#!/usr/bin/env python3
"""One-shot local media transcription worker for VoiceSwitch.

The worker accepts one JSON object on stdin and writes machine-readable events
with the VoiceSwitch protocol prefix.  Model imports stay in ``asr_worker`` so
the helpers in this module remain testable with the Python standard library.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import wave
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Generator, Iterable, Sequence

from asr_worker import PROTOCOL_PREFIX, Recognizer, configure_environment


CHECKPOINT_VERSION = 1
TRANSCRIPT_VERSION = 1
CHECKPOINT_NAME = "transcript.checkpoint.json"
WORD_PATTERN = re.compile(r"[^\W_]+(?:[\N{RIGHT SINGLE QUOTATION MARK}'-][^\W_]+)*", re.UNICODE)

_cancel_requested = False
_active_ffmpeg: subprocess.Popen[str] | None = None


class WorkerError(Exception):
    """An error safe to show in the application UI."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class CancelledError(WorkerError):
    def __init__(self) -> None:
        super().__init__("cancelled", "Распознавание отменено.")


def emit(message_type: str, **payload: Any) -> None:
    message = {"type": message_type, **payload}
    print(PROTOCOL_PREFIX + json.dumps(message, ensure_ascii=False), flush=True)


def emit_progress(
    request_id: str,
    phase: str,
    progress: float,
    *,
    message: str,
    completed: int | None = None,
    total: int | None = None,
) -> None:
    payload: dict[str, Any] = {
        "id": request_id,
        "phase": phase,
        "progress": max(0.0, min(1.0, float(progress))),
        "fraction": max(0.0, min(1.0, float(progress))),
        "message": message,
    }
    if completed is not None:
        payload["completed"] = completed
    if total is not None:
        payload["total"] = total
    emit("progress", **payload)


def _handle_termination(_signum: int, _frame: Any) -> None:
    global _cancel_requested
    _cancel_requested = True
    process = _active_ffmpeg
    if process is not None and process.poll() is None:
        process.terminate()


def check_cancelled() -> None:
    if _cancel_requested:
        raise CancelledError()


def normalized_words(text: str) -> list[str]:
    """Return punctuation-independent, case-folded words for exact matching."""
    return [match.group(0).casefold() for match in WORD_PATTERN.finditer(text)]


def deduplicate_prefix(
    previous_text: str,
    current_text: str,
    *,
    minimum_words: int = 3,
) -> str:
    """Remove an exact normalized suffix/prefix overlap from ``current_text``."""
    if minimum_words < 1:
        raise ValueError("minimum_words must be positive")

    previous_words = normalized_words(previous_text)
    current_matches = list(WORD_PATTERN.finditer(current_text))
    current_words = [match.group(0).casefold() for match in current_matches]
    maximum = min(len(previous_words), len(current_words))

    overlap = 0
    for size in range(maximum, minimum_words - 1, -1):
        if previous_words[-size:] == current_words[:size]:
            overlap = size
            break
    if overlap == 0:
        return current_text.strip()

    cut = current_matches[overlap - 1].end()
    remainder = current_text[cut:]
    remainder = re.sub(r"^[\s,.;:!?\N{HORIZONTAL ELLIPSIS}\N{EM DASH}\N{EN DASH}-]+", "", remainder)
    return remainder.strip()


def chunk_boundaries(
    total_frames: int,
    frame_rate: int,
    chunk_seconds: float,
    overlap_seconds: float,
) -> list[tuple[int, int]]:
    """Calculate deterministic overlapping WAV frame ranges."""
    if total_frames < 0:
        raise ValueError("total_frames must not be negative")
    if frame_rate <= 0:
        raise ValueError("frame_rate must be positive")
    if chunk_seconds <= 0:
        raise ValueError("chunk_seconds must be positive")
    if overlap_seconds < 0 or overlap_seconds >= chunk_seconds:
        raise ValueError("overlap_seconds must be non-negative and smaller than chunk_seconds")
    if total_frames == 0:
        return []

    chunk_frames = max(1, round(frame_rate * chunk_seconds))
    overlap_frames = max(0, round(frame_rate * overlap_seconds))
    step_frames = chunk_frames - overlap_frames
    ranges: list[tuple[int, int]] = []
    start = 0
    while start < total_frames:
        end = min(total_frames, start + chunk_frames)
        ranges.append((start, end))
        if end == total_frames:
            break
        start += step_frames
    return ranges


def format_timestamp(seconds: float, *, decimal: str = ",") -> str:
    """Format a non-negative timestamp for SRT (comma) or WebVTT (dot)."""
    milliseconds = max(0, round(float(seconds) * 1000.0))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d}{decimal}{millis:03d}"


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary = Path(output.name)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(
        path,
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )


@contextmanager
def job_work_directory(output_dir: Path) -> Generator[Path, None, None]:
    """Use a parent-visible work directory and clean leftovers from a hard kill."""
    work_directory = output_dir / ".work"
    shutil.rmtree(work_directory, ignore_errors=True)
    work_directory.mkdir(parents=True, exist_ok=True)
    try:
        yield work_directory
    finally:
        shutil.rmtree(work_directory, ignore_errors=True)


def build_fingerprint(
    source: Path,
    *,
    engine: str,
    chunk_seconds: float,
    overlap_seconds: float,
    prompt: str,
) -> dict[str, Any]:
    """Build a resumable fingerprint without persisting the full source path."""
    stat = source.stat()
    config = {
        "chunk_seconds": float(chunk_seconds),
        "overlap_seconds": float(overlap_seconds),
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
    }
    private_identity = {
        "source": str(source.resolve()),
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "engine": engine,
        "config": config,
    }
    digest = hashlib.sha256(
        json.dumps(private_identity, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()
    return {
        "digest": digest,
        "source": source.name,
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "engine": engine,
        "config": config,
    }


def load_checkpoint(path: Path, fingerprint: dict[str, Any]) -> dict[str, Any] | None:
    try:
        checkpoint = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    if checkpoint.get("version") != CHECKPOINT_VERSION:
        return None
    saved = checkpoint.get("fingerprint")
    if not isinstance(saved, dict) or saved.get("digest") != fingerprint.get("digest"):
        return None
    completed = checkpoint.get("completed_chunks")
    segments = checkpoint.get("segments")
    if not isinstance(completed, int) or completed < 0 or not isinstance(segments, list):
        return None
    return checkpoint


def write_checkpoint(
    path: Path,
    *,
    fingerprint: dict[str, Any],
    completed_chunks: int,
    segments: Sequence[dict[str, Any]],
    duration: float,
) -> None:
    atomic_write_json(
        path,
        {
            "version": CHECKPOINT_VERSION,
            "fingerprint": fingerprint,
            "completed_chunks": completed_chunks,
            "duration": duration,
            "segments": list(segments),
        },
    )


def _render_srt(segments: Iterable[dict[str, Any]]) -> str:
    blocks: list[str] = []
    for number, segment in enumerate(segments, start=1):
        blocks.append(
            "\n".join(
                (
                    str(number),
                    f"{format_timestamp(segment['start'])} --> {format_timestamp(segment['end'])}",
                    str(segment["text"]),
                )
            )
        )
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def _render_vtt(segments: Iterable[dict[str, Any]]) -> str:
    blocks = ["WEBVTT"]
    for segment in segments:
        blocks.append(
            "\n".join(
                (
                    f"{format_timestamp(segment['start'], decimal='.')} --> "
                    f"{format_timestamp(segment['end'], decimal='.')}",
                    str(segment["text"]),
                )
            )
        )
    return "\n\n".join(blocks) + "\n"


def export_transcript(
    output_dir: Path,
    *,
    source: Path,
    engine: str,
    duration: float,
    chunk_seconds: float,
    overlap_seconds: float,
    segments: Sequence[dict[str, Any]],
) -> dict[str, Path]:
    """Atomically write the four public transcript formats."""
    output_dir.mkdir(parents=True, exist_ok=True)
    text = "\n".join(str(segment["text"]).strip() for segment in segments if segment.get("text"))
    if text:
        text += "\n"

    metadata = {
        "version": TRANSCRIPT_VERSION,
        "source": {
            "name": source.name,
            "size": source.stat().st_size,
            "mtime_ns": source.stat().st_mtime_ns,
        },
        "engine": engine,
        "duration": duration,
        "configuration": {
            "chunk_seconds": chunk_seconds,
            "overlap_seconds": overlap_seconds,
            "timestamps": "coarse_chunk_boundaries",
        },
        "text": text.rstrip("\n"),
        "segments": list(segments),
    }
    paths = {
        "text": output_dir / "transcript.txt",
        "srt": output_dir / "transcript.srt",
        "vtt": output_dir / "transcript.vtt",
        "json": output_dir / "transcript.json",
    }
    atomic_write_text(paths["text"], text)
    atomic_write_text(paths["srt"], _render_srt(segments))
    atomic_write_text(paths["vtt"], _render_vtt(segments))
    atomic_write_json(paths["json"], metadata)
    return paths


def normalize_media(source: Path, destination: Path) -> None:
    """Normalize the first audio stream to mono 16-bit PCM WAV at 16 kHz."""
    global _active_ffmpeg
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise WorkerError("ffmpeg_missing", "Не найден локальный ffmpeg.")

    command = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-map",
        "0:a:0",
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(destination),
    ]
    check_cancelled()
    try:
        _active_ffmpeg = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        _stdout, stderr = _active_ffmpeg.communicate()
        return_code = _active_ffmpeg.returncode
    except OSError as error:
        raise WorkerError("ffmpeg_failed", "Не удалось запустить локальный ffmpeg.") from error
    finally:
        _active_ffmpeg = None

    check_cancelled()
    if return_code != 0:
        lowered = (stderr or "").casefold()
        no_audio_markers = (
            "matches no streams",
            "does not contain any stream",
            "output file #0 does not contain any stream",
        )
        if any(marker in lowered for marker in no_audio_markers):
            raise WorkerError("no_audio", "В выбранном файле нет аудиодорожки.")
        raise WorkerError("media_read_failed", "Не удалось прочитать аудиодорожку медиафайла.")
    if not destination.exists() or destination.stat().st_size == 0:
        raise WorkerError("no_audio", "В выбранном файле нет аудиодорожки.")


def inspect_wav(path: Path) -> tuple[wave._wave_params, int, int, float]:
    try:
        with wave.open(str(path), "rb") as wav_file:
            parameters = wav_file.getparams()
            frame_rate = wav_file.getframerate()
            total_frames = wav_file.getnframes()
    except (OSError, wave.Error) as error:
        raise WorkerError("invalid_audio", "Не удалось подготовить аудиодорожку.") from error
    if parameters.nchannels != 1 or parameters.sampwidth != 2 or frame_rate != 16000:
        raise WorkerError("invalid_audio", "Аудиодорожка имеет неожиданный формат.")
    duration = total_frames / float(frame_rate) if frame_rate else 0.0
    if total_frames == 0:
        raise WorkerError("no_audio", "В выбранном файле нет аудиоданных.")
    return parameters, frame_rate, total_frames, duration


def write_wav_chunk(
    source: Path,
    destination: Path,
    *,
    parameters: wave._wave_params,
    start_frame: int,
    end_frame: int,
) -> None:
    with wave.open(str(source), "rb") as input_file:
        input_file.setpos(start_frame)
        frames = input_file.readframes(end_frame - start_frame)
    with wave.open(str(destination), "wb") as output_file:
        output_file.setparams(parameters)
        output_file.writeframes(frames)


def _validated_request(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise WorkerError("invalid_request", "Ожидается JSON-объект с параметрами задачи.")
    try:
        request_id = str(request["id"])
        source = Path(str(request["input"])).expanduser()
        output_dir = Path(str(request["output_dir"])).expanduser()
        engine = str(request["engine"])
        cache = Path(str(request["cache"])).expanduser()
    except (KeyError, TypeError, ValueError) as error:
        raise WorkerError("invalid_request", "В запросе не хватает обязательных полей.") from error
    if not request_id:
        raise WorkerError("invalid_request", "Поле id не должно быть пустым.")
    if engine not in {"gigaam", "whisper", "qwen"}:
        raise WorkerError("invalid_engine", f"Неизвестный движок: {engine}")
    if not source.is_file():
        raise WorkerError("input_missing", "Выбранный медиафайл не найден.")

    try:
        chunk_seconds = float(request.get("chunk_seconds", 60.0))
        overlap_seconds = float(request.get("overlap_seconds", 1.5))
    except (TypeError, ValueError) as error:
        raise WorkerError("invalid_request", "Размер блока и перекрытие должны быть числами.") from error
    if chunk_seconds <= 0:
        raise WorkerError("invalid_request", "Размер блока должен быть больше нуля.")
    if overlap_seconds < 0 or overlap_seconds >= chunk_seconds:
        raise WorkerError("invalid_request", "Перекрытие должно быть меньше размера блока.")
    return {
        "id": request_id,
        "source": source,
        "output_dir": output_dir,
        "engine": engine,
        "cache": cache,
        "prompt": str(request.get("prompt") or ""),
        "chunk_seconds": chunk_seconds,
        "overlap_seconds": overlap_seconds,
    }


def process_request(raw_request: Any) -> dict[str, Any]:
    overall_started = time.perf_counter()
    request = _validated_request(raw_request)
    request_id = request["id"]
    source: Path = request["source"]
    output_dir: Path = request["output_dir"]
    engine = request["engine"]
    cache: Path = request["cache"]
    prompt = request["prompt"]
    chunk_seconds = request["chunk_seconds"]
    overlap_seconds = request["overlap_seconds"]

    configure_environment(cache)
    output_dir.mkdir(parents=True, exist_ok=True)
    fingerprint = build_fingerprint(
        source,
        engine=engine,
        chunk_seconds=chunk_seconds,
        overlap_seconds=overlap_seconds,
        prompt=prompt,
    )
    checkpoint_path = output_dir / CHECKPOINT_NAME

    emit_progress(request_id, "normalizing", 0.0, message="Подготовка аудиодорожки…")
    with job_work_directory(output_dir) as temporary_dir:
        normalized = temporary_dir / "normalized.wav"
        normalize_media(source, normalized)
        parameters, frame_rate, total_frames, duration = inspect_wav(normalized)
        ranges = chunk_boundaries(
            total_frames,
            frame_rate,
            chunk_seconds,
            overlap_seconds,
        )
        emit_progress(request_id, "normalizing", 1.0, message="Аудиодорожка подготовлена.")

        checkpoint = load_checkpoint(checkpoint_path, fingerprint)
        completed_chunks = 0
        segments: list[dict[str, Any]] = []
        if checkpoint is not None:
            completed_chunks = min(int(checkpoint["completed_chunks"]), len(ranges))
            segments = [item for item in checkpoint["segments"] if isinstance(item, dict)]

        check_cancelled()
        recognizer: Recognizer | None = None
        if completed_chunks < len(ranges):
            emit_progress(request_id, "loading", 0.0, message="Загрузка модели…")
            recognizer = Recognizer(engine, cache)
            recognizer.load()
            emit_progress(request_id, "loading", 1.0, message="Модель готова.")

        emit_progress(
            request_id,
            "transcribing",
            completed_chunks / max(1, len(ranges)),
            message=(
                f"Продолжение с блока {completed_chunks + 1}."
                if completed_chunks < len(ranges) and completed_chunks > 0
                else "Распознавание аудиодорожки…"
            ),
            completed=completed_chunks,
            total=len(ranges),
        )

        previous_text = " ".join(
            str(segment.get("text", "")).strip() for segment in segments if segment.get("text")
        )
        for index in range(completed_chunks, len(ranges)):
            check_cancelled()
            start_frame, end_frame = ranges[index]
            chunk_path = temporary_dir / f"chunk-{index:06d}.wav"
            write_wav_chunk(
                normalized,
                chunk_path,
                parameters=parameters,
                start_frame=start_frame,
                end_frame=end_frame,
            )
            emit_progress(
                request_id,
                "transcribing",
                index / max(1, len(ranges)),
                message=f"Распознавание блока {index + 1} из {len(ranges)}…",
                completed=index,
                total=len(ranges),
            )
            started = time.perf_counter()
            try:
                assert recognizer is not None
                raw_text, language = recognizer.transcribe(chunk_path, prompt)
            finally:
                chunk_path.unlink(missing_ok=True)
            check_cancelled()

            clean_text = deduplicate_prefix(previous_text, raw_text)
            if clean_text:
                segment_start = start_frame / float(frame_rate)
                if segments:
                    # Перекрытие нужно для контекста ASR, но не должно создавать
                    # одновременно показываемые cue в SRT/VTT.
                    segment_start = max(segment_start, float(segments[-1]["end"]))
                segment = {
                    "index": index,
                    "start": segment_start,
                    "end": end_frame / float(frame_rate),
                    "text": clean_text,
                    "language": language,
                    "latency": time.perf_counter() - started,
                }
                segments.append(segment)
                previous_text = f"{previous_text} {clean_text}".strip()
            completed_chunks = index + 1
            write_checkpoint(
                checkpoint_path,
                fingerprint=fingerprint,
                completed_chunks=completed_chunks,
                segments=segments,
                duration=duration,
            )
            emit_progress(
                request_id,
                "transcribing",
                completed_chunks / max(1, len(ranges)),
                message=f"Готово блоков: {completed_chunks} из {len(ranges)}.",
                completed=completed_chunks,
                total=len(ranges),
            )

        check_cancelled()
        emit_progress(request_id, "exporting", 0.0, message="Сохранение результата…")
        outputs = export_transcript(
            output_dir,
            source=source,
            engine=engine,
            duration=duration,
            chunk_seconds=chunk_seconds,
            overlap_seconds=overlap_seconds,
            segments=segments,
        )
        emit_progress(request_id, "exporting", 1.0, message="Результат сохранён.")

    serialized_outputs = {name: str(path) for name, path in outputs.items()}
    return {
        "id": request_id,
        "engine": engine,
        "source_name": source.name,
        "duration": duration,
        "latency": time.perf_counter() - overall_started,
        "text": "\n".join(str(segment["text"]) for segment in segments),
        "segments": len(segments),
        "segment_count": len(segments),
        "output_dir": str(output_dir),
        "outputs": serialized_outputs,
        "files": serialized_outputs,
    }


def main() -> int:
    signal.signal(signal.SIGTERM, _handle_termination)
    signal.signal(signal.SIGINT, _handle_termination)
    request_id = "unknown"
    engine: str | None = None
    try:
        raw = sys.stdin.read().strip()
        if not raw:
            raise WorkerError("invalid_request", "Не получен JSON-запрос.")
        request = json.loads(raw)
        if isinstance(request, dict):
            request_id = str(request.get("id") or "unknown")
            engine = str(request.get("engine")) if request.get("engine") is not None else None
        result = process_request(request)
        emit("result", **result)
        return 0
    except CancelledError as error:
        emit("error", id=request_id, engine=engine, code=error.code, message=str(error))
        return 130
    except WorkerError as error:
        emit("error", id=request_id, engine=engine, code=error.code, message=str(error))
        return 1
    except json.JSONDecodeError:
        emit(
            "error",
            id=request_id,
            engine=engine,
            code="invalid_json",
            message="Не удалось прочитать JSON-запрос.",
        )
        return 1
    except Exception as error:
        emit(
            "error",
            id=request_id,
            engine=engine,
            code="internal_error",
            message=f"Ошибка локального распознавания: {error}",
        )
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
