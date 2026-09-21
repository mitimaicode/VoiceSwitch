import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { Type } from "typebox";
import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";
import { inspectTelegramPublication } from "./publication-completion.js";
import { expectsTelegramPublication, resolveTelegramPublicationTarget } from "./telegram-origin.js";
import { validateVideoSource } from "./source-validation.js";
import { toolResult } from "./tool-result.js";
import { flowOutputRoot, newestJobState, sha256, videoStartFingerprint } from "./job-isolation.js";
import {
  isWorkerScopeActive,
  stopWorkerScope,
  workerScopeArgs,
  workerScopeUnitName,
} from "./worker-scope.js";

const CONTROLLER_ID = "video-transcription-taskflow";
const HOME = homedir();
const PROJECT = process.env.VOICESWITCH_VIDEO_PROJECT
  ?? join(HOME, ".local", "share", "mitim-video", "pipeline");
const VIDEO_PYTHON = process.env.VOICESWITCH_VIDEO_PYTHON
  ?? join(HOME, ".local", "share", "mitim-video", "venv", "bin", "python");
const DEFAULT_FFMPEG = join(HOME, ".local", "share", "mitim-stt", "bin", "ffmpeg");
const DEFAULT_FFPROBE = join(HOME, ".local", "share", "mitim-stt", "bin", "ffprobe");
const DEFAULT_OUTPUT_ROOT = join(PROJECT, "artifacts");
const DEFAULT_PIPELINE = join(PROJECT, "video_pipeline.py");
const ALIGNER = `${VIDEO_PYTHON} ${join(PROJECT, "align_qwen.py")} --audio \"{audio}\" --transcript \"{transcript}\" --output \"{output}\"`;
const DIARIZER = `${VIDEO_PYTHON} ${join(PROJECT, "diarize_pyannote.py")} --audio \"{audio}\" --transcript \"{transcript}\" --output \"{output}\"`;
const TERMINAL = new Set(["succeeded", "failed", "cancelled", "lost"]);

const profiles = ["quick", "standard", "interview", "multilingual", "deep"];
const sourceKinds = ["auto", "youtube", "telegram", "local"];

const startParameters = Type.Object({
  idempotencyKey: Type.String({ minLength: 1, maxLength: 200, description: "Stable key reused for retries of the same video job." }),
  source: Type.String({ description: "Exact YouTube URL or absolute local MediaPath. Never pass the literal marker media:." }),
  profile: Type.Optional(Type.Union(profiles.map((value) => Type.Literal(value)))),
  sourceKind: Type.Optional(Type.Union(sourceKinds.map((value) => Type.Literal(value)))),
  title: Type.Optional(Type.String()),
  force: Type.Optional(Type.Boolean()),
  telegramChatId: Type.Optional(Type.String({ description: "Telegram target chat id; normally derived from trusted runtime context." })),
  telegramSourceTopicId: Type.Optional(Type.Integer({ minimum: 1, description: "Telegram source topic id; normally derived from trusted runtime context." })),
});
const flowParameters = Type.Object({
  flowId: Type.Optional(Type.String({ description: "TaskFlow id; latest flow is used when omitted." })),
});

const pluginConfigSchema = Type.Object({
  outputRoot: Type.Optional(Type.String()),
  pipelinePath: Type.Optional(Type.String()),
  pythonPath: Type.Optional(Type.String()),
  ffmpegPath: Type.Optional(Type.String()),
  ffprobePath: Type.Optional(Type.String()),
}, { additionalProperties: false });

function getFlow(runtime, token) {
  return token ? runtime.resolve(token) : runtime.findLatest();
}

function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function isWorkerAlive(state) {
  if (state?.unitName) {
    if (isWorkerScopeActive(state.unitName)) return true;
    return Date.now() - Number(state.startedAt ?? 0) < 10_000 && isAlive(Number(state.pid));
  }
  return isAlive(Number(state?.pid));
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function reserveVideoStart(baseOutputRoot, idempotencyKey, startFingerprint) {
  const reservationRoot = join(resolve(baseOutputRoot), ".taskflow-start");
  mkdirSync(reservationRoot, { recursive: true, mode: 0o700 });
  const keyHash = sha256(idempotencyKey);
  const reservationPath = join(reservationRoot, `${keyHash}.json`);
  const reservation = {
    schemaVersion: 1,
    keyHash,
    startFingerprint,
    status: "reserved",
    gatewayPid: process.pid,
    reservedAt: Date.now(),
  };
  let descriptor;
  try {
    descriptor = openSync(reservationPath, "wx", 0o600);
    writeFileSync(descriptor, `${JSON.stringify(reservation)}\n`, "utf8");
    closeSync(descriptor);
    return { path: reservationPath, data: reservation, created: true };
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    if (error?.code !== "EEXIST") throw error;
    const existing = readJson(reservationPath);
    if (!existing || existing.keyHash !== keyHash) {
      throw new Error("Video start reservation is corrupted; refusing a duplicate worker.");
    }
    if (existing.startFingerprint !== startFingerprint) {
      throw new Error("Video idempotency key was already used with a different payload.");
    }
    return { path: reservationPath, data: existing, created: false };
  }
}

function updateVideoStartReservation(reservationPath, patch) {
  const current = readJson(reservationPath);
  if (!current) throw new Error("Video start reservation disappeared.");
  const temporary = `${reservationPath}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify({ ...current, ...patch, updatedAt: Date.now() })}\n`, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, reservationPath);
}

function stageFromState(state) {
  if (!state || typeof state !== "object") return "processing";
  const stage = String(state.stage ?? state.current_stage ?? state.status ?? "processing");
  return ["complete", "completed", "succeeded"].includes(stage.toLowerCase()) ? "ready" : stage;
}

function settleStoppedFlow(runtime, flow, nextState, stage) {
  if (!["ready", "completed", "complete", "succeeded"].includes(stage.toLowerCase())) {
    return runtime.fail({
      flowId: flow.flowId,
      expectedRevision: flow.revision,
      stateJson: nextState,
      blockedSummary: `Video worker stopped at stage: ${stage}`,
    });
  }

  const publication = inspectTelegramPublication(
    nextState.jobState,
    Boolean(nextState.publicationTarget),
  );
  const stateJson = { ...nextState, publication };
  if (publication.required && !publication.complete) {
    return runtime.setWaiting({
      flowId: flow.flowId,
      expectedRevision: flow.revision,
      currentStep: "waiting_publication",
      stateJson,
      waitJson: {
        kind: "telegram_publication",
        outboxPath: publication.outboxPath,
        deliveryStatus: publication.status,
        missing: publication.missing,
      },
      blockedSummary: "Local processing is complete; Telegram publication is still pending.",
    });
  }
  return runtime.finish({
    flowId: flow.flowId,
    expectedRevision: flow.revision,
    stateJson,
  });
}

function refreshFlow(runtime, flow) {
  if (!flow || TERMINAL.has(flow.status)) return flow;
  const state = flow.stateJson && typeof flow.stateJson === "object" ? flow.stateJson : {};
  const pid = Number(state.pid);
  const job = newestJobState(String(state.outputRoot ?? DEFAULT_OUTPUT_ROOT), Number(state.startedAt ?? 0));
  const stage = stageFromState(job?.data);
  const nextState = { ...state, stage, ...(job ? { jobStatePath: job.path, jobState: job.data } : {}) };

  if (isWorkerAlive(state)) {
    const updated = runtime.resume({
      flowId: flow.flowId,
      expectedRevision: flow.revision,
      status: "running",
      currentStep: stage,
      stateJson: nextState,
    });
    return updated.applied ? updated.flow : updated.current ?? flow;
  }

  const result = settleStoppedFlow(runtime, flow, nextState, stage);
  return result.applied ? result.flow : result.current ?? flow;
}

function pipelineArgs({
  source,
  profile,
  sourceKind,
  title,
  force,
  pipelinePath,
  outputRoot,
  ffmpegPath,
  ffprobePath,
  publicationTarget,
}) {
  const args = [
    pipelinePath,
    source,
    "--profile", profile,
    "--source-kind", sourceKind ?? "auto",
    "--output-root", outputRoot,
    "--align-command", ALIGNER,
    "--diarize-command", DIARIZER,
    "--ffmpeg-path", ffmpegPath,
    "--ffprobe-path", ffprobePath,
  ];
  if (title) args.push("--title", title);
  if (force) args.push("--force");
  if (publicationTarget) {
    args.push("--telegram-chat-id", publicationTarget.chatId);
    if (publicationTarget.sourceTopicId) {
      args.push("--telegram-source-topic-id", String(publicationTarget.sourceTopicId));
    }
  }
  return args;
}

function launchWorker({ flowId, pythonPath, args, logPath, ffmpegPath, ffprobePath }) {
  const unitName = workerScopeUnitName(flowId);
  const logFd = openSync(logPath, "a");
  let child;
  try {
    child = spawn("/usr/bin/systemd-run", workerScopeArgs(unitName, pythonPath, args), {
      detached: true,
      stdio: ["ignore", logFd, logFd],
      env: {
        ...process.env,
        PATH: [dirname(ffmpegPath), dirname(ffprobePath), process.env.PATH].filter(Boolean).join(":"),
      },
    });
  } finally {
    closeSync(logFd);
  }
  if (!child.pid) throw new Error("Video worker scope did not return a PID.");
  return { child, unitName };
}

function finishFromExit(runtime, flowId, code, signal) {
  let flow = runtime.get(flowId);
  if (!flow || TERMINAL.has(flow.status)) return;
  const state = flow.stateJson && typeof flow.stateJson === "object" ? flow.stateJson : {};
  const job = newestJobState(String(state.outputRoot ?? DEFAULT_OUTPUT_ROOT), Number(state.startedAt ?? 0));
  const stage = stageFromState(job?.data);
  const nextState = {
    ...state,
    stage,
    ...(job ? { jobStatePath: job.path, jobState: job.data } : {}),
    exitCode: code,
    exitSignal: signal ?? null,
  };
  if (code === 0) {
    settleStoppedFlow(runtime, flow, nextState, stage);
  } else {
    runtime.fail({
      flowId,
      expectedRevision: flow.revision,
      stateJson: nextState,
      blockedSummary: `Video worker exited with code ${code ?? "unknown"}`,
    });
  }
}

function createStartTool(api, config, toolContext) {
  const runtime = api.runtime.tasks.managedFlows.fromToolContext(toolContext);
  return {
    name: "video_transcription_start",
    label: "Start video transcription",
    description: "Start the local GigaAM-first video pipeline and track it as a managed TaskFlow.",
    parameters: startParameters,
    execute: async (_toolCallId, params) => {
      const profile = params.profile ?? "standard";
      // Fail before createManaged/spawn so an invalid attachment cannot be
      // reported as "started" and then disappear as a failed background job.
      const source = validateVideoSource(params.source);
      const idempotencyKey = String(params.idempotencyKey ?? "").trim();
      if (!idempotencyKey || idempotencyKey.length > 200) {
        throw new Error("video_transcription_start requires a stable idempotencyKey.");
      }
      const publicationTarget = resolveTelegramPublicationTarget(toolContext, params);
      if (expectsTelegramPublication(toolContext) && !publicationTarget) {
        throw new Error("Telegram context detected, but publication chat could not be resolved.");
      }

      const pipelinePath = resolve(config.pipelinePath ?? DEFAULT_PIPELINE);
      const pythonPath = config.pythonPath ? resolve(config.pythonPath) : "/usr/bin/python3";
      const ffmpegPath = resolve(config.ffmpegPath ?? DEFAULT_FFMPEG);
      const ffprobePath = resolve(config.ffprobePath ?? DEFAULT_FFPROBE);
      const baseOutputRoot = resolve(config.outputRoot ?? DEFAULT_OUTPUT_ROOT);
      if (!existsSync(pipelinePath)) throw new Error(`Pipeline not found: ${pipelinePath}`);
      if (!existsSync(ffmpegPath)) throw new Error(`ffmpeg not found: ${ffmpegPath}`);
      if (!existsSync(ffprobePath)) throw new Error(`ffprobe not found: ${ffprobePath}`);
      mkdirSync(baseOutputRoot, { recursive: true });
      const startFingerprint = videoStartFingerprint(params, source, publicationTarget);
      const existing = runtime.list().find((candidate) => {
        const state = candidate?.stateJson && typeof candidate.stateJson === "object" ? candidate.stateJson : {};
        return candidate.controllerId === CONTROLLER_ID && state.startIdempotencyKey === idempotencyKey;
      });
      if (existing) {
        const state = existing.stateJson && typeof existing.stateJson === "object" ? existing.stateJson : {};
        if (state.startFingerprint !== startFingerprint) {
          throw new Error("Video idempotency key was already used with a different payload.");
        }
        return toolResult({ ...refreshFlow(runtime, existing), idempotent: true, duplicateWorkerCreated: false });
      }
      const reservation = reserveVideoStart(baseOutputRoot, idempotencyKey, startFingerprint);
      if (!reservation.created) {
        if (reservation.data.flowId) {
          const reservedFlow = runtime.get(reservation.data.flowId);
          if (reservedFlow) {
            return toolResult({ ...refreshFlow(runtime, reservedFlow), idempotent: true, duplicateWorkerCreated: false });
          }
          throw new Error(`Video job already belongs to TaskFlow ${reservation.data.flowId}; refusing a cross-session duplicate.`);
        }
        throw new Error("A previous video start stopped before its TaskFlow id was recorded; manual reconcile is required and no duplicate was started.");
      }
      const jobId = sha256(idempotencyKey).slice(0, 24);
      const outputRoot = flowOutputRoot(baseOutputRoot, jobId);
      mkdirSync(outputRoot, { recursive: true });
      const logRoot = join(outputRoot, "logs");
      mkdirSync(logRoot, { recursive: true });

      const startedAt = Date.now();
      const flow = runtime.createManaged({
        controllerId: CONTROLLER_ID,
        goal: `Transcribe video: ${params.title || basename(source) || source}`,
        status: "running",
        notifyPolicy: "state_changes",
        currentStep: "received",
        stateJson: {
          source,
          sourceHash: sha256(source),
          profile,
          baseOutputRoot,
          outputRoot,
          jobId,
          startIdempotencyKey: idempotencyKey,
          startFingerprint,
          startedAt,
          publicationTarget,
        },
        waitJson: { kind: "local_process" },
      });
      updateVideoStartReservation(reservation.path, { status: "flow_created", flowId: flow.flowId, jobId });

      const logPath = join(logRoot, `${flow.flowId}.log`);
      const args = pipelineArgs({
        source,
        profile,
        sourceKind: params.sourceKind,
        title: params.title,
        force: params.force,
        pipelinePath,
        outputRoot,
        ffmpegPath,
        ffprobePath,
        publicationTarget,
      });

      let launched;
      try {
        launched = launchWorker({ flowId: flow.flowId, pythonPath, args, logPath, ffmpegPath, ffprobePath });
      } catch (error) {
        const current = runtime.get(flow.flowId) ?? flow;
        runtime.fail({
          flowId: current.flowId,
          expectedRevision: current.revision,
          stateJson: { ...current.stateJson, stage: "worker_launch_failed" },
          blockedSummary: `Video worker launch failed: ${error instanceof Error ? error.message : String(error)}`,
        });
        updateVideoStartReservation(reservation.path, { status: "failed", flowId: flow.flowId, jobId });
        throw error;
      }
      const { child, unitName } = launched;
      if (!child.pid) {
        finishFromExit(runtime, flow.flowId, null, "spawn_failed");
        throw new Error("Video worker did not return a PID.");
      }

      const current = runtime.get(flow.flowId);
      const stateJson = {
        source,
        sourceHash: sha256(source),
        profile,
        baseOutputRoot,
        outputRoot,
        jobId,
        startIdempotencyKey: idempotencyKey,
        startFingerprint,
        startedAt,
        pid: child.pid,
        unitName,
        logPath,
        ffmpegPath,
        ffprobePath,
        sourceKind: params.sourceKind ?? "auto",
        title: params.title ?? null,
        force: params.force === true,
        publicationTarget,
      };
      if (current) {
        runtime.resume({
          flowId: flow.flowId,
          expectedRevision: current.revision,
          status: "running",
          currentStep: "received",
          stateJson,
        });
      }
      child.once("exit", (code, signal) => finishFromExit(runtime, flow.flowId, code, signal));
      child.once("error", () => finishFromExit(runtime, flow.flowId, null, "spawn_error"));
      child.unref();
      updateVideoStartReservation(reservation.path, { status: "worker_started", flowId: flow.flowId, jobId, unitName });

      return toolResult({ flowId: flow.flowId, jobId, status: "running", pid: child.pid, logPath, profile, publicationTarget, idempotent: false });
    },
  };
}

function createResumeTool(api, config, toolContext) {
  const runtime = api.runtime.tasks.managedFlows.fromToolContext(toolContext);
  return {
    name: "video_transcription_resume",
    label: "Resume video transcription",
    description: "Resume the same interrupted video TaskFlow without creating a duplicate Flow.",
    parameters: flowParameters,
    execute: async (_toolCallId, params) => {
      let flow = getFlow(runtime, params.flowId);
      if (!flow) throw new Error("Video transcription TaskFlow was not found.");
      if (TERMINAL.has(flow.status) && flow.status !== "failed") {
        throw new Error(`Video transcription TaskFlow cannot be resumed from: ${flow.status}`);
      }
      const state = flow.stateJson && typeof flow.stateJson === "object" ? flow.stateJson : {};
      if (isWorkerAlive(state)) return toolResult({ ...flow, idempotent: true, workerActive: true });

      const completedJob = newestJobState(
        String(state.outputRoot ?? DEFAULT_OUTPUT_ROOT),
        Number(state.startedAt ?? 0),
      );
      const completedStage = stageFromState(completedJob?.data);
      if (["ready", "completed", "complete", "succeeded"].includes(completedStage.toLowerCase())) {
        const settled = settleStoppedFlow(runtime, flow, {
          ...state,
          stage: completedStage,
          jobStatePath: completedJob.path,
          jobState: completedJob.data,
        }, completedStage);
        return toolResult({ ...(settled.applied ? settled.flow : settled.current ?? flow), idempotent: true, workerActive: false });
      }
      const source = validateVideoSource(state.source);
      const profile = profiles.includes(state.profile) ? state.profile : "standard";
      const pipelinePath = resolve(config.pipelinePath ?? DEFAULT_PIPELINE);
      const pythonPath = config.pythonPath ? resolve(config.pythonPath) : "/usr/bin/python3";
      const ffmpegPath = resolve(state.ffmpegPath ?? config.ffmpegPath ?? DEFAULT_FFMPEG);
      const ffprobePath = resolve(state.ffprobePath ?? config.ffprobePath ?? DEFAULT_FFPROBE);
      const outputRoot = resolve(state.outputRoot ?? config.outputRoot ?? DEFAULT_OUTPUT_ROOT);
      const logPath = resolve(state.logPath ?? join(outputRoot, "logs", `${flow.flowId}.log`));
      if (!existsSync(pipelinePath)) throw new Error(`Pipeline not found: ${pipelinePath}`);
      if (!existsSync(ffmpegPath)) throw new Error(`ffmpeg not found: ${ffmpegPath}`);
      if (!existsSync(ffprobePath)) throw new Error(`ffprobe not found: ${ffprobePath}`);
      mkdirSync(dirname(logPath), { recursive: true });
      const startedAt = Date.now();
      const args = pipelineArgs({
        source,
        profile,
        sourceKind: state.sourceKind,
        title: state.title,
        force: false,
        pipelinePath,
        outputRoot,
        ffmpegPath,
        ffprobePath,
        publicationTarget: state.publicationTarget ?? null,
      });
      const { child, unitName } = launchWorker({
        flowId: flow.flowId,
        pythonPath,
        args,
        logPath,
        ffmpegPath,
        ffprobePath,
      });
      const resumed = runtime.resume({
        flowId: flow.flowId,
        expectedRevision: flow.revision,
        status: "running",
        currentStep: "resumed_after_gateway_restart",
        stateJson: {
          ...state,
          originalStartedAt: state.originalStartedAt ?? state.startedAt,
          startedAt,
          pid: child.pid,
          unitName,
          recoveryCount: Number(state.recoveryCount ?? 0) + 1,
          recoveredAt: startedAt,
          stage: "resumed_after_gateway_restart",
        },
      });
      if (!resumed.applied) {
        stopWorkerScope(unitName);
        throw new Error(`Video TaskFlow changed during recovery: ${resumed.code ?? "revision conflict"}`);
      }
      child.once("exit", (code, signal) => finishFromExit(runtime, flow.flowId, code, signal));
      child.once("error", () => finishFromExit(runtime, flow.flowId, null, "spawn_error"));
      child.unref();
      return toolResult({
        flowId: flow.flowId,
        status: "running",
        resumed: true,
        duplicateFlowCreated: false,
        pid: child.pid,
        unitName,
      });
    },
  };
}

function createStatusTool(api, toolContext) {
  const runtime = api.runtime.tasks.managedFlows.fromToolContext(toolContext);
  return {
    name: "video_transcription_status",
    label: "Video transcription status",
    description: "Refresh and return the latest state of a managed video transcription TaskFlow.",
    parameters: flowParameters,
    execute: async (_toolCallId, params) => {
      const flow = getFlow(runtime, params.flowId);
      if (!flow) throw new Error("Video transcription TaskFlow was not found.");
      return toolResult(refreshFlow(runtime, flow));
    },
  };
}

function createCancelTool(api, toolContext) {
  const runtime = api.runtime.tasks.managedFlows.fromToolContext(toolContext);
  return {
    name: "video_transcription_cancel",
    label: "Cancel video transcription",
    description: "Terminate the local worker and cancel its managed video transcription TaskFlow.",
    parameters: flowParameters,
    execute: async (_toolCallId, params) => {
      const flow = getFlow(runtime, params.flowId);
      if (!flow) throw new Error("Video transcription TaskFlow was not found.");
      const state = flow.stateJson && typeof flow.stateJson === "object" ? flow.stateJson : {};
      const pid = Number(state.pid);
      if (state.unitName) {
        stopWorkerScope(state.unitName);
      } else if (isAlive(pid)) {
        try {
          process.kill(-pid, "SIGTERM");
        } catch {
          process.kill(pid, "SIGTERM");
        }
      }
      const requested = runtime.requestCancel({ flowId: flow.flowId, expectedRevision: flow.revision });
      const current = requested.applied ? requested.flow : requested.current ?? flow;
      const cfg = toolContext.getRuntimeConfig?.() ?? toolContext.runtimeConfig ?? toolContext.config;
      if (!cfg) return toolResult(current);
      const cancelled = await runtime.cancel({ flowId: flow.flowId, cfg });
      return toolResult(cancelled);
    },
  };
}

export default defineToolPlugin({
  id: CONTROLLER_ID,
  name: "Video Transcription TaskFlow",
  description: "Managed background orchestration for the local GigaAM-first video pipeline.",
  configSchema: pluginConfigSchema,
  tools: (tool) => [
    tool({
      name: "video_transcription_start",
      label: "Start video transcription",
      description: "Start the local GigaAM-first video pipeline and track it as a managed TaskFlow.",
      parameters: startParameters,
      factory: ({ api, config, toolContext }) => (
        toolContext?.sessionKey ? createStartTool(api, config, toolContext) : null
      ),
    }),
    tool({
      name: "video_transcription_resume",
      label: "Resume video transcription",
      description: "Resume the same interrupted video TaskFlow without creating a duplicate Flow.",
      parameters: flowParameters,
      factory: ({ api, config, toolContext }) => (
        toolContext?.sessionKey ? createResumeTool(api, config, toolContext) : null
      ),
    }),
    tool({
      name: "video_transcription_status",
      label: "Video transcription status",
      description: "Refresh and return a managed video transcription TaskFlow.",
      parameters: flowParameters,
      factory: ({ api, toolContext }) => (
        toolContext?.sessionKey ? createStatusTool(api, toolContext) : null
      ),
    }),
    tool({
      name: "video_transcription_cancel",
      label: "Cancel video transcription",
      description: "Cancel a managed video transcription TaskFlow.",
      parameters: flowParameters,
      factory: ({ api, toolContext }) => (
        toolContext?.sessionKey ? createCancelTool(api, toolContext) : null
      ),
    }),
  ],
});
