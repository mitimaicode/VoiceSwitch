import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const REQUIRED_PUBLICATION_MESSAGES = ["status", "summary", "summary_document", "transcript_document"];

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0;
}

function publicationPathFromJob(job) {
  const stages = job?.stages && typeof job.stages === "object" ? job.stages : {};
  const publication = stages.publication && typeof stages.publication === "object"
    ? stages.publication
    : {};
  return typeof publication.outbox === "string" && publication.outbox.trim()
    ? resolve(publication.outbox)
    : null;
}

export function inspectTelegramPublication(job, publicationExpected = true) {
  if (!publicationExpected) {
    return { required: false, complete: true, status: "skipped", missing: [] };
  }
  const outboxPath = publicationPathFromJob(job);
  if (!outboxPath) {
    return {
      required: true,
      complete: false,
      status: "missing_outbox",
      outboxPath: null,
      missing: ["outbox"],
    };
  }
  const plan = readJson(outboxPath);
  if (!plan) {
    return {
      required: true,
      complete: false,
      status: "unreadable_outbox",
      outboxPath,
      missing: ["outbox"],
    };
  }
  const delivery = plan.delivery && typeof plan.delivery === "object" ? plan.delivery : {};
  const messages = delivery.messages && typeof delivery.messages === "object" ? delivery.messages : {};
  const missing = [];
  if (!positiveInteger(delivery.topic_id)) missing.push("topic_id");
  for (const kind of REQUIRED_PUBLICATION_MESSAGES) {
    if (!positiveInteger(messages[kind])) missing.push(`message:${kind}`);
  }
  if (typeof delivery.completed_at !== "string" || !delivery.completed_at.trim()) {
    missing.push("completed_at");
  }
  if (delivery.status !== "completed") missing.push("delivery.status");
  return {
    required: true,
    complete: missing.length === 0,
    status: String(delivery.status ?? "missing"),
    outboxPath,
    topicId: positiveInteger(delivery.topic_id) ? Number(delivery.topic_id) : null,
    messages,
    completedAt: delivery.completed_at ?? null,
    missing,
  };
}
