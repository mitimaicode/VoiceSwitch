import { existsSync, statSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

const YOUTUBE_HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"]);

function isYoutubeUrl(value) {
  try {
    const parsed = new URL(value);
    return ["http:", "https:"].includes(parsed.protocol) && YOUTUBE_HOSTS.has(parsed.hostname.toLowerCase());
  } catch {
    return false;
  }
}

/**
 * Validate before creating a managed flow. In particular, `media:` is an
 * inbound-media marker, not a filesystem path; accepting it creates a flow
 * that can only fail after the user has already been told it started.
 */
export function validateVideoSource(input) {
  const source = typeof input === "string" ? input.trim() : "";
  if (!source) {
    throw new Error("Источник видео пуст. Передай точный MediaPath или YouTube-ссылку.");
  }
  if (/^media(?::|$)/i.test(source)) {
    throw new Error("Получен маркер `media:`, а не путь к файлу. Передай точный MediaPath из входящего вложения.");
  }
  if (/^https?:\/\//i.test(source)) {
    if (!isYoutubeUrl(source)) {
      throw new Error("Поддерживаются только YouTube-ссылки; Instagram/Reels нужно скачать и передать как видеофайл.");
    }
    return source;
  }

  const path = isAbsolute(source) ? source : resolve(source);
  if (!existsSync(path)) {
    throw new Error(`Файл видео не найден: ${path}. Обработка не запускалась.`);
  }
  let stats;
  try {
    stats = statSync(path);
  } catch {
    throw new Error(`Невозможно прочитать файл видео: ${path}. Обработка не запускалась.`);
  }
  if (!stats.isFile()) {
    throw new Error(`Источник не является файлом: ${path}. Обработка не запускалась.`);
  }
  return path;
}
