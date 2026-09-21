#!/usr/bin/env python3
"""Add word timestamps to an existing transcript with Qwen3 ForcedAligner."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import soundfile as sf
import torch
from qwen_asr import Qwen3ForcedAligner


DEFAULT_MODEL = "Qwen/Qwen3-ForcedAligner-0.6B"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--transcript", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--language", default="Russian")
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--max-seconds", type=float, default=280.0)
    return parser.parse_args()


def read_transcript(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, list):
        return {"segments": payload}, payload
    if not isinstance(payload, dict) or not isinstance(payload.get("segments"), list):
        raise ValueError("Transcript must be a JSON object with a segments array")
    return payload, payload["segments"]


def split_segment(segment: dict[str, Any], max_seconds: float) -> list[dict[str, Any]]:
    start = float(segment.get("start", 0.0))
    end = float(segment.get("end", start))
    text = str(segment.get("text", "")).strip()
    duration = max(0.0, end - start)
    if not text or duration <= 0.0:
        return []
    count = max(1, math.ceil(duration / max_seconds))
    if count == 1:
        return [{"start": start, "end": end, "text": text}]

    words = text.split()
    units: list[dict[str, Any]] = []
    for index in range(count):
        left = math.floor(len(words) * index / count)
        right = math.floor(len(words) * (index + 1) / count)
        unit_text = " ".join(words[left:right]).strip()
        unit_start = start + duration * index / count
        unit_end = start + duration * (index + 1) / count
        if unit_text:
            units.append({"start": unit_start, "end": unit_end, "text": unit_text})
    return units


def read_audio_slice(handle: sf.SoundFile, start: float, end: float) -> Any:
    sample_rate = int(handle.samplerate)
    first = max(0, round(start * sample_rate))
    frames = max(1, round((end - start) * sample_rate))
    handle.seek(min(first, len(handle)))
    audio = handle.read(frames=frames, dtype="float32", always_2d=True)
    if audio.shape[1] > 1:
        audio = audio.mean(axis=1)
    else:
        audio = audio[:, 0]
    return audio, sample_rate


def main() -> int:
    args = parse_args()
    payload, segments = read_transcript(args.transcript)
    if not args.audio.is_file():
        raise FileNotFoundError(args.audio)

    use_cuda = args.device.startswith("cuda") and torch.cuda.is_available()
    device = args.device if use_cuda else "cpu"
    dtype = torch.float16 if use_cuda else torch.float32
    aligner = Qwen3ForcedAligner.from_pretrained(
        args.model,
        device_map=device,
        dtype=dtype,
        attn_implementation="sdpa",
    )

    aligned_segments: list[dict[str, Any]] = []
    all_words: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []

    with sf.SoundFile(str(args.audio)) as audio_file:
        for index, original in enumerate(segments):
            segment = dict(original)
            segment_words: list[dict[str, Any]] = []
            try:
                for unit in split_segment(segment, args.max_seconds):
                    audio = read_audio_slice(audio_file, unit["start"], unit["end"])
                    result = aligner.align(
                        audio=audio,
                        text=unit["text"],
                        language=args.language,
                    )[0]
                    for item in result:
                        word = {
                            "text": item.text,
                            "start": round(unit["start"] + float(item.start_time), 3),
                            "end": round(unit["start"] + float(item.end_time), 3),
                        }
                        segment_words.append(word)
                        all_words.append(word)
            except Exception as exc:  # Keep the canonical GigaAM text on local failures.
                errors.append({"segment": index, "error": str(exc)})

            if segment_words:
                segment["start"] = segment_words[0]["start"]
                segment["end"] = segment_words[-1]["end"]
                segment["words"] = segment_words
                segment["alignment_engine"] = "qwen3-forced-aligner"
            aligned_segments.append(segment)

    result_payload = dict(payload)
    result_payload["segments"] = aligned_segments
    result_payload["words"] = all_words
    result_payload["alignment"] = {
        "engine": "qwen3-forced-aligner",
        "model": args.model,
        "language": args.language,
        "device": device,
        "aligned_segments": len(segments) - len(errors),
        "failed_segments": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
