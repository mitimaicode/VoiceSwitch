#!/usr/bin/env python3
"""Resident local speech-to-text service for OpenClaw.

GigaAM v3 E2E RNNT is the primary Russian recognizer.  Whisper Turbo is
loaded only when explicitly requested or when the primary recognizer fails.
The HTTP endpoint is loopback-only; OpenClaw calls it through transcribe.py.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import traceback
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

GIGAAM_MODEL = "v3_e2e_rnnt"
MAX_INPUT_BYTES = 50 * 1024 * 1024
MAX_DURATION_SECONDS = 30 * 60
REQUEST_TIMEOUT_SECONDS = 180


def _duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / float(audio.getframerate())


def _split_wav_for_gigaam(
    source: Path,
    *,
    maximum_seconds: float = 22.0,
) -> tuple[list[Path], tempfile.TemporaryDirectory[str] | None]:
    """Split long PCM WAV files near a low-energy point.

    GigaAM's short-form transcribe API is limited to roughly 25 seconds.  The
    VoiceSwitch worker uses the same strategy, with a little safety margin.
    """

    with wave.open(str(source), "rb") as audio:
        parameters = audio.getparams()
        frame_rate = audio.getframerate()
        channels = audio.getnchannels()
        sample_width = audio.getsampwidth()
        frame_count = audio.getnframes()
        frames = audio.readframes(frame_count)

    if frame_count / float(frame_rate) <= 24.0:
        return [source], None
    if channels != 1 or sample_width != 2:
        raise ValueError("Ожидается mono PCM WAV 16-bit после нормализации.")

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
                best_end = candidate + max(1, segment.size // 2)
        boundaries.append(best_end)
        start = best_end
    boundaries.append(total)

    temporary = tempfile.TemporaryDirectory(prefix="mitim-stt-gigaam-")
    chunks: list[Path] = []
    for index, (left, right) in enumerate(zip(boundaries, boundaries[1:])):
        output = Path(temporary.name) / f"chunk-{index:03d}.wav"
        with wave.open(str(output), "wb") as chunk:
            chunk.setnchannels(1)
            chunk.setsampwidth(2)
            chunk.setframerate(frame_rate)
            chunk.writeframes(samples[left:right].astype("<i2").tobytes())
        chunks.append(output)
    return chunks, temporary


class SpeechEngine:
    def __init__(self, cache_root: Path, work_root: Path) -> None:
        self.cache_root = cache_root
        self.work_root = work_root
        self.work_root.mkdir(parents=True, exist_ok=True)
        self._gpu_lock = threading.Lock()
        self._whisper_lock = threading.Lock()
        self.gigaam: Any = None
        self.whisper: Any = None
        self.device = "cpu"

        os.environ.setdefault("HF_HOME", str(cache_root / "huggingface"))
        os.environ.setdefault("TORCH_HOME", str(cache_root / "torch"))
        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

        # GigaAM's Hugging Face modeling file invokes ``ffmpeg`` by name.
        # imageio-ffmpeg supplies a pinned Linux binary inside the venv, so
        # expose that binary to both our normalizer and the model code.
        import imageio_ffmpeg

        ffmpeg_executable = Path(imageio_ffmpeg.get_ffmpeg_exe())
        # GigaAM invokes the executable by the literal name ``ffmpeg``.
        # imageio-ffmpeg ships a pinned binary with a versioned filename, so
        # expose it through a private service-local symlink rather than
        # changing the system installation.
        ffmpeg_bin = self.work_root.parent / "bin"
        ffmpeg_bin.mkdir(parents=True, exist_ok=True)
        ffmpeg_link = ffmpeg_bin / "ffmpeg"
        if not ffmpeg_link.exists():
            ffmpeg_link.symlink_to(ffmpeg_executable)
        os.environ["PATH"] = f"{ffmpeg_bin}{os.pathsep}{os.environ.get('PATH', '')}"

        import torch

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA недоступна: GPU-режим mitim-stt не активирован.")
        self.device = "cuda"

        import gigaam

        print("Loading GigaAM v3 E2E RNNT on CUDA", flush=True)
        self.gigaam = gigaam.load_model(
            GIGAAM_MODEL,
            device=self.device,
            fp16_encoder=True,
            download_root=str(cache_root / "gigaam"),
        )
        print("GigaAM ready", flush=True)

    def _normalize(self, source: Path, temporary: Path) -> Path:
        import imageio_ffmpeg

        output = temporary / "normalized.wav"
        ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
        command = [
            ffmpeg,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
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
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        if completed.returncode != 0 or not output.exists():
            detail = (completed.stderr or "ffmpeg не создал WAV").strip()
            raise RuntimeError(f"Не удалось подготовить аудио: {detail[-500:]}")
        return output

    def _gigaam_transcribe(self, audio: Path) -> str:
        chunks, temporary = _split_wav_for_gigaam(audio)
        try:
            texts: list[str] = []
            for chunk in chunks:
                result = self.gigaam.transcribe(str(chunk))
                text = getattr(result, "text", str(result)).strip()
                if text:
                    texts.append(text)
            return " ".join(texts).strip()
        finally:
            if temporary is not None:
                temporary.cleanup()

    def _load_whisper(self) -> Any:
        if self.whisper is not None:
            return self.whisper
        with self._whisper_lock:
            if self.whisper is None:
                import whisper

                print("Loading Whisper Turbo fallback on CUDA", flush=True)
                self.whisper = whisper.load_model(
                    "turbo",
                    device=self.device,
                    download_root=str(self.cache_root / "whisper"),
                )
                print("Whisper fallback ready", flush=True)
        return self.whisper

    def _whisper_transcribe(self, audio: Path) -> tuple[str, str | None]:
        model = self._load_whisper()
        result = model.transcribe(
            str(audio),
            task="transcribe",
            language=None,
            temperature=0.0,
            condition_on_previous_text=False,
            word_timestamps=False,
            fp16=True,
            verbose=False,
        )
        return str(result.get("text", "")).strip(), result.get("language")

    def transcribe(self, source: Path, engine: str = "auto") -> dict[str, Any]:
        try:
            source = source.resolve(strict=True)
            metadata = source.stat()
        except FileNotFoundError as error:
            raise ValueError(f"Аудиофайл не найден: {source}") from error
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"Аудиофайл должен быть обычным файлом: {source}")
        if metadata.st_size < 1024:
            raise ValueError("Аудиофайл слишком мал.")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise ValueError("Аудиофайл больше 50 МБ.")

        started = time.perf_counter()
        with self._gpu_lock:
            with tempfile.TemporaryDirectory(prefix="mitim-stt-request-", dir=self.work_root) as work:
                normalized = self._normalize(source, Path(work))
                duration = _duration(normalized)
                if duration <= 0 or duration > MAX_DURATION_SECONDS:
                    raise ValueError("Длительность аудио должна быть от 0 до 30 минут.")

                if engine == "whisper":
                    text, language = self._whisper_transcribe(normalized)
                    used_engine = "whisper"
                else:
                    try:
                        text = self._gigaam_transcribe(normalized)
                        language = "ru"
                        used_engine = "gigaam"
                    except Exception:
                        if engine == "gigaam":
                            raise
                        traceback.print_exc()
                        text, language = self._whisper_transcribe(normalized)
                        used_engine = "whisper-fallback"

                    if engine == "auto" and not text:
                        text, language = self._whisper_transcribe(normalized)
                        used_engine = "whisper-fallback-empty"

        return {
            "text": text,
            "language": language,
            "engine": used_engine,
            "duration": duration,
            "latency": time.perf_counter() - started,
        }


class RequestHandler(BaseHTTPRequestHandler):
    service: "STTHTTPServer"

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}", flush=True)

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path != "/health":
            self._json(404, {"error": "not found"})
            return
        self._json(
            200,
            {"ok": True, "ready": True, "device": self.service.engine.device},
        )

    def do_POST(self) -> None:
        if self.path != "/transcribe":
            self._json(404, {"error": "not found"})
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > 64 * 1024:
                raise ValueError("Некорректный размер JSON-запроса.")
            request = json.loads(self.rfile.read(content_length))
            source = Path(str(request.get("path", ""))).expanduser()
            if not source.is_absolute():
                raise ValueError("Путь к аудио должен быть абсолютным.")
            engine = str(request.get("engine", "auto"))
            if engine not in {"auto", "gigaam", "whisper"}:
                raise ValueError("engine должен быть auto, gigaam или whisper.")
            if not self.service.admission.acquire(blocking=False):
                self._json(429, {"error": "STT queue is full"})
                return
            try:
                result = self.service.engine.transcribe(source, engine)
            finally:
                self.service.admission.release()
            self._json(200, result)
        except Exception as error:
            traceback.print_exc()
            self._json(400, {"error": str(error)})


class STTHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], engine: SpeechEngine) -> None:
        super().__init__(address, RequestHandler)
        self.engine = engine
        self.admission = threading.BoundedSemaphore(2)
        RequestHandler.service = self


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18790)
    args = parser.parse_args()

    args.cache.mkdir(parents=True, exist_ok=True)
    args.work.mkdir(parents=True, exist_ok=True)
    service = SpeechEngine(args.cache, args.work)
    server = STTHTTPServer((args.host, args.port), service)
    print(f"mitim-stt listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
