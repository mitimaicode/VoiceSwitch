function positiveInteger(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

export function telegramOriginFromSessionKey(sessionKey) {
  if (typeof sessionKey !== "string" || !sessionKey.trim()) return null;
  const parts = sessionKey.split(":");
  const channelIndex = parts.indexOf("telegram");
  if (channelIndex < 0) return null;
  const kind = parts[channelIndex + 1];
  const chatId = parts[channelIndex + 2];
  if (!chatId || !["direct", "group"].includes(kind)) return null;
  const topicIndex = parts.indexOf("topic", channelIndex + 3);
  return {
    chatId,
    sourceTopicId: topicIndex >= 0 ? positiveInteger(parts[topicIndex + 1]) : null,
  };
}

export function telegramOriginFromDestination(value) {
  if (value === null || value === undefined) return null;
  const rendered = String(value).trim();
  if (!rendered) return null;
  const match = rendered.match(/^(?:telegram:)?(-?\d+)(?::topic:(\d+))?$/);
  if (!match) return null;
  return {
    chatId: match[1],
    sourceTopicId: positiveInteger(match[2]),
  };
}

export function expectsTelegramPublication(toolContext = {}) {
  const deliveryChannel = String(toolContext.deliveryContext?.channel ?? "").toLowerCase();
  const messageChannel = String(toolContext.messageChannel ?? "").toLowerCase();
  return deliveryChannel === "telegram"
    || messageChannel === "telegram"
    || telegramOriginFromSessionKey(toolContext.sessionKey) !== null;
}

export function resolveTelegramPublicationTarget(toolContext = {}, params = {}) {
  const explicit = telegramOriginFromDestination(params.telegramChatId);
  const delivery = String(toolContext.deliveryContext?.channel ?? "").toLowerCase() === "telegram"
    ? telegramOriginFromDestination(toolContext.deliveryContext?.to)
    : null;
  const session = telegramOriginFromSessionKey(toolContext.sessionKey);
  const chatId = explicit?.chatId ?? delivery?.chatId ?? session?.chatId;
  if (!chatId) return null;
  const sourceTopicId = positiveInteger(params.telegramSourceTopicId)
    ?? positiveInteger(toolContext.deliveryContext?.threadId)
    ?? explicit?.sourceTopicId
    ?? delivery?.sourceTopicId
    ?? session?.sourceTopicId
    ?? null;
  return { chatId: String(chatId), sourceTopicId };
}
