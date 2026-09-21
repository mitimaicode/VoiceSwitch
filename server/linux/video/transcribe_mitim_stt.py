#!/usr/bin/env python3
"""Transcribe long WAV files through the local loopback-only mitim-stt service.

The resident service accepts files up to 30 minutes and returns one text block.
This adapter cuts long recordings into timestamped pieces, adds a small overlap,
deduplicates exact words at joins, and checkpoints every completed request.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path
from typing import Any


WORD_RE = re.compile(r"[\wёЁ-]+", re.UNICODE)


def resolve_binary(name: str, configured: Path | None) -> str:
    resolved = str(configured.expanduser().resolve()) if configured else shutil.which(name)
    if not resolved:
        raise RuntimeError(f"{name} не найден")
    path = Path(resolved)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"{name} недоступен для запуска: {path}")
    return resolved


def media_duration(path: Path, ffprobe: str) -> float:
    if ffprobe:
        completed = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if completed.returncode == 0:
            try:
                duration = float(completed.stdout.strip())
                if duration > 0:
                    return duration
            except ValueError:
                pass
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / float(audio.getframerate())


def post_transcribe(endpoint: str, audio: Path, engine: str) -> dict[str, Any]:
    body = json.dumps({"path": str(audio.resolve()), "engine": engine}).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    result: Any = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=3600) as response:
                result = json.load(response)
            break
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code not in {429, 500, 502, 503, 504} or attempt == 3:
                raise RuntimeError(f"mitim-stt HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            if attempt == 3:
                raise RuntimeError(f"mitim-stt недоступен: {error}") from error
        time.sleep(2**attempt)
    if not isinstance(result, dict) or "text" not in result:
        raise RuntimeError(f"Некорректный ответ mitim-stt: {result!r}")
    return result


def normalized_words(text: str) -> list[str]:
    return [word.casefold() for word in WORD_RE.findall(text)]


def remove_overlap(previous: str, current: str, maximum_words: int = 24) -> str:
    """Remove an exact 3+ word suffix/prefix repeated by overlapped audio."""
    previous_words = normalized_words(previous)
    current_matches = list(WORD_RE.finditer(current))
    current_words = [match.group(0).casefold() for match in current_matches]
    limit = min(maximum_words, len(previous_words), len(current_words))
    for count in range(limit, 2, -1):
        if previous_words[-count:] == current_words[:count]:
            return current[current_matches[count - 1].end() :].lstrip(" ,.;:—–-\t")
    return current.strip()


def quality_flags(text: str, duration: float, language: Any, engine: Any) -> list[str]:
    flags: list[str] = []
    words = normalized_words(text)
    if not words:
        return ["empty_text"]
    if duration >= 20 and len(words) / duration < 0.03:
        flags.append("low_text_density")
    if len(words) >= 12:
        most_common = max(words.count(word) for word in set(words))
        if most_common / len(words) >= 0.45:
            flags.append("high_token_repetition")
    letters = [character for character in text if character.isalpha()]
    cyrillic = [character for character in letters if "а" <= character.casefold() <= "я" or character.casefold() == "ё"]
    if str(language) == "ru" and str(engine).startswith("gigaam") and len(letters) >= 20:
        if len(cyrillic) / len(letters) < 0.2:
            flags.append("unexpected_script_for_russian")
    return flags


def extract_chunk(ffmpeg: str, source: Path, output: Path, start: float, duration: float) -> None:
    command = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        f"{start:.3f}",
        "-t",
        f"{duration:.3f}",
        "-i",
        str(source),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(output),
    ]
    subprocess.run(command, check=True, timeout=180)


def atomic_write_json(path: Path, value: Any) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Long-form adapter for local mitim-stt")
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--endpoint", default="http://127.0.0.1:18790/transcribe")
    parser.add_argument("--engine", choices=("auto", "gigaam", "whisper"), default="auto")
    parser.add_argument("--chunk-seconds", type=float, default=60.0)
    parser.add_argument("--overlap-seconds", type=float, default=1.5)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ffmpeg-path", type=Path)
    parser.add_argument("--ffprobe-path", type=Path)
    args = parser.parse_args()

    source = args.audio.resolve(strict=True)
    ffmpeg = resolve_binary("ffmpeg", args.ffmpeg_path)
    ffprobe = resolve_binary("ffprobe", args.ffprobe_path)
    if args.chunk_seconds < 30 or args.chunk_seconds > 600:
        raise ValueError("chunk-seconds должен быть от 30 до 600")
    if args.overlap_seconds < 0 or args.overlap_seconds >= args.chunk_seconds / 4:
        raise ValueError("Некорректный overlap-seconds")

    total_duration = media_duration(source, ffprobe)
    checkpoint = args.checkpoint or source.with_suffix(".mitim-stt-checkpoint.json")
    fingerprint = {
        "path": str(source),
        "size": source.stat().st_size,
        "mtime_ns": source.stat().st_mtime_ns,
        "duration": round(total_duration, 3),
        "chunk_seconds": args.chunk_seconds,
        "overlap_seconds": args.overlap_seconds,
        "endpoint": args.endpoint,
        "requested_engine": args.engine,
        "ffmpeg_path": ffmpeg,
        "ffprobe_path": ffprobe,
    }

    state: dict[str, Any] = {"fingerprint": fingerprint, "segments": []}
    if checkpoint.exists():
        candidate = json.loads(checkpoint.read_text(encoding="utf-8"))
        if candidate.get("fingerprint") == fingerprint and isinstance(candidate.get("segments"), list):
            state = candidate

    segment_count = max(1, math.ceil(total_duration / args.chunk_seconds))
    done = {int(segment["index"]): segment for segment in state["segments"]}
    started_all = time.perf_counter()

    for index in range(segment_count):
        if index in done:
            print(f"[{index + 1}/{segment_count}] checkpoint", file=sys.stderr, flush=True)
            continue

        nominal_start = index * args.chunk_seconds
        nominal_end = min(total_duration, (index + 1) * args.chunk_seconds)
        actual_start = max(0.0, nominal_start - (args.overlap_seconds if index else 0.0))
        actual_duration = nominal_end - actual_start
        print(
            f"[{index + 1}/{segment_count}] {nominal_start:.1f}-{nominal_end:.1f}s -> mitim-stt",
            file=sys.stderr,
            flush=True,
        )
        with tempfile.TemporaryDirectory(prefix="youtube-mitim-stt-") as temporary:
            chunk = Path(temporary) / f"chunk-{index:04d}.wav"
            extract_chunk(ffmpeg, source, chunk, actual_start, actual_duration)
            result = post_transcribe(args.endpoint, chunk, args.engine)

        previous_text = ""
        if index > 0 and index - 1 in done:
            previous_text = str(done[index - 1].get("text", ""))
        text = remove_overlap(previous_text, str(result.get("text", "")).strip())
        segment = {
            "index": index,
            "start": round(nominal_start, 3),
            "end": round(nominal_end, 3),
            "text": text,
            "confidence": None,
            "source": f"mitim-stt:{result.get('engine', args.engine)}",
            "engine": result.get("engine", args.engine),
            "language": result.get("language"),
            "latency": result.get("latency"),
            "quality_flags": quality_flags(
                text,
                nominal_end - nominal_start,
                result.get("language"),
                result.get("engine", args.engine),
            ),
        }
        done[index] = segment
        state["segments"] = [done[key] for key in sorted(done)]
        atomic_write_json(checkpoint, state)

    segments = [done[key] for key in sorted(done)]
    for segment in segments:
        segment.setdefault(
            "quality_flags",
            quality_flags(
                str(segment.get("text", "")),
                float(segment.get("end", 0)) - float(segment.get("start", 0)),
                segment.get("language"),
                segment.get("engine"),
            ),
        )
    payload = {
        "segments": segments,
        "metadata": {
            "adapter": "mitim-stt-long-form-v2",
            "requested_engine": args.engine,
            "engines_used": sorted({str(segment.get("engine")) for segment in segments}),
            "duration": round(total_duration, 3),
            "segment_count": len(segments),
            "empty_segment_count": sum(not str(segment.get("text", "")).strip() for segment in segments),
            "flagged_segment_count": sum(bool(segment.get("quality_flags")) for segment in segments),
            "coverage": {
                "start": 0.0,
                "end": round(max((float(segment.get("end", 0)) for segment in segments), default=0.0), 3),
                "expected_end": round(total_duration, 3),
            },
            "elapsed": round(time.perf_counter() - started_all, 3),
            "checkpoint": str(checkpoint),
        },
    }
    rendered = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
