import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

export function sha256(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

export function videoStartFingerprint(params, source, publicationTarget) {
  return sha256(JSON.stringify({
    sourceHash: sha256(source),
    profile: params.profile ?? "standard",
    sourceKind: params.sourceKind ?? "auto",
    title: params.title ?? null,
    force: params.force === true,
    publicationTarget: publicationTarget ?? null,
  }));
}

export function flowOutputRoot(baseOutputRoot, jobId) {
  if (!/^[a-f0-9]{24}$/.test(jobId)) throw new Error("Unsupported video job id.");
  return join(resolve(baseOutputRoot), "jobs", jobId);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

export function newestJobState(root, startedAt) {
  if (!existsSync(root)) return null;
  let newest = null;
  const queue = [{ path: root, depth: 0 }];
  while (queue.length) {
    const current = queue.shift();
    if (current.depth > 5) continue;
    let entries;
    try {
      entries = readdirSync(current.path, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const path = join(current.path, entry.name);
      if (entry.isDirectory()) {
        queue.push({ path, depth: current.depth + 1 });
      } else if (entry.name === "job-state.json") {
        const modified = statSync(path).mtimeMs;
        if (modified >= startedAt - 5000 && (!newest || modified > newest.modified)) {
          newest = { path, modified, data: readJson(path) };
        }
      }
    }
  }
  return newest;
}
