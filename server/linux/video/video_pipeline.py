#!/usr/bin/env python3
"""Local-first video transcription pipeline built around resident mitim-stt.

Supported sources:
- YouTube URLs through yt-dlp
- local audio/video files, including media downloaded from Telegram

GigaAM is the canonical Russian ASR. YouTube captions are preserved only as
auxiliary evidence. Optional external commands can add forced alignment and
speaker diarization without changing the stable voice-message endpoint.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from telegram_publication import DEFAULT_CONNECTION as DEFAULT_TELEGRAM_CONNECTION
from telegram_publication import build_publication_plan


PIPELINE_VERSION = "mitim-video-pipeline-v3"
PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT_ROOT = PROJECT_DIR / "knowledge" / "videos"
DEFAULT_STT_ADAPTER = PROJECT_DIR / "transcribe_mitim_stt.py"
DEFAULT_OLLAMA_ENRICHER = PROJECT_DIR / "enrich_ollama.py"
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"}
PROFILES = {
    "quick": {"alignment": False, "diarization": False, "visuals": False, "frame_interval": 0},
    "standard": {"alignment": True, "diarization": False, "visuals": True, "frame_interval": 300},
    "interview": {"alignment": True, "diarization": True, "visuals": True, "frame_interval": 300},
    "multilingual": {"alignment": True, "diarization": False, "visuals": True, "frame_interval": 300},
    "deep": {"alignment": True, "diarization": True, "visuals": True, "frame_interval": 60},
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def atomic_write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def run_cmd(command: list[str], *, timeout: int = 3600) -> str:
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "command failed").strip()
        raise RuntimeError(f"Команда завершилась с кодом {completed.returncode}: {detail[-1200:]}")
    return completed.stdout.strip()


def require_binary(name: str, configured: Path | str | None = None) -> str:
    resolved = str(Path(configured).expanduser().resolve()) if configured else shutil.which(name)
    if not resolved:
        raise RuntimeError(f"Не найдена обязательная команда: {name}")
    path = Path(resolved)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"Команда {name} недоступна для запуска: {path}")
    return resolved


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_name(value: str, fallback: str) -> str:
    cleaned = re.sub(r"[^0-9A-Za-zА-Яа-яЁё._-]+", "-", value).strip("-._")
    return (cleaned[:96] or fallback).strip("-._") or fallback


def seconds_to_timestamp(seconds: float, *, srt: bool = False) -> str:
    milliseconds = max(0, int(round(seconds * 1000)))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    separator = "," if srt else "."
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{separator}{millis:03d}"


def human_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def is_youtube_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and parsed.hostname in YOUTUBE_HOSTS


def probe_media(path: Path, *, ffprobe: str) -> dict[str, Any]:
    data = json.loads(
        run_cmd([ffprobe, "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], timeout=120)
    )
    duration = 0.0
    try:
        duration = float(data.get("format", {}).get("duration") or 0)
    except (TypeError, ValueError):
        pass
    if duration <= 0:
        for stream in data.get("streams", []):
            try:
                duration = max(duration, float(stream.get("duration") or 0))
            except (TypeError, ValueError):
                continue
    return {
        "duration": round(duration, 3),
        "format": data.get("format", {}),
        "streams": data.get("streams", []),
        "has_video": any(stream.get("codec_type") == "video" for stream in data.get("streams", [])),
        "has_audio": any(stream.get("codec_type") == "audio" for stream in data.get("streams", [])),
    }


def prepare_stage_audio(media: Path, output: Path, *, ffmpeg: str, force: bool) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and not force:
        return output
    run_cmd(
        [
            ffmpeg,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(media),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output),
        ],
        timeout=7200,
    )
    return output


def choose_youtube_caption(metadata: dict[str, Any], languages: list[str]) -> tuple[str, str] | None:
    for source, bucket_name in (("youtube_manual", "subtitles"), ("youtube_auto", "automatic_captions")):
        bucket = metadata.get(bucket_name, {})
        if not isinstance(bucket, dict):
            continue
        for language in languages:
            if bucket.get(language):
                return source, language
        for language, tracks in bucket.items():
            if tracks:
                return source, language
    return None


def download_youtube_caption(
    url: str,
    destination: Path,
    source: str,
    language: str,
    *,
    ffmpeg: str,
) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    command = [
        require_binary("yt-dlp"),
        "--no-warnings",
        "--no-playlist",
        "--skip-download",
        "--sub-lang",
        language,
        "--sub-format",
        "vtt",
        "--convert-subs",
        "vtt",
        "--ffmpeg-location",
        ffmpeg,
        "--output",
        str(destination / "captions.%(ext)s"),
        "--write-subs" if source == "youtube_manual" else "--write-auto-subs",
        url,
    ]
    run_cmd(command)
    candidates = sorted(destination.glob("*.vtt"))
    if not candidates:
        raise RuntimeError("yt-dlp не создал файл субтитров")
    return candidates[0]


def download_youtube_media(url: str, work_dir: Path, include_video: bool, *, ffmpeg: str) -> Path:
    work_dir.mkdir(parents=True, exist_ok=True)
    yt_dlp = require_binary("yt-dlp")
    output = str(work_dir / "source.%(ext)s")
    if include_video:
        command = [
            yt_dlp,
            "--no-warnings",
            "--no-playlist",
            "-f",
            "bv*[height<=720]+ba/b[height<=720]/b",
            "--merge-output-format",
            "mp4",
            "--ffmpeg-location",
            ffmpeg,
            "--output",
            output,
            url,
        ]
    else:
        command = [
            yt_dlp,
            "--no-warnings",
            "--no-playlist",
            "-x",
            "--audio-format",
            "wav",
            "--audio-quality",
            "0",
            "--ffmpeg-location",
            ffmpeg,
            "--postprocessor-args",
            "ffmpeg:-ac 1 -ar 16000",
            "--output",
            output,
            url,
        ]
    run_cmd(command, timeout=7200)
    candidates = sorted(
        path for path in work_dir.glob("source.*") if path.is_file() and path.suffix not in {".part", ".ytdl"}
    )
    if not candidates:
        raise RuntimeError("Не удалось найти скачанный медиафайл")
    return candidates[0]


class JobState:
    def __init__(self, path: Path, *, asset_id: str, source: str, profile: str) -> None:
        self.path = path
        if path.exists():
            self.value = json.loads(path.read_text(encoding="utf-8"))
            self.value.update(
                {
                    "pipeline": PIPELINE_VERSION,
                    "asset_id": asset_id,
                    "source": source,
                    "profile": profile,
                    "status": "running",
                    "current_stage": "received",
                    "stages": {},
                }
            )
            for stale_key in ("error", "failed_at", "completed_at"):
                self.value.pop(stale_key, None)
        else:
            self.value = {
                "pipeline": PIPELINE_VERSION,
                "asset_id": asset_id,
                "source": source,
                "profile": profile,
                "status": "running",
                "current_stage": "received",
                "stages": {},
                "created_at": utc_now(),
            }
        self.save()

    def stage(self, name: str, status: str, **details: Any) -> None:
        self.value["current_stage"] = name
        self.value["status"] = "failed" if status == "failed" else "running"
        self.value.setdefault("stages", {})[name] = {"status": status, "updated_at": utc_now(), **details}
        self.save()

    def finish(self) -> None:
        self.value["status"] = "complete"
        self.value["current_stage"] = "complete"
        self.value["completed_at"] = utc_now()
        self.save()

    def fail(self, error: Exception) -> None:
        self.value["status"] = "failed"
        self.value["error"] = str(error)
        self.value["failed_at"] = utc_now()
        self.save()

    def save(self) -> None:
        self.value["updated_at"] = utc_now()
        atomic_write_json(self.path, self.value)


def run_transcription(
    media: Path,
    output_dir: Path,
    *,
    adapter: Path,
    engine: str,
    chunk_seconds: float,
    overlap_seconds: float,
    ffmpeg: str,
    ffprobe: str,
    force: bool,
) -> dict[str, Any]:
    raw_name = "transcript.raw.gigaam.json" if engine in {"auto", "gigaam"} else "transcript.raw.whisper.json"
    raw_path = output_dir / raw_name
    if raw_path.exists() and not force:
        return json.loads(raw_path.read_text(encoding="utf-8"))
    checkpoint = output_dir / "checkpoints" / "mitim-stt.json"
    checkpoint.parent.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable,
        str(adapter),
        "--audio",
        str(media),
        "--engine",
        engine,
        "--chunk-seconds",
        str(chunk_seconds),
        "--overlap-seconds",
        str(overlap_seconds),
        "--ffmpeg-path",
        ffmpeg,
        "--ffprobe-path",
        ffprobe,
        "--checkpoint",
        str(checkpoint),
        "--output",
        str(raw_path),
    ]
    run_cmd(command, timeout=24 * 3600)
    return json.loads(raw_path.read_text(encoding="utf-8"))


def canonical_segments(raw: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for index, source in enumerate(raw.get("segments", [])):
        start = round(float(source.get("start", 0)), 3)
        end = round(float(source.get("end", start)), 3)
        result.append(
            {
                "id": index,
                "start": start,
                "end": max(start, end),
                "text": str(source.get("text", "")).strip(),
                "speaker": source.get("speaker"),
                "words": source.get("words", []),
                "confidence": source.get("confidence"),
                "source": source.get("source", "mitim-stt"),
                "engine": source.get("engine"),
                "language": source.get("language"),
                "quality_flags": list(source.get("quality_flags", [])),
            }
        )
    return result


def run_stage_command(
    template: str,
    *,
    media: Path,
    audio: Path | None = None,
    transcript: Path,
    output: Path,
) -> dict[str, Any]:
    command = shlex.split(
        template.format(
            audio=str(audio or media),
            media=str(media),
            transcript=str(transcript),
            output=str(output),
        )
    )
    run_cmd(command, timeout=24 * 3600)
    if not output.exists():
        raise RuntimeError(f"Этап не создал ожидаемый файл: {output}")
    payload = json.loads(output.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("segments"), list):
        raise RuntimeError(f"Некорректный JSON этапа: {output}")
    return payload


def build_qc(segments: list[dict[str, Any]], duration: float) -> dict[str, Any]:
    gaps: list[dict[str, float]] = []
    overlaps: list[dict[str, float]] = []
    previous_end = 0.0
    for segment in segments:
        start = float(segment["start"])
        end = float(segment["end"])
        if start > previous_end + 0.25:
            gaps.append({"start": round(previous_end, 3), "end": round(start, 3)})
        if start < previous_end - 0.25:
            overlaps.append({"start": round(start, 3), "previous_end": round(previous_end, 3)})
        previous_end = max(previous_end, end)
    flagged = [
        {"id": segment["id"], "start": segment["start"], "flags": segment["quality_flags"]}
        for segment in segments
        if segment["quality_flags"]
    ]
    return {
        "status": "review" if flagged or gaps else "ok",
        "duration": duration,
        "segment_count": len(segments),
        "nonempty_segment_count": sum(bool(segment["text"]) for segment in segments),
        "coverage_end": max((segment["end"] for segment in segments), default=0.0),
        "gaps": gaps,
        "overlaps": overlaps,
        "flagged_segments": flagged,
        "generated_at": utc_now(),
    }


def export_markdown(
    path: Path,
    *,
    asset_id: str,
    title: str,
    source_url: str | None,
    duration: float,
    profile: str,
    segments: list[dict[str, Any]],
) -> None:
    lines = [
        "---",
        f"asset_id: {asset_id}",
        f"title: {json.dumps(title, ensure_ascii=False)}",
        f"duration: {duration}",
        f"pipeline: {PIPELINE_VERSION}",
        f"profile: {profile}",
        "canonical_source: local_asr",
        f"created_at: {utc_now()}",
        "---",
        "",
        f"# {title}",
        "",
        "## Полный локальный транскрипт",
        "",
    ]
    for segment in segments:
        if not segment["text"]:
            continue
        start = float(segment["start"])
        label = human_timestamp(start)
        if source_url and is_youtube_url(source_url):
            heading = f"### [{label}]({source_url}{'&' if '?' in source_url else '?'}t={int(start)})"
        else:
            heading = f"### {label}"
        lines.extend([heading, "", segment["text"], ""])
        if segment["quality_flags"]:
            lines.extend([f"_QC: {', '.join(segment['quality_flags'])}_", ""])
    atomic_write_text(path, "\n".join(lines).strip() + "\n")


def export_srt(path: Path, segments: list[dict[str, Any]]) -> None:
    blocks: list[str] = []
    cue = 0
    for segment in segments:
        if not segment["text"]:
            continue
        cue += 1
        blocks.append(
            f"{cue}\n{seconds_to_timestamp(segment['start'], srt=True)} --> "
            f"{seconds_to_timestamp(segment['end'], srt=True)}\n{segment['text']}"
        )
    atomic_write_text(path, "\n\n".join(blocks) + ("\n" if blocks else ""))


def export_vtt(path: Path, segments: list[dict[str, Any]]) -> None:
    blocks = ["WEBVTT"]
    for segment in segments:
        if not segment["text"]:
            continue
        blocks.append(
            f"{seconds_to_timestamp(segment['start'])} --> {seconds_to_timestamp(segment['end'])}\n{segment['text']}"
        )
    atomic_write_text(path, "\n\n".join(blocks) + "\n")


def extract_frames(
    media: Path,
    output_dir: Path,
    *,
    duration: float,
    interval: int,
    ffmpeg: str,
    force: bool,
) -> list[dict[str, Any]]:
    if interval <= 0:
        return []
    output_dir.mkdir(parents=True, exist_ok=True)
    existing = sorted(output_dir.glob("frame-*.jpg"))
    if not existing or force:
        run_cmd(
            [
                ffmpeg,
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(media),
                "-vf",
                f"fps=1/{interval},scale=1280:-2",
                "-q:v",
                "3",
                str(output_dir / "frame-%05d.jpg"),
            ],
            timeout=7200,
        )
        existing = sorted(output_dir.glob("frame-*.jpg"))
    if not existing and duration > 0:
        first_frame = output_dir / "frame-00001.jpg"
        run_cmd(
            [
                ffmpeg,
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(media),
                "-frames:v",
                "1",
                "-vf",
                "scale=1280:-2",
                "-q:v",
                "3",
                str(first_frame),
            ],
            timeout=7200,
        )
        existing = sorted(output_dir.glob("frame-*.jpg"))
    return [
        {
            "timestamp": round(min(index * interval, duration), 3),
            "path": str(path),
            "ocr": None,
            "description": None,
            "status": "frame_extracted",
        }
        for index, path in enumerate(existing)
    ]


def reusable_visual_timeline(path: Path, *, force: bool) -> dict[str, Any] | None:
    if force or not path.exists():
        return None
    try:
        timeline = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    frames = timeline.get("frames")
    if (
        timeline.get("status") != "complete"
        or not isinstance(frames, list)
        or not frames
        or any(not isinstance(frame, dict) or frame.get("status") != "complete" for frame in frames)
    ):
        return None
    return timeline


def main() -> int:
    parser = argparse.ArgumentParser(description="Local-first video transcription around GigaAM/mitim-stt")
    parser.add_argument("source", help="YouTube URL or local audio/video path")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--profile", choices=tuple(PROFILES), default="standard")
    parser.add_argument("--engine", choices=("auto", "gigaam", "whisper"), default="gigaam")
    parser.add_argument("--chunk-seconds", type=float, default=60.0)
    parser.add_argument("--overlap-seconds", type=float, default=1.5)
    parser.add_argument("--langs", default="ru,en,en-US,en-GB")
    parser.add_argument("--title")
    parser.add_argument("--source-kind", choices=("auto", "youtube", "telegram", "local"), default="auto")
    parser.add_argument("--stt-adapter", type=Path, default=DEFAULT_STT_ADAPTER)
    parser.add_argument("--ollama-enricher", type=Path, default=DEFAULT_OLLAMA_ENRICHER)
    parser.add_argument("--ollama-url", default="http://127.0.0.1:11434")
    parser.add_argument("--vision-model", default="qwen3-vl:8b")
    parser.add_argument("--align-command", help="Command template using {audio}, {transcript}, {output}")
    parser.add_argument("--diarize-command", help="Command template using {audio}, {transcript}, {output}")
    parser.add_argument("--ffmpeg-path", type=Path, help="Absolute path to ffmpeg for detached workers")
    parser.add_argument("--ffprobe-path", type=Path, help="Absolute path to ffprobe for detached workers")
    parser.add_argument("--skip-vision-analysis", action="store_true")
    parser.add_argument("--skip-summary", action="store_true")
    parser.add_argument("--telegram-chat-id", help="Build a Telegram Suite publication outbox for this chat")
    parser.add_argument("--telegram-source-topic-id", type=int, help="Topic where the source was received")
    parser.add_argument("--telegram-connection", default=DEFAULT_TELEGRAM_CONNECTION)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if args.telegram_source_topic_id is not None and not args.telegram_chat_id:
        parser.error("--telegram-source-topic-id требует --telegram-chat-id")

    ffmpeg = require_binary("ffmpeg", args.ffmpeg_path)
    ffprobe = require_binary("ffprobe", args.ffprobe_path)
    source_is_youtube = is_youtube_url(args.source)
    if urlparse(args.source).scheme in {"http", "https"} and not source_is_youtube:
        raise ValueError("В первой версии URL поддерживаются только для YouTube; остальные источники передавайте файлом")

    profile = PROFILES[args.profile]
    metadata: dict[str, Any]
    source_info: dict[str, Any]
    output_dir: Path
    work_dir: Path

    if source_is_youtube:
        yt_dlp = require_binary("yt-dlp")
        metadata = json.loads(run_cmd([yt_dlp, "--dump-single-json", "--no-playlist", "--no-warnings", args.source]))
        asset_id = str(metadata.get("id") or safe_name(args.source, "youtube"))
        output_dir = args.output_root / asset_id
        work_dir = output_dir / "_work"
        title = args.title or str(metadata.get("title") or asset_id)
        source_info = {
            "kind": "youtube",
            "original": args.source,
            "canonical_url": metadata.get("webpage_url") or args.source,
            "video_id": asset_id,
            "received_at": utc_now(),
        }
    else:
        local_source = Path(args.source).expanduser().resolve(strict=True)
        digest = file_sha256(local_source)
        asset_id = safe_name(local_source.stem, digest[:16]) + "-" + digest[:12]
        output_dir = args.output_root / asset_id
        work_dir = output_dir / "_work"
        title = args.title or local_source.stem
        metadata = {"title": title, "id": asset_id}
        source_info = {
            "kind": "telegram" if args.source_kind == "telegram" else "local",
            "original": str(local_source),
            "sha256": digest,
            "size": local_source.stat().st_size,
            "received_at": utc_now(),
        }

    output_dir.mkdir(parents=True, exist_ok=True)
    job = JobState(output_dir / "job-state.json", asset_id=asset_id, source=args.source, profile=args.profile)

    try:
        job.stage("metadata", "running")
        atomic_write_json(output_dir / "metadata.json", metadata)
        atomic_write_json(output_dir / "source-info.json", source_info)
        job.stage("metadata", "complete")

        if source_is_youtube:
            job.stage("media", "running")
            media = download_youtube_media(args.source, work_dir, bool(profile["visuals"]), ffmpeg=ffmpeg)
            caption = choose_youtube_caption(metadata, [item.strip() for item in args.langs.split(",") if item.strip()])
            if caption:
                caption_source, caption_language = caption
                try:
                    caption_path = download_youtube_caption(
                        args.source,
                        work_dir / "captions",
                        caption_source,
                        caption_language,
                        ffmpeg=ffmpeg,
                    )
                    shutil.copy2(caption_path, output_dir / "subtitles.raw.vtt")
                    atomic_write_json(
                        output_dir / "subtitles.source.json",
                        {"source": caption_source, "language": caption_language, "canonical": False},
                    )
                except Exception as error:
                    atomic_write_json(output_dir / "subtitles.source.json", {"status": "failed", "error": str(error)})
            job.stage("media", "complete", path=str(media))
        else:
            media = Path(args.source).expanduser().resolve(strict=True)
            job.stage("media", "complete", path=str(media))

        media_probe = probe_media(media, ffprobe=ffprobe)
        if not media_probe["has_audio"]:
            raise RuntimeError("В источнике не найден аудиопоток")
        atomic_write_json(output_dir / "media-info.json", media_probe)

        effective_engine = "whisper" if args.profile == "multilingual" and args.engine == "gigaam" else args.engine
        job.stage("transcription", "running", engine=effective_engine)
        raw = run_transcription(
            media,
            output_dir,
            adapter=args.stt_adapter,
            engine=effective_engine,
            chunk_seconds=args.chunk_seconds,
            overlap_seconds=args.overlap_seconds,
            ffmpeg=ffmpeg,
            ffprobe=ffprobe,
            force=args.force,
        )
        segments = canonical_segments(raw)
        transcript_path = output_dir / "transcript.json"
        transcript = {
            "asset_id": asset_id,
            "title": title,
            "source": source_info,
            "duration": media_probe["duration"],
            "language": "ru" if effective_engine == "gigaam" else "auto",
            "canonical_source": "local_asr",
            "pipeline": PIPELINE_VERSION,
            "profile": args.profile,
            "asr": raw.get("metadata", {}),
            "created_at": utc_now(),
            "segments": segments,
        }
        atomic_write_json(transcript_path, transcript)
        job.stage("transcription", "complete", segment_count=len(segments))

        stage_audio = media
        needs_stage_audio = (profile["alignment"] and bool(args.align_command)) or (
            profile["diarization"] and bool(args.diarize_command)
        )
        if needs_stage_audio:
            stage_audio = prepare_stage_audio(
                media,
                work_dir / "stage-audio-16k-mono.wav",
                ffmpeg=ffmpeg,
                force=args.force,
            )

        if profile["alignment"]:
            if args.align_command:
                job.stage("alignment", "running")
                aligned_path = output_dir / "transcript.aligned.json"
                aligned = run_stage_command(
                    args.align_command,
                    media=media,
                    audio=stage_audio,
                    transcript=transcript_path,
                    output=aligned_path,
                )
                segments = canonical_segments(aligned)
                transcript["segments"] = segments
                transcript["alignment"] = aligned.get("metadata", {"status": "complete"})
                atomic_write_json(transcript_path, transcript)
                job.stage("alignment", "complete")
            else:
                job.stage("alignment", "skipped", reason="align_command_not_configured", precision="chunk")
        else:
            job.stage("alignment", "skipped", reason="profile")

        if profile["diarization"]:
            if args.diarize_command:
                job.stage("diarization", "running")
                diarized_path = output_dir / "transcript.diarized.json"
                diarized = run_stage_command(
                    args.diarize_command,
                    media=media,
                    audio=stage_audio,
                    transcript=transcript_path,
                    output=diarized_path,
                )
                segments = canonical_segments(diarized)
                transcript["segments"] = segments
                transcript["diarization"] = diarized.get(
                    "diarization",
                    diarized.get("metadata", {"status": "complete"}),
                )
                if isinstance(diarized.get("speakers"), list):
                    transcript["speakers"] = diarized["speakers"]
                if isinstance(diarized.get("speaker_turns"), list):
                    transcript["speaker_turns"] = diarized["speaker_turns"]
                atomic_write_json(transcript_path, transcript)
                job.stage("diarization", "complete")
            else:
                job.stage("diarization", "skipped", reason="diarize_command_not_configured")
        else:
            job.stage("diarization", "skipped", reason="profile")

        visual_timeline_path = output_dir / "visual-timeline.json"
        if profile["visuals"] and media_probe["has_video"]:
            existing_timeline = reusable_visual_timeline(visual_timeline_path, force=args.force)
            if existing_timeline:
                existing_frames = existing_timeline["frames"]
                job.stage(
                    "visuals",
                    "complete",
                    frame_count=len(existing_frames),
                    analyzed_frame_count=len(existing_frames),
                    ocr="complete",
                    model=existing_timeline.get("model") or args.vision_model,
                    resumed=True,
                )
            else:
                job.stage("visuals", "running")
                frames = extract_frames(
                    media,
                    output_dir / "frames",
                    duration=media_probe["duration"],
                    interval=int(profile["frame_interval"]),
                    ffmpeg=ffmpeg,
                    force=args.force,
                )
                atomic_write_json(
                    visual_timeline_path,
                    {
                        "interval_seconds": profile["frame_interval"],
                        "frames": frames,
                        "status": "frames_extracted",
                    },
                )
                if frames and not args.skip_vision_analysis:
                    enrich_command = [
                        sys.executable,
                        str(args.ollama_enricher),
                        "--ollama-url",
                        args.ollama_url,
                        "--model",
                        args.vision_model,
                        "visuals",
                        "--timeline",
                        str(visual_timeline_path),
                    ]
                    if args.force:
                        enrich_command.append("--force")
                    try:
                        run_cmd(enrich_command, timeout=7200)
                        job.stage(
                            "visuals",
                            "complete",
                            frame_count=len(frames),
                            analyzed_frame_count=len(frames),
                            ocr="complete",
                            model=args.vision_model,
                        )
                    except Exception as error:
                        if args.profile == "deep":
                            raise
                        job.stage(
                            "visuals",
                            "partial",
                            frame_count=len(frames),
                            ocr="failed",
                            model=args.vision_model,
                            error=str(error),
                        )
                else:
                    job.stage(
                        "visuals",
                        "complete",
                        frame_count=len(frames),
                        analyzed_frame_count=0,
                        ocr="skipped" if args.skip_vision_analysis else "not_applicable",
                    )
        else:
            job.stage("visuals", "skipped", reason="profile_or_no_video_stream")

        if args.skip_summary:
            job.stage("summary", "skipped", reason="command_line")
        else:
            job.stage("summary", "running", model=args.vision_model)
            summary_command = [
                sys.executable,
                str(args.ollama_enricher),
                "--ollama-url",
                args.ollama_url,
                "--model",
                args.vision_model,
                "summary",
                "--transcript",
                str(transcript_path),
                "--output-json",
                str(output_dir / "summary.json"),
                "--output-markdown",
                str(output_dir / "summary.md"),
            ]
            if visual_timeline_path.exists():
                summary_command.extend(["--visual-timeline", str(visual_timeline_path)])
            if args.force:
                summary_command.append("--force")
            run_cmd(summary_command, timeout=7200)
            summary_result = json.loads((output_dir / "summary.json").read_text(encoding="utf-8"))
            job.stage(
                "summary",
                "complete",
                model=args.vision_model,
                chapter_count=len(summary_result.get("chapters", [])),
                visual_finding_count=len(summary_result.get("visual_findings", [])),
            )

        job.stage("exports", "running")
        qc = build_qc(segments, media_probe["duration"])
        atomic_write_json(output_dir / "qc.json", qc)
        export_markdown(
            output_dir / "transcript.md",
            asset_id=asset_id,
            title=title,
            source_url=source_info.get("canonical_url"),
            duration=media_probe["duration"],
            profile=args.profile,
            segments=segments,
        )
        export_srt(output_dir / "transcript.srt", segments)
        export_vtt(output_dir / "transcript.vtt", segments)
        artifacts = [
            "metadata.json",
            "source-info.json",
            "media-info.json",
            "transcript.json",
            "transcript.md",
            "transcript.srt",
            "transcript.vtt",
            "qc.json",
            "job-state.json",
        ]
        if (output_dir / "visual-timeline.json").exists():
            artifacts.append("visual-timeline.json")
        if (output_dir / "frames").exists():
            artifacts.append("frames/")
        if (output_dir / "summary.json").exists():
            artifacts.append("summary.json")
        if (output_dir / "summary.md").exists():
            artifacts.append("summary.md")
        manifest = {
            "asset_id": asset_id,
            "title": title,
            "status": "complete",
            "pipeline": PIPELINE_VERSION,
            "profile": args.profile,
            "canonical_source": "local_asr",
            "engine": effective_engine,
            "duration": media_probe["duration"],
            "segment_count": len(segments),
            "qc_status": qc["status"],
            "vision_status": job.value.get("stages", {}).get("visuals", {}).get("status"),
            "summary_status": job.value.get("stages", {}).get("summary", {}).get("status"),
            "publication_status": "pending" if args.telegram_chat_id else "skipped",
            "vision_model": args.vision_model,
            "artifacts": artifacts,
            "completed_at": utc_now(),
        }
        atomic_write_json(output_dir / "manifest.json", manifest)
        job.stage("exports", "complete")

        if args.telegram_chat_id:
            job.stage("publication", "running", connection=args.telegram_connection)
            publication_path = output_dir / "telegram-publication.json"
            publication = build_publication_plan(
                output_dir,
                chat_id=args.telegram_chat_id,
                source_topic_id=args.telegram_source_topic_id,
                connection=args.telegram_connection,
                output=publication_path,
            )
            artifacts.append("telegram-publication.json")
            manifest["artifacts"] = artifacts
            manifest["publication_status"] = "ready"
            atomic_write_json(output_dir / "manifest.json", manifest)
            job.stage(
                "publication",
                "ready",
                outbox=str(publication_path),
                topic_name=publication["topic"]["name"],
            )
        else:
            job.stage("publication", "skipped", reason="telegram_chat_not_configured")
        job.finish()
        print(json.dumps({"output_dir": str(output_dir), "manifest": manifest}, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        job.fail(error)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
