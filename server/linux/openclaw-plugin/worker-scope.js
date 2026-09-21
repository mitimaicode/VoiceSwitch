import { spawnSync } from "node:child_process";

const FLOW_ID_PATTERN = /^[a-zA-Z0-9-]{1,80}$/;

export function workerScopeUnitName(flowId) {
  if (typeof flowId !== "string" || !FLOW_ID_PATTERN.test(flowId)) {
    throw new Error("Unsupported video TaskFlow id for a systemd scope.");
  }
  return `openclaw-video-${flowId}.scope`;
}

export function workerScopeArgs(unitName, command, args = []) {
  if (typeof unitName !== "string" || !unitName.endsWith(".scope")) {
    throw new Error("Video worker unit must be a systemd scope.");
  }
  if (typeof command !== "string" || !command.startsWith("/")) {
    throw new Error("Video worker command must be an absolute path.");
  }
  return [
    "--user",
    "--scope",
    "--quiet",
    `--unit=${unitName}`,
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
    command,
    ...args,
  ];
}

export function isWorkerScopeActive(unitName, run = spawnSync) {
  if (typeof unitName !== "string" || !unitName.endsWith(".scope")) return false;
  const result = run("/usr/bin/systemctl", ["--user", "is-active", "--quiet", unitName], {
    stdio: "ignore",
    timeout: 5000,
  });
  return result.status === 0;
}
export function stopWorkerScope(unitName, run = spawnSync) {
  if (typeof unitName !== "string" || !unitName.endsWith(".scope")) return false;
  const result = run("/usr/bin/systemctl", ["--user", "stop", unitName], {
    stdio: "ignore",
    timeout: 10000,
  });
  return result.status === 0;
}
