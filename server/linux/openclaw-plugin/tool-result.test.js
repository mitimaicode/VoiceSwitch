import assert from "node:assert/strict";
import test from "node:test";

import { toolResult } from "./tool-result.js";

test("successful terminal TaskFlow status is an affirmative tool result", () => {
  const result = toolResult({ flowId: "flow-1", status: "succeeded" });
  assert.equal(result.details.ok, true);
  assert.equal(result.details.status, "succeeded");
  assert.equal(JSON.parse(result.content[0].text).ok, true);
});
