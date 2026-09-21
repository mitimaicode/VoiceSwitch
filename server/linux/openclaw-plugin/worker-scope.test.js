import assert from "node:assert/strict";
import test from "node:test";

import {
  isWorkerScopeActive,
  stopWorkerScope,
  workerScopeArgs,
  workerScopeUnitName,
} from "./worker-scope.js";

test("video worker scope is owner-flow specific and resource friendly", () => {
  const unit = workerScopeUnitName("4e090d8d-5f12-4b32-aa42-985608f3c755");
  assert.equal(unit, "openclaw-video-4e090d8d-5f12-4b32-aa42-985608f3c755.scope");
  assert.deepEqual(workerScopeArgs(unit, "/usr/bin/python3", ["/opt/pipeline.py"]), [
    "--user",
    "--scope",
    "--quiet",
    `--unit=${unit}`,
    "--property=CPUWeight=50",
    "--property=CPUQuota=300%",
    "--property=IOWeight=50",
    "--property=MemoryHigh=3G",
    "--property=MemoryMax=4G",
    "--property=TasksMax=256",
    "--",
    "/usr/bin/nice",
    "-n",
    "10",
    "/usr/bin/python3",
    "/opt/pipeline.py",
  ]);
});

test("scope probes and stops use exact non-shell systemctl arguments", () => {
  const calls = [];
  const run = (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 0 };
  };
  const unit = workerScopeUnitName("flow-1");
  assert.equal(isWorkerScopeActive(unit, run), true);
  assert.equal(stopWorkerScope(unit, run), true);
  assert.deepEqual(calls.map((call) => call.args), [
    ["--user", "is-active", "--quiet", unit],
    ["--user", "stop", unit],
  ]);
});

test("unsafe flow ids and commands are rejected", () => {
  assert.throws(() => workerScopeUnitName("flow/../../escape"), /Unsupported/);
  assert.throws(() => workerScopeArgs("worker.service", "/usr/bin/python3"), /scope/);
  assert.throws(() => workerScopeArgs("worker.scope", "python3"), /absolute/);
});
