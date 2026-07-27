#!/usr/bin/env python3
"""Run the same recorded WAV files through VoiceSwitch's Python engines."""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Any

PROTOCOL_PREFIX = "__VOICESWITCH_JSON__"
DEFAULT_ENGINES = ("gigaam", "whisper", "qwen")


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wav_file:
        return wav_file.getnframes() / float(wav_file.getframerate())


def read_protocol_message(
    process: subprocess.Popen[str],
    *,
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    assert process.stdout is not None

    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        readable, _, _ = select.select([process.stdout], [], [], min(1.0, remaining))
        if not readable:
            if process.poll() is not None:
                raise RuntimeError(
                    f"Worker exited unexpectedly with code {process.returncode}."
                )
            continue

        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                raise RuntimeError(
                    f"Worker exited unexpectedly with code {process.returncode}."
                )
            continue

        if line.startswith(PROTOCOL_PREFIX):
            return json.loads(line[len(PROTOCOL_PREFIX) :])
        print(f"[worker] {line.rstrip()}", flush=True)

    raise TimeoutError(f"No worker protocol message received within {timeout:.0f}s.")


def persist(output: Path, payload: dict[str, Any]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)


def run_engine(
    *,
    engine: str,
    python: Path,
    worker: Path,
    cache: Path,
    audio_files: list[Path],
    output: Path,
    benchmark: dict[str, Any],
) -> None:
    environment = os.environ.copy()
    environment.update(
        {
            "HF_HOME": str(cache / "huggingface"),
            "TOKENIZERS_PARALLELISM": "false",
            "PYTHONUNBUFFERED": "1",
        }
    )

    command = [
        str(python),
        str(worker),
        "--serve",
        "--engine",
        engine,
        "--cache",
        str(cache),
    ]
    print(f"\n=== {engine}: starting worker ===", flush=True)
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=environment,
    )

    try:
        while True:
            message = read_protocol_message(process, timeout=600)
            if message.get("type") == "ready":
                break
            if message.get("type") == "error":
                raise RuntimeError(message.get("message") or "Worker startup failed.")

        engine_results: list[dict[str, Any]] = []
        benchmark["engines"][engine] = engine_results
        persist(output, benchmark)

        for index, audio in enumerate(audio_files, start=1):
            duration = wav_duration(audio)
            request = {
                "id": audio.stem,
                "audio": str(audio.resolve()),
                "duration": duration,
                "prompt": "",
            }
            print(
                f"[{engine}] {index}/{len(audio_files)} {audio.name} "
                f"({duration:.1f}s)",
                flush=True,
            )
            assert process.stdin is not None
            wall_started = time.perf_counter()
            process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            process.stdin.flush()

            while True:
                message = read_protocol_message(process, timeout=900)
                if message.get("id") != audio.stem:
                    continue
                message["wall_latency"] = time.perf_counter() - wall_started
                engine_results.append(message)
                persist(output, benchmark)
                if message.get("type") == "error":
                    print(
                        f"[{engine}] ERROR {audio.name}: {message.get('message')}",
                        flush=True,
                    )
                else:
                    print(
                        f"[{engine}] done in {message['wall_latency']:.2f}s",
                        flush=True,
                    )
                break
    finally:
        if process.stdin is not None:
            process.stdin.close()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--audio-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--engines",
        nargs="+",
        choices=DEFAULT_ENGINES,
        default=list(DEFAULT_ENGINES),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    audio_files = sorted(arguments.audio_dir.glob("*.wav"))
    if not audio_files:
        raise SystemExit(f"No WAV files found in {arguments.audio_dir}")

    benchmark: dict[str, Any] = {
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "audio_dir": str(arguments.audio_dir.resolve()),
        "samples": [
            {
                "id": path.stem,
                "file": path.name,
                "duration": wav_duration(path),
                "category": "story" if path.name.startswith("story_") else "music",
            }
            for path in audio_files
        ],
        "engines": {},
    }
    persist(arguments.output, benchmark)

    for engine in arguments.engines:
        run_engine(
            engine=engine,
            python=arguments.python,
            worker=arguments.worker,
            cache=arguments.cache,
            audio_files=audio_files,
            output=arguments.output,
            benchmark=benchmark,
        )

    print(f"\nSaved: {arguments.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
