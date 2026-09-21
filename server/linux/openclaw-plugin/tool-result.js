export function toolResult(details) {
  const payload = { ...details, ok: true };
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    details: payload,
  };
}
