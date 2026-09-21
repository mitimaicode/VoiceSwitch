import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { flowOutputRoot, newestJobState, videoStartFingerprint } from "./job-isolation.js";

import { inspectTelegramPublication } from "./publication-completion.js";
import {
  expectsTelegramPublication,
  resolveTelegramPublicationTarget,
  telegramOriginFromDestination,
  telegramOriginFromSessionKey,
} from "./telegram-origin.js";

test("uses the OpenClaw 2026.9 managed TaskFlow runtime", () => {
  const source = readFileSync(new URL("./index.js", import.meta.url), "utf8");
  assert.match(source, /api\.runtime\.tasks\.managedFlows\.fromToolContext/);
  assert.doesNotMatch(source, /api\.runtime\.tasks\.flow\./);
});

test("parses Telegram topic session keys", () => {
  assert.deepEqual(
    telegramOriginFromSessionKey("agent:main:telegram:group:-1001234567890:topic:8"),
    { chatId: "-1001234567890", sourceTopicId: 8 },
  );
});

test("parses marked Telegram destinations", () => {
  assert.deepEqual(
    telegramOriginFromDestination("telegram:-1001234567890:topic:8"),
    { chatId: "-1001234567890", sourceTopicId: 8 },
  );
});

test("trusted delivery context becomes the publication target", () => {
  const target = resolveTelegramPublicationTarget({
    deliveryContext: { channel: "telegram", to: "-1001234567890", threadId: "8" },
  });
  assert.deepEqual(target, { chatId: "-1001234567890", sourceTopicId: 8 });
});

test("session key is a fallback when delivery context is absent", () => {
  const target = resolveTelegramPublicationTarget({
    messageChannel: "telegram",
    sessionKey: "agent:main:telegram:group:-1001234567890:topic:8",
  });
  assert.deepEqual(target, { chatId: "-1001234567890", sourceTopicId: 8 });
  assert.equal(expectsTelegramPublication({ messageChannel: "telegram" }), true);
});

test("non-Telegram calls do not gain a publication target", () => {
  assert.equal(resolveTelegramPublicationTarget({ messageChannel: "webchat" }), null);
  assert.equal(expectsTelegramPublication({ messageChannel: "webchat" }), false);
});

test("parallel video jobs only inspect their own output directory", (t) => {
  const root = mkdtempSync(join(tmpdir(), "video-isolation-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const firstRoot = flowOutputRoot(root, "a".repeat(24));
  const secondRoot = flowOutputRoot(root, "b".repeat(24));
  mkdirSync(join(firstRoot, "result"), { recursive: true });
  mkdirSync(join(secondRoot, "result"), { recursive: true });
  writeFileSync(join(firstRoot, "result", "job-state.json"), JSON.stringify({ stage: "complete", owner: "first" }));
  writeFileSync(join(secondRoot, "result", "job-state.json"), JSON.stringify({ stage: "complete", owner: "second" }));
  assert.equal(newestJobState(firstRoot, 0).data.owner, "first");
  assert.equal(newestJobState(secondRoot, 0).data.owner, "second");
});

test("video start fingerprint is stable and payload-sensitive", () => {
  const params = { profile: "standard", sourceKind: "youtube", title: "One" };
  const target = { chatId: "-1001", sourceTopicId: 7 };
  const first = videoStartFingerprint(params, "https://youtu.be/example", target);
  assert.equal(first, videoStartFingerprint(params, "https://youtu.be/example", target));
  assert.notEqual(first, videoStartFingerprint({ ...params, profile: "deep" }, "https://youtu.be/example", target));
});

function publicationFixture(t, delivery) {
  const root = mkdtempSync(join(tmpdir(), "video-publication-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const outbox = join(root, "telegram-publication.json");
  writeFileSync(outbox, JSON.stringify({ delivery }), "utf8");
  return { stages: { publication: { status: "ready", outbox } } };
}

test("pending Telegram delivery cannot complete the flow", (t) => {
  const job = publicationFixture(t, {
    status: "pending_topic",
    topic_id: null,
    messages: {},
    completed_at: null,
  });
  const result = inspectTelegramPublication(job);
  assert.equal(result.complete, false);
  assert.ok(result.missing.includes("topic_id"));
  assert.ok(result.missing.includes("delivery.status"));
});

test("completed status alone is insufficient without message ids", (t) => {
  const job = publicationFixture(t, {
    status: "completed",
    topic_id: 777,
    messages: { status: 10, summary: 11 },
    completed_at: "2026-08-30T07:00:00+00:00",
  });
  const result = inspectTelegramPublication(job);
  assert.equal(result.complete, false);
  assert.deepEqual(result.missing, ["message:summary_document", "message:transcript_document"]);
});

test("flow completion requires topic and every publication message", (t) => {
  const job = publicationFixture(t, {
    status: "completed",
    topic_id: 777,
    messages: {
      status: 10,
      summary: 11,
      summary_document: 12,
      transcript_document: 13,
    },
    completed_at: "2026-08-30T07:00:00+00:00",
  });
  const result = inspectTelegramPublication(job);
  assert.equal(result.complete, true);
  assert.deepEqual(result.missing, []);
});
