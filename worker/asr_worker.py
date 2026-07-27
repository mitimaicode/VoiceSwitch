#!/usr/bin/env python3
"""Persistent local ASR worker for VoiceSwitch.

The process loads exactly one model at a time and communicates over JSON Lines.
Machine-readable messages are prefixed so library progress output cannot corrupt
the protocol.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import traceback
import wave
from pathlib import Path
from typing import Any

PROTOCOL_PREFIX = "__VOICESWITCH_JSON__"
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
GIGAAM_MODEL = "v3_e2e_rnnt"


def emit(message_type: str, **payload: Any) -> None:
    message = {"type": message_type, **payload}
    print(
        PROTOCOL_PREFIX + json.dumps(message, ensure_ascii=False),
        flush=True,
    )


def configure_environment(cache_root: Path) -> None:
    cache_root.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(cache_root / "huggingface"))
    os.environ.setdefault("TORCH_HOME", str(cache_root / "torch"))
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    runtime_bin = cache_root.parent / "bin"
    if runtime_bin.exists():
        os.environ["PATH"] = f"{runtime_bin}{os.pathsep}{os.environ.get('PATH', '')}"


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wav_file:
        return wav_file.getnframes() / float(wav_file.getframerate())


def split_wav_for_gigaam(
    source: Path,
    *,
    maximum_seconds: float = 22.0,
) -> tuple[list[Path], tempfile.TemporaryDirectory[str] | None]:
    """Split on a low-energy region so every GigaAM chunk stays below 25 s."""
    with wave.open(str(source), "rb") as wav_file:
        parameters = wav_file.getparams()
        frame_rate = wav_file.getframerate()
        channels = wav_file.getnchannels()
        sample_width = wav_file.getsampwidth()
        frame_count = wav_file.getnframes()
        frames = wav_file.readframes(frame_count)

    if frame_count / float(frame_rate) <= 24.0:
        return [source], None

    if channels != 1 or sample_width != 2:
        raise ValueError("Ожидается mono PCM WAV 16-bit.")

    import numpy as np

    samples = np.frombuffer(frames, dtype="<i2")
    maximum = int(frame_rate * maximum_seconds)
    minimum = int(frame_rate * 8.0)
    search_span = int(frame_rate * 5.0)
    analysis_window = max(1, int(frame_rate * 0.12))

    boundaries = [0]
    start = 0
    total = len(samples)
    while total - start > maximum:
        hard_end = min(total, start + maximum)
        search_start = max(start + minimum, hard_end - search_span)
        best_end = hard_end
        best_energy = float("inf")

        for candidate in range(search_start, hard_end, analysis_window):
            segment = samples[candidate : min(candidate + analysis_window, hard_end)]
            if segment.size == 0:
                continue
            energy = float(np.mean(np.abs(segment.astype(np.float32))))
            if energy < best_energy:
                best_energy = energy
                best_end = candidate + segment.size // 2

        boundaries.append(best_end)
        start = best_end
    boundaries.append(total)

    temporary = tempfile.TemporaryDirectory(prefix="voiceswitch-gigaam-")
    chunks: list[Path] = []
    for index, (left, right) in enumerate(zip(boundaries, boundaries[1:])):
        output = Path(temporary.name) / f"chunk-{index:03d}.wav"
        with wave.open(str(output), "wb") as wav_file:
            wav_file.setparams(parameters)
            wav_file.writeframes(samples[left:right].astype("<i2").tobytes())
        chunks.append(output)
    return chunks, temporary


class Recognizer:
    def __init__(self, engine: str, cache_root: Path):
        self.engine = engine
        self.cache_root = cache_root
        self.model: Any = None

    def load(self) -> None:
        if self.engine == "whisper":
            emit("loading", engine=self.engine, message="Загрузка Whisper Large V3 Turbo…")
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            self.model = ModelHolder.get_model(WHISPER_MODEL, mx.float16)
        elif self.engine == "gigaam":
            emit("loading", engine=self.engine, message="Загрузка GigaAM v3 E2E RNNT…")
            import gigaam

            self.model = gigaam.load_model(
                GIGAAM_MODEL,
                device="cpu",
                fp16_encoder=False,
                download_root=str(self.cache_root / "gigaam"),
            )
        else:
            raise ValueError(f"Неизвестный движок: {self.engine}")

    def transcribe(self, audio: Path, prompt: str) -> tuple[str, str | None]:
        if self.engine == "whisper":
            return self._transcribe_whisper(audio, prompt)
        return self._transcribe_gigaam(audio), "ru"

    def _transcribe_whisper(
        self,
        audio: Path,
        prompt: str,
    ) -> tuple[str, str | None]:
        import mlx_whisper

        result = mlx_whisper.transcribe(
            str(audio),
            path_or_hf_repo=WHISPER_MODEL,
            verbose=None,
            temperature=0.0,
            task="transcribe",
            language=None,
            initial_prompt=prompt.strip() or None,
            condition_on_previous_text=False,
            word_timestamps=False,
            no_speech_threshold=0.65,
            hallucination_silence_threshold=1.5,
        )
        return result.get("text", "").strip(), result.get("language")

    def _transcribe_gigaam(self, audio: Path) -> str:
        chunks, temporary = split_wav_for_gigaam(audio)
        try:
            texts: list[str] = []
            for chunk in chunks:
                result = self.model.transcribe(str(chunk))
                text = getattr(result, "text", str(result)).strip()
                if text:
                    texts.append(text)
            return " ".join(texts).strip()
        finally:
            if temporary is not None:
                temporary.cleanup()


def serve(engine: str, cache_root: Path) -> int:
    configure_environment(cache_root)
    recognizer = Recognizer(engine, cache_root)
    try:
        recognizer.load()
    except Exception as error:
        emit(
            "error",
            id="startup",
            engine=engine,
            message=f"Не удалось загрузить модель: {error}",
        )
        traceback.print_exc(file=sys.stderr)
        return 1

    emit("ready", engine=engine)
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        request_id = "unknown"
        try:
            request = json.loads(line)
            request_id = str(request["id"])
            audio = Path(request["audio"])
            duration = float(request.get("duration") or wav_duration(audio))
            prompt = str(request.get("prompt") or "")

            started = time.perf_counter()
            text, language = recognizer.transcribe(audio, prompt)
            latency = time.perf_counter() - started
            emit(
                "result",
                id=request_id,
                engine=engine,
                text=text,
                language=language,
                latency=latency,
                duration=duration,
            )
        except Exception as error:
            emit(
                "error",
                id=request_id,
                engine=engine,
                message=str(error),
            )
            traceback.print_exc(file=sys.stderr)
    return 0


def download(engine: str, cache_root: Path) -> int:
    configure_environment(cache_root)
    recognizer = Recognizer(engine, cache_root)
    recognizer.load()
    emit("ready", engine=engine, message="Модель загружена и готова.")
    return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VoiceSwitch local ASR worker")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--serve", action="store_true")
    mode.add_argument("--download", action="store_true")
    parser.add_argument("--engine", choices=("gigaam", "whisper"), required=True)
    parser.add_argument("--cache", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.serve:
        return serve(arguments.engine, arguments.cache)
    return download(arguments.engine, arguments.cache)


if __name__ == "__main__":
    raise SystemExit(main())
