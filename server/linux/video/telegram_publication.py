#!/usr/bin/env python3
"""Build a safe, resumable Telegram publication outbox for one video.

This module never contacts Telegram. It renders exact action descriptors for
Telegram Suite. A fresh video from Ivan is the direct command for the exact
low-risk publication package, so descriptors request owner-direct execution
without a duplicate confirmation prompt.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse


SCHEMA_VERSION = 1
SAFE_TEXT_LIMIT = 3900
DEFAULT_CONNECTION = "bot:voiceswitch"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path, *, required: bool = True) -> dict[str, Any]:
    if not path.exists():
        if required:
            raise FileNotFoundError(f"Не найден обязательный артефакт: {path}")
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Ожидался JSON-объект: {path}")
    return value


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def normalize_space(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def stable_key(*parts: Any) -> str:
    source = "\x1f".join(str(part) for part in parts)
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()[:20]
    return f"video-{digest}"


def file_digest(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_chat_id(value: str | int) -> str | int:
    rendered = str(value).strip()
    if re.fullmatch(r"-?\d+", rendered):
        return int(rendered)
    if not rendered:
        raise ValueError("Telegram chat id не может быть пустым")
    return rendered


def make_topic_name(title: str) -> str:
    cleaned = normalize_space(title).strip(" 🎬:—–-.,;!?«»\"'").replace("/", "／")
    words = re.findall(r"[0-9A-Za-zА-Яа-яЁё]+(?:[-–][0-9A-Za-zА-Яа-яЁё]+)*", cleaned)
    generic = {"видео", "тестовое видео", "фрагмент транскрипта", "итоговый конспект"}
    if re.search(r"\.(?:mp4|mov|mkv|webm|avi|mp3|wav|m4a)$", cleaned, flags=re.IGNORECASE):
        raise ValueError("Название топика не должно быть именем файла")
    if re.fullmatch(r"[0-9a-f]{12,64}", cleaned, flags=re.IGNORECASE) or re.fullmatch(
        r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", cleaned, flags=re.IGNORECASE
    ):
        raise ValueError("Название топика не должно быть техническим идентификатором")
    if cleaned.casefold() in generic or len(words) < 3:
        raise ValueError("Название топика должно содержательно описывать видео и включать 3–8 слов")
    words = words[:8]
    cleaned = " ".join(words)
    prefix = "🎬 "
    available = 60 - len(prefix)
    while len(words) >= 3 and len(cleaned) > available:
        words.pop()
        cleaned = " ".join(words)
    if len(words) < 3:
        raise ValueError("Название топика нельзя сократить до 60 символов без потери смысла")
    return prefix + cleaned


def human_duration(value: Any) -> str:
    try:
        total = max(0, int(round(float(value))))
    except (TypeError, ValueError):
        return "не определена"
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes}:{seconds:02d}"


def timestamp(value: Any) -> str:
    try:
        total = max(0, int(float(value)))
    except (TypeError, ValueError):
        total = 0
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes}:{seconds:02d}"


def timestamp_url(url: str | None, seconds: Any) -> str | None:
    if not url:
        return None
    parsed = urlparse(url)
    allowed = {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"}
    if parsed.hostname not in allowed:
        return None
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query["t"] = str(max(0, int(float(seconds or 0))))
    return urlunparse(parsed._replace(query=urlencode(query)))


def source_label(source: dict[str, Any]) -> str:
    if source.get("canonical_url"):
        return str(source["canonical_url"])
    digest = normalize_space(source.get("sha256"))[:12]
    label = "Telegram-вложение" if source.get("kind") == "telegram" else "Локальный файл"
    return f"{label} · SHA-256 {digest}…" if digest else label


def author_label(metadata: dict[str, Any]) -> str | None:
    for key in ("uploader", "channel", "creator", "artist", "author"):
        value = normalize_space(metadata.get(key))
        if value:
            return value
    return None


def engine_label(transcript: dict[str, Any], manifest: dict[str, Any]) -> str:
    asr = transcript.get("asr") if isinstance(transcript.get("asr"), dict) else {}
    engines = asr.get("engines_used")
    if isinstance(engines, list) and engines:
        return ", ".join(normalize_space(item) for item in engines if normalize_space(item))
    return normalize_space(asr.get("requested_engine") or manifest.get("engine") or "не определён")


def stage_warnings(job: dict[str, Any]) -> list[str]:
    result: list[str] = []
    stages = job.get("stages") if isinstance(job.get("stages"), dict) else {}
    labels = {
        "alignment": "точное выравнивание",
        "diarization": "диаризация",
        "visuals": "OCR/vision",
        "summary": "саммари",
    }
    for stage, label in labels.items():
        value = stages.get(stage) if isinstance(stages.get(stage), dict) else {}
        status = normalize_space(value.get("status"))
        if status in {"skipped", "partial", "failed"}:
            reason = normalize_space(value.get("reason") or value.get("error"))
            internal_markers = ("Traceback", "eback (most recent call", 'File "', "/home/", "RuntimeError:")
            if any(marker in reason for marker in internal_markers):
                reason = ""
            elif len(reason) > 180:
                reason = reason[:179].rstrip() + "…"
            result.append(f"{label}: {status}" + (f" ({reason})" if reason else ""))
    return result


def bounded_text(value: str, *, limit: int = SAFE_TEXT_LIMIT) -> str:
    if len(value) <= limit:
        return value
    marker = "\n\n…Текст сокращён; полный материал приложен файлами."
    return value[: limit - len(marker)].rstrip() + marker


def build_summary_text(
    *,
    transcript: dict[str, Any],
    summary: dict[str, Any],
    manifest: dict[str, Any],
    metadata: dict[str, Any],
    source: dict[str, Any],
    qc: dict[str, Any],
    job: dict[str, Any],
) -> str:
    title = normalize_space(summary.get("title") or transcript.get("title") or manifest.get("title") or "Видео")
    profile = normalize_space(manifest.get("profile") or transcript.get("profile") or job.get("profile") or "standard")
    duration = manifest.get("duration", transcript.get("duration"))
    lines = [
        f"🎬 {title}",
        "",
        f"Источник: {source_label(source)}",
        f"Длительность: {human_duration(duration)}",
    ]
    author = author_label(metadata)
    if author:
        lines.append(f"Автор/канал: {author}")
    lines.extend(
        [
            f"Профиль: {profile}",
            f"Локальная ASR: {engine_label(transcript, manifest)}",
            f"QC: {normalize_space(qc.get('status') or manifest.get('qc_status') or 'не определён')}",
        ]
    )

    overview = normalize_space(summary.get("overview"))
    if overview:
        lines.extend(["", "Кратко", overview])
    key_points = [normalize_space(item) for item in summary.get("key_points", []) if normalize_space(item)]
    if key_points:
        lines.extend(["", "Ключевые тезисы"])
        lines.extend(f"• {item}" for item in key_points[:6])
    chapters = [item for item in summary.get("chapters", []) if isinstance(item, dict)]
    if chapters:
        lines.extend(["", "Ключевые фрагменты"])
        base_url = source.get("canonical_url")
        for chapter in chapters[:6]:
            start = chapter.get("start", 0)
            chapter_title = normalize_space(chapter.get("title") or chapter.get("chapter_title") or "Фрагмент")
            link = timestamp_url(str(base_url), start) if base_url else None
            lines.append(f"• {timestamp(start)} — {chapter_title}" + (f" — {link}" if link else ""))
    risks = [normalize_space(item) for item in summary.get("risks", []) if normalize_space(item)]
    if risks:
        lines.extend(["", "Риски и оговорки"])
        lines.extend(f"• {item}" for item in risks[:4])
    warnings = stage_warnings(job)
    if warnings:
        lines.extend(["", "Ограничения обработки"])
        lines.extend(f"• {item}" for item in warnings)
    lines.extend(["", "Полные саммари и транскрипт приложены файлами."])
    return bounded_text("\n".join(lines))


def build_status_text(manifest: dict[str, Any], qc: dict[str, Any]) -> str:
    return "\n".join(
        [
            "📦 Локальная обработка готова",
            f"Профиль: {normalize_space(manifest.get('profile') or 'standard')}",
            f"QC: {normalize_space(qc.get('status') or manifest.get('qc_status') or 'не определён')}",
            f"OCR/vision: {normalize_space(manifest.get('vision_status') or 'не применялся')}",
            f"Саммари: {normalize_space(manifest.get('summary_status') or 'не создано')}",
        ]
    )


def build_publication_plan(
    artifact_dir: Path,
    *,
    chat_id: str | int,
    source_topic_id: int | None = None,
    connection: str = DEFAULT_CONNECTION,
    output: Path | None = None,
) -> dict[str, Any]:
    artifact_dir = artifact_dir.expanduser().resolve(strict=True)
    transcript = read_json(artifact_dir / "transcript.json")
    manifest = read_json(artifact_dir / "manifest.json")
    summary = read_json(artifact_dir / "summary.json", required=False)
    metadata = read_json(artifact_dir / "metadata.json", required=False)
    source = read_json(artifact_dir / "source-info.json")
    qc = read_json(artifact_dir / "qc.json")
    job = read_json(artifact_dir / "job-state.json")
    asset_id = normalize_space(manifest.get("asset_id") or transcript.get("asset_id"))
    if not asset_id:
        raise ValueError("В артефактах отсутствует asset_id")
    title = normalize_space(summary.get("title"))
    if not title:
        raise ValueError("В summary.json отсутствует смысловое название для Telegram-топика")
    target_chat = parse_chat_id(chat_id)
    output = output or artifact_dir / "telegram-publication.json"

    previous: dict[str, Any] = {}
    if output.exists():
        previous = read_json(output)
        old_target = previous.get("target") if isinstance(previous.get("target"), dict) else {}
        if previous.get("asset_id") != asset_id or old_target.get("chat_id") != target_chat:
            raise ValueError("Существующий outbox относится к другому asset или Telegram-чату")

    attachments: list[dict[str, Any]] = []
    for kind, filename, caption in (
        ("summary_document", "summary.md", "Содержательное саммари"),
        ("transcript_document", "transcript.md", "Полный локальный транскрипт"),
    ):
        path = artifact_dir / filename
        if not path.is_file():
            raise FileNotFoundError(f"Не найден обязательный файл публикации: {path}")
        attachments.append({"kind": kind, "path": str(path), "caption": caption})

    now = utc_now()
    delivery = previous.get("delivery") or {
        "status": "pending_topic",
        "topic_id": None,
        "messages": {},
        "completed_at": None,
    }
    if delivery.get("status") == "complete":
        delivery["status"] = "completed"
    plan = {
        "schema_version": SCHEMA_VERSION,
        "asset_id": asset_id,
        "artifact_dir": str(artifact_dir),
        "created_at": previous.get("created_at") or now,
        "updated_at": now,
        "target": {"connection": connection, "chat_id": target_chat, "source_topic_id": source_topic_id},
        "topic": {
            "name": make_topic_name(title),
            "idempotency_key": stable_key(asset_id, target_chat, "topic", SCHEMA_VERSION),
        },
        "content": {
            "status_ready": build_status_text(manifest, qc),
            "summary": build_summary_text(
                transcript=transcript,
                summary=summary,
                manifest=manifest,
                metadata=metadata,
                source=source,
                qc=qc,
                job=job,
            ),
        },
        "attachments": attachments,
        "delivery": delivery,
    }
    atomic_write_json(output, plan)
    return plan


def action_descriptors(plan: dict[str, Any], *, topic_id: int | None = None) -> list[dict[str, Any]]:
    target = plan["target"]
    delivery = plan.get("delivery") if isinstance(plan.get("delivery"), dict) else {}
    messages = delivery.get("messages") if isinstance(delivery.get("messages"), dict) else {}
    resolved_topic = topic_id or delivery.get("topic_id")
    connection = target["connection"]
    chat_id = target["chat_id"]
    asset_id = plan["asset_id"]

    if not resolved_topic:
        return [
            {
                "kind": "topic",
                "connection": connection,
                "operation": "create_forum_topic",
                "params": {"chat_id": chat_id, "name": plan["topic"]["name"]},
                "idempotency_key": plan["topic"]["idempotency_key"],
                "owner_direct_approval": True,
            }
        ]

    resolved_topic = int(resolved_topic)
    common = {"chat_id": chat_id, "message_thread_id": resolved_topic}
    result: list[dict[str, Any]] = []
    for kind, text_key in (("status", "status_ready"), ("summary", "summary")):
        if kind not in messages:
            text = plan["content"][text_key]
            result.append(
                {
                    "kind": kind,
                    "connection": connection,
                    "operation": "send_message",
                    "params": {**common, "text": text},
                    "idempotency_key": stable_key(
                        asset_id, chat_id, resolved_topic, kind, text, SCHEMA_VERSION
                    ),
                    "owner_direct_approval": True,
                }
            )
    for attachment in plan.get("attachments", []):
        kind = attachment["kind"]
        if kind in messages:
            continue
        result.append(
            {
                "kind": kind,
                "connection": connection,
                "operation": "send_media",
                "params": {
                    **common,
                    "media_type": "document",
                    "file": {"$file": attachment["path"]},
                    "caption": attachment["caption"],
                },
                "idempotency_key": stable_key(
                    asset_id,
                    chat_id,
                    resolved_topic,
                    kind,
                    file_digest(attachment["path"]),
                    SCHEMA_VERSION,
                ),
                "owner_direct_approval": True,
            }
        )
    return result


def record_topic(plan_path: Path, topic_id: int) -> dict[str, Any]:
    if topic_id < 1:
        raise ValueError("topic_id должен быть положительным")
    plan = read_json(plan_path)
    delivery = plan.setdefault("delivery", {})
    existing = delivery.get("topic_id")
    if existing and int(existing) != topic_id:
        raise ValueError(f"Outbox уже привязан к другому topic_id: {existing}")
    delivery["topic_id"] = topic_id
    delivery["status"] = "pending_messages"
    plan["updated_at"] = utc_now()
    atomic_write_json(plan_path, plan)
    return plan


def record_message(plan_path: Path, kind: str, message_id: int) -> dict[str, Any]:
    if message_id < 1:
        raise ValueError("message_id должен быть положительным")
    plan = read_json(plan_path)
    delivery = plan.setdefault("delivery", {})
    messages = delivery.setdefault("messages", {})
    existing = messages.get(kind)
    if existing and int(existing) != message_id:
        raise ValueError(f"Для {kind} уже записан другой message_id: {existing}")
    messages[kind] = message_id
    expected = {"status", "summary", *(item["kind"] for item in plan.get("attachments", []))}
    if expected.issubset(messages):
        delivery["status"] = "completed"
        delivery["completed_at"] = delivery.get("completed_at") or utc_now()
    else:
        delivery["status"] = "pending_messages"
    plan["updated_at"] = utc_now()
    atomic_write_json(plan_path, plan)
    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description="Telegram topic publication outbox for video artifacts")
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("artifact_dir", type=Path)
    build.add_argument("--chat-id", required=True)
    build.add_argument("--source-topic-id", type=int)
    build.add_argument("--connection", default=DEFAULT_CONNECTION)
    build.add_argument("--output", type=Path)
    actions = subparsers.add_parser("actions")
    actions.add_argument("plan", type=Path)
    actions.add_argument("--topic-id", type=int)
    bind = subparsers.add_parser("record-topic")
    bind.add_argument("plan", type=Path)
    bind.add_argument("topic_id", type=int)
    record = subparsers.add_parser("record-message")
    record.add_argument("plan", type=Path)
    record.add_argument("kind")
    record.add_argument("message_id", type=int)

    args = parser.parse_args()
    if args.command == "build":
        result = build_publication_plan(
            args.artifact_dir,
            chat_id=args.chat_id,
            source_topic_id=args.source_topic_id,
            connection=args.connection,
            output=args.output,
        )
    elif args.command == "actions":
        result = action_descriptors(read_json(args.plan), topic_id=args.topic_id)
    elif args.command == "record-topic":
        result = record_topic(args.plan, args.topic_id)
    else:
        result = record_message(args.plan, args.kind, args.message_id)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
