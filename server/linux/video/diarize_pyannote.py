#!/usr/bin/env python3
"""Assign pyannote speaker labels to transcript segments and words."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

import torch
import soundfile as sf
from huggingface_hub import get_token
from pyannote.audio import Pipeline


DEFAULT_MODEL = "pyannote/speaker-diarization-community-1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--transcript", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--num-speakers", type=int)
    parser.add_argument("--min-speakers", type=int)
    parser.add_argument("--max-speakers", type=int)
    return parser.parse_args()


def load_transcript(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, list):
        return {"segments": payload}, payload
    if not isinstance(payload, dict) or not isinstance(payload.get("segments"), list):
        raise ValueError("Transcript must be a JSON object with a segments array")
    return payload, payload["segments"]


def best_speaker(start: float, end: float, turns: list[dict[str, Any]]) -> str | None:
    best_label: str | None = None
    best_overlap = 0.0
    midpoint = (start + end) / 2.0
    nearest_distance = float("inf")
    for turn in turns:
        overlap = max(0.0, min(end, turn["end"]) - max(start, turn["start"]))
        if overlap > best_overlap:
            best_overlap = overlap
            best_label = turn["speaker"]
        if best_overlap == 0.0:
            turn_midpoint = (turn["start"] + turn["end"]) / 2.0
            distance = abs(midpoint - turn_midpoint)
            if distance < nearest_distance:
                nearest_distance = distance
                best_label = turn["speaker"]
    return best_label


def main() -> int:
    args = parse_args()
    token = (
        os.environ.get("HF_TOKEN")
        or os.environ.get("HUGGINGFACE_HUB_TOKEN")
        or get_token()
    )
    if not token:
        raise RuntimeError(
            "Hugging Face authentication is required after accepting the "
            "pyannote community-1 model terms"
        )

    payload, segments = load_transcript(args.transcript)
    if not args.audio.is_file():
        raise FileNotFoundError(args.audio)

    pipeline = Pipeline.from_pretrained(args.model, token=token)
    device = torch.device(args.device if torch.cuda.is_available() else "cpu")
    pipeline.to(device)
    call_args = {
        key: value
        for key, value in {
            "num_speakers": args.num_speakers,
            "min_speakers": args.min_speakers,
            "max_speakers": args.max_speakers,
        }.items()
        if value is not None
    }
    samples, sample_rate = sf.read(
        args.audio,
        dtype="float32",
        always_2d=True,
    )
    audio = {
        "waveform": torch.from_numpy(samples.T.copy()),
        "sample_rate": int(sample_rate),
    }
    diarization_output = pipeline(audio, **call_args)
    annotation = getattr(diarization_output, "speaker_diarization", diarization_output)
    turns = [
        {
            "start": round(float(turn.start), 3),
            "end": round(float(turn.end), 3),
            "speaker": str(speaker),
        }
        for turn, _, speaker in annotation.itertracks(yield_label=True)
    ]

    diarized_segments: list[dict[str, Any]] = []
    for original in segments:
        segment = dict(original)
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        segment["speaker"] = best_speaker(start, end, turns)
        words = segment.get("words")
        if isinstance(words, list):
            labeled_words = []
            for original_word in words:
                word = dict(original_word)
                word_start = float(word.get("start", start))
                word_end = float(word.get("end", word_start))
                word["speaker"] = best_speaker(word_start, word_end, turns)
                labeled_words.append(word)
            segment["words"] = labeled_words
        diarized_segments.append(segment)

    result_payload = dict(payload)
    result_payload["segments"] = diarized_segments
    result_payload["speaker_turns"] = turns
    result_payload["speakers"] = sorted({turn["speaker"] for turn in turns})
    result_payload["diarization"] = {
        "engine": "pyannote.audio",
        "model": args.model,
        "device": str(device),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
