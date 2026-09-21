import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { validateVideoSource } from "./source-validation.js";

test("rejects media marker before a flow can be created", () => {
  assert.throws(
    () => validateVideoSource("media:"),
    /маркер `media:`/,
  );
});

test("rejects a missing local file", () => {
  assert.throws(
    () => validateVideoSource(join(tmpdir(), "video-does-not-exist.mp4")),
    /Файл видео не найден/,
  );
});

test("returns an existing regular file as an absolute path", () => {
  const root = mkdtempSync(join(tmpdir(), "video-source-"));
  const file = join(root, "clip.mp4");
  writeFileSync(file, "test");
  assert.equal(validateVideoSource(file), file);
});

test("accepts YouTube URLs and rejects unsupported web sources", () => {
  assert.equal(validateVideoSource("https://youtu.be/abc123"), "https://youtu.be/abc123");
  assert.throws(
    () => validateVideoSource("https://www.instagram.com/reel/abc123/"),
    /только YouTube-ссылки/,
  );
});
