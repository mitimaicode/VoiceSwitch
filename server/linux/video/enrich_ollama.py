#!/usr/bin/env python3
"""Local OCR/vision and transcript summarization through Ollama.

The helper is deliberately dependency-free: frames and transcripts stay on the
server and are sent only to the local Ollama HTTP endpoint.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_MODEL = "qwen3-vl:8b"
DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"


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


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Ожидался JSON-объект: {path}")
    return value


def human_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def parse_json_object(value: str) -> dict[str, Any]:
    text = value.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\s*```$", "", text)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("Ollama не вернул JSON-объект")
        parsed = json.loads(text[start : end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("Ollama вернул JSON другого типа")
    return parsed


class OllamaClient:
    def __init__(self, *, url: str, model: str, timeout: int = 900, json_attempts: int = 3) -> None:
        self.endpoint = url.rstrip("/") + "/api/chat"
        self.model = model
        self.timeout = timeout
        self.json_attempts = max(1, json_attempts)

    def chat(
        self,
        prompt: str,
        *,
        schema: dict[str, Any],
        images: list[Path] | None = None,
    ) -> dict[str, Any]:
        message: dict[str, Any] = {"role": "user", "content": prompt}
        if images:
            message["images"] = [base64.b64encode(path.read_bytes()).decode("ascii") for path in images]
        messages = [message]
        last_error: Exception | None = None
        for attempt in range(1, self.json_attempts + 1):
            payload = {
                "model": self.model,
                "messages": messages,
                "stream": False,
                "think": False,
                "format": schema,
                "keep_alive": "10m",
                "options": {"temperature": 0, "num_ctx": 8192},
            }
            request = Request(
                self.endpoint,
                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urlopen(request, timeout=self.timeout) as response:
                    result = json.loads(response.read().decode("utf-8"))
            except HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")[-1200:]
                raise RuntimeError(f"Ollama HTTP {error.code}: {detail}") from error
            except URLError as error:
                raise RuntimeError(f"Локальный Ollama недоступен: {error.reason}") from error
            message_result = result.get("message", {})
            content = message_result.get("content")
            if not isinstance(content, str) or not content.strip():
                content = message_result.get("thinking")
            if not isinstance(content, str) or not content.strip():
                last_error = RuntimeError("Ollama вернул пустой ответ")
                content = ""
            else:
                try:
                    return parse_json_object(content)
                except (ValueError, json.JSONDecodeError) as error:
                    last_error = error
            if attempt < self.json_attempts:
                messages.extend(
                    [
                        {"role": "assistant", "content": content},
                        {
                            "role": "user",
                            "content": (
                                "Предыдущий ответ не удалось разобрать как JSON. "
                                "Повтори ответ строго как один валидный JSON-объект по заданной схеме, "
                                "без пояснений и Markdown."
                            ),
                        },
                    ]
                )
        raise ValueError(f"Ollama не вернул валидный JSON за {self.json_attempts} попытки") from last_error


VISION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "ocr_text": {"type": "string"},
        "description": {"type": "string"},
        "visible_actions": {"type": "array", "items": {"type": "string"}},
        "visual_type": {
            "type": "string",
            "enum": ["slide", "interface", "document", "camera", "diagram", "other"],
        },
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "warnings": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["ocr_text", "description", "visible_actions", "visual_type", "confidence", "warnings"],
    "additionalProperties": False,
}


SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "chapter_title": {"type": "string"},
        "overview": {"type": "string"},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "action_items": {"type": "array", "items": {"type": "string"}},
        "risks": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["chapter_title", "overview", "key_points", "decisions", "action_items", "risks"],
    "additionalProperties": False,
}

TOPIC_TITLE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"title": {"type": "string"}},
    "required": ["title"],
    "additionalProperties": False,
}

GENERIC_TOPIC_TITLES = {
    "видео",
    "тестовое видео",
    "фрагмент транскрипта",
    "итоговый конспект",
}


def normalize_topic_title(value: Any) -> str:
    """Return a short semantic topic title without an emoji or technical ids."""
    rendered = re.sub(r"\s+", " ", str(value or "")).strip(" \t\r\n🎬:—–-.,;!?«»\"'")
    if not rendered or rendered.casefold() in GENERIC_TOPIC_TITLES:
        raise ValueError("Название топика не отражает содержание видео")
    if re.search(r"\.(?:mp4|mov|mkv|webm|avi|mp3|wav|m4a)$", rendered, flags=re.IGNORECASE):
        raise ValueError("Название топика похоже на имя файла")
    if re.fullmatch(r"[0-9a-f]{12,64}", rendered, flags=re.IGNORECASE) or re.fullmatch(
        r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", rendered, flags=re.IGNORECASE
    ):
        raise ValueError("Название топика похоже на технический идентификатор")

    words = re.findall(r"[0-9A-Za-zА-Яа-яЁё]+(?:[-–][0-9A-Za-zА-Яа-яЁё]+)*", rendered)
    if len(words) < 3:
        raise ValueError("Название топика должно содержать не менее трёх слов")
    words = words[:8]
    while len(words) >= 3 and len(" ".join(words)) > 56:
        words.pop()
    if len(words) < 3:
        raise ValueError("Название топика нельзя сократить до 56 символов без потери смысла")
    return " ".join(words)


def generate_topic_title(
    reduced: dict[str, Any],
    partials: list[dict[str, Any]],
    *,
    source_title: Any,
    client: OllamaClient,
) -> str:
    """Generate the Telegram topic title from the completed transcript summary."""
    evidence = {
        "overview": str(reduced.get("overview") or "").strip(),
        "key_points": unique_strings(list(reduced.get("key_points") or []), limit=8),
        "chapters": unique_strings(
            [str(item.get("chapter_title") or "") for item in partials], limit=8
        ),
    }
    prompt = (
        "Сформулируй короткое фактическое название темы видео по готовому конспекту. "
        "Верни только JSON. Поле title: 3–8 слов, не более 56 символов, без эмодзи, "
        "кавычек, имени файла и технических идентификаторов. Название должно отражать "
        "главную тему или практический результат, не быть кликбейтом.\n\n"
        + json.dumps(evidence, ensure_ascii=False)
    )
    try:
        result = client.chat(prompt, schema=TOPIC_TITLE_SCHEMA)
        return normalize_topic_title(result.get("title"))
    except (RuntimeError, ValueError):
        candidates = [
            *(item.get("chapter_title") for item in partials),
            *(reduced.get("key_points") or []),
            reduced.get("overview"),
            source_title,
        ]
        for candidate in candidates:
            try:
                return normalize_topic_title(candidate)
            except ValueError:
                continue
        raise ValueError("Не удалось сформировать смысловое название топика из транскрипта")


def analyze_visual_timeline(
    timeline_path: Path,
    *,
    client: OllamaClient,
    force: bool,
) -> dict[str, Any]:
    timeline = read_json(timeline_path)
    frames = timeline.get("frames")
    if not isinstance(frames, list):
        raise ValueError("В visual-timeline.json отсутствует список frames")
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise ValueError(f"Некорректная запись кадра #{index + 1}")
        if frame.get("status") == "complete" and not force:
            continue
        image_path = Path(str(frame.get("path", ""))).expanduser()
        if not image_path.is_absolute():
            image_path = image_path.resolve() if image_path.is_file() else (timeline_path.parent / image_path).resolve()
        if not image_path.is_file():
            raise FileNotFoundError(f"Не найден кадр: {image_path}")
        timestamp = float(frame.get("timestamp") or 0)
        prompt = (
            "Проанализируй один кадр видео. Верни только JSON по заданной схеме. "
            "Дословно перепиши весь уверенно читаемый русский и английский текст в ocr_text. "
            "В ocr_text запрещено копировать слова этой инструкции: записывай только текст, "
            "физически видимый на изображении; если текста нет, верни пустую строку. "
            "Кратко опиши только видимое содержимое и действия. Не угадывай скрытый контекст, "
            "имена людей и события вне кадра. Неразборчивое не выдумывай, а укажи в warnings. "
            f"Таймкод кадра: {human_timestamp(timestamp)}."
        )
        try:
            result = client.chat(prompt, schema=VISION_SCHEMA, images=[image_path])
            frame.update(
                {
                    "ocr": str(result.get("ocr_text") or "").strip() or None,
                    "description": str(result.get("description") or "").strip(),
                    "actions": [str(item).strip() for item in result.get("visible_actions", []) if str(item).strip()],
                    "visual_type": result.get("visual_type", "other"),
                    "confidence": float(result.get("confidence") or 0),
                    "warnings": [str(item).strip() for item in result.get("warnings", []) if str(item).strip()],
                    "model": client.model,
                    "status": "complete",
                    "analyzed_at": utc_now(),
                }
            )
        except Exception as error:
            frame.update({"status": "failed", "error": str(error), "analyzed_at": utc_now()})
            timeline.update({"status": "failed", "model": client.model, "updated_at": utc_now()})
            atomic_write_json(timeline_path, timeline)
            raise
        timeline.update({"status": "running", "model": client.model, "updated_at": utc_now()})
        atomic_write_json(timeline_path, timeline)
    timeline.update(
        {
            "status": "complete",
            "model": client.model,
            "frame_count": len(frames),
            "analyzed_frame_count": sum(frame.get("status") == "complete" for frame in frames),
            "completed_at": utc_now(),
        }
    )
    atomic_write_json(timeline_path, timeline)
    return timeline


def transcript_chunks(segments: list[dict[str, Any]], *, max_chars: int = 8500) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    current: list[str] = []
    current_start = 0.0
    current_end = 0.0
    current_size = 0
    for segment in segments:
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        start = float(segment.get("start") or 0)
        end = float(segment.get("end") or start)
        line = f"[{human_timestamp(start)}] {text}"
        if current and current_size + len(line) + 1 > max_chars:
            chunks.append({"start": current_start, "end": current_end, "text": "\n".join(current)})
            current = []
            current_size = 0
        if not current:
            current_start = start
        current.append(line)
        current_end = end
        current_size += len(line) + 1
    if current:
        chunks.append({"start": current_start, "end": current_end, "text": "\n".join(current)})
    return chunks


def summarize_chunk(chunk: dict[str, Any], *, client: OllamaClient) -> dict[str, Any]:
    prompt = (
        "Сделай фактический конспект фрагмента транскрипта видео. Верни только JSON по схеме. "
        "Не добавляй знания извне и не исправляй утверждения автора молча. Пустые разделы оставляй "
        "пустыми массивами. chapter_title должен коротко отражать тему фрагмента.\n\n"
        f"Диапазон: {human_timestamp(float(chunk['start']))}–{human_timestamp(float(chunk['end']))}\n"
        f"Транскрипт:\n{chunk['text']}"
    )
    try:
        result = client.chat(prompt, schema=SUMMARY_SCHEMA)
    except (RuntimeError, ValueError) as error:
        lines = [
            re.sub(r"^\[[^\]]+\]\s*", "", line).strip()
            for line in str(chunk.get("text") or "").splitlines()
        ]
        lines = [line for line in lines if line]
        overview = " ".join(lines).strip()
        if len(overview) > 1600:
            overview = overview[:1599].rstrip() + "…"
        result = {
            "chapter_title": (lines[0][:120] if lines else "Фрагмент транскрипта"),
            "overview": overview or "Нет распознанного текста.",
            "key_points": lines[:8],
            "decisions": [],
            "action_items": [],
            "risks": [],
            "_fallback": True,
            "_fallback_reason": str(error),
        }
    return {"start": chunk["start"], "end": chunk["end"], **result}


def unique_strings(values: list[Any], *, limit: int = 30) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        text = str(value).strip()
        key = text.casefold()
        if not text or key in seen:
            continue
        seen.add(key)
        result.append(text)
        if len(result) >= limit:
            break
    return result


def merge_summary_items(items: list[dict[str, Any]], *, fallback_reason: str | None = None) -> dict[str, Any]:
    merged = {
        "start": min(float(item.get("start") or 0) for item in items),
        "end": max(float(item.get("end") or 0) for item in items),
        "chapter_title": "Итоговый конспект",
        "overview": " ".join(str(item.get("overview") or "") for item in items).strip(),
        "key_points": unique_strings([point for item in items for point in item.get("key_points", [])]),
        "decisions": unique_strings([point for item in items for point in item.get("decisions", [])]),
        "action_items": unique_strings([point for item in items for point in item.get("action_items", [])]),
        "risks": unique_strings([point for item in items for point in item.get("risks", [])]),
    }
    if fallback_reason:
        merged["_fallback"] = True
        merged["_fallback_reason"] = fallback_reason
    return merged


def reduce_summaries(items: list[dict[str, Any]], *, client: OllamaClient) -> dict[str, Any]:
    if len(items) == 1:
        return items[0]
    current = items
    while len(current) > 1:
        groups: list[list[dict[str, Any]]] = []
        group: list[dict[str, Any]] = []
        size = 0
        for item in current:
            serialized = json.dumps(item, ensure_ascii=False)
            if group and size + len(serialized) > 8000:
                groups.append(group)
                group = []
                size = 0
            group.append(item)
            size += len(serialized)
        if group:
            groups.append(group)
        next_items: list[dict[str, Any]] = []
        for batch in groups:
            start = min(float(item.get("start") or 0) for item in batch)
            end = max(float(item.get("end") or start) for item in batch)
            prompt = (
                "Объедини промежуточные конспекты одного видео в единый фактический конспект. "
                "Верни только JSON по схеме, устрани повторы, не добавляй знания извне.\n\n"
                + json.dumps(batch, ensure_ascii=False)
            )
            try:
                reduced = client.chat(prompt, schema=SUMMARY_SCHEMA)
            except (RuntimeError, ValueError) as error:
                return merge_summary_items(current, fallback_reason=str(error))
            next_items.append({"start": start, "end": end, **reduced})
        if len(next_items) >= len(current) and len(current) > 1:
            return merge_summary_items(current)
        current = next_items
    return current[0]


def render_summary_markdown(summary: dict[str, Any]) -> str:
    title = str(summary.get("title") or summary.get("asset_id") or "Видео")
    lines = [f"# {title}", "", "## Кратко", "", str(summary.get("overview") or "Нет данных."), ""]

    def section(name: str, values: list[Any]) -> None:
        cleaned = unique_strings(values)
        if not cleaned:
            return
        lines.extend([f"## {name}", ""])
        lines.extend(f"- {value}" for value in cleaned)
        lines.append("")

    section("Ключевые тезисы", list(summary.get("key_points") or []))
    chapters = summary.get("chapters") or []
    if chapters:
        lines.extend(["## Содержание по времени", ""])
        for chapter in chapters:
            start = human_timestamp(float(chapter.get("start") or 0))
            end = human_timestamp(float(chapter.get("end") or 0))
            heading = str(chapter.get("title") or "Фрагмент")
            overview = str(chapter.get("overview") or "").strip()
            lines.extend([f"### {start}–{end} — {heading}", "", overview, ""])
    visual_findings = summary.get("visual_findings") or []
    if visual_findings:
        lines.extend(["## Визуальные наблюдения", ""])
        for finding in visual_findings:
            timestamp = human_timestamp(float(finding.get("timestamp") or 0))
            description = str(finding.get("description") or "").strip()
            ocr = str(finding.get("ocr") or "").strip()
            line = f"- **{timestamp}:** {description}"
            if ocr:
                line += f" Текст на экране: «{ocr}»"
            lines.append(line)
        lines.append("")
    section("Решения", list(summary.get("decisions") or []))
    section("Дальнейшие действия", list(summary.get("action_items") or []))
    section("Предупреждения", list(summary.get("warnings") or []))
    section("Риски и оговорки", list(summary.get("risks") or []))
    lines.extend(
        [
            "---",
            "",
            f"_Сформировано локально моделью `{summary.get('model')}`; источник текста — локальная ASR._",
            "",
        ]
    )
    return "\n".join(lines)


def generate_summary(
    transcript_path: Path,
    *,
    visual_timeline_path: Path | None,
    output_json: Path,
    output_markdown: Path,
    client: OllamaClient,
    force: bool,
) -> dict[str, Any]:
    if output_json.exists() and output_markdown.exists() and not force:
        return read_json(output_json)
    transcript = read_json(transcript_path)
    segments = transcript.get("segments")
    if not isinstance(segments, list):
        raise ValueError("В transcript.json отсутствует список segments")
    chunks = transcript_chunks(segments)
    if not chunks:
        raise ValueError("Невозможно создать саммари: транскрипт пуст")
    partials = [summarize_chunk(chunk, client=client) for chunk in chunks]
    reduced = reduce_summaries(partials, client=client)
    fallback_reasons = unique_strings(
        [
            str(item.get("_fallback_reason") or "")
            for item in [*partials, reduced]
            if item.get("_fallback")
        ],
        limit=10,
    )
    visual_findings: list[dict[str, Any]] = []
    if visual_timeline_path and visual_timeline_path.exists():
        timeline = read_json(visual_timeline_path)
        for frame in timeline.get("frames", []):
            if not isinstance(frame, dict) or frame.get("status") != "complete":
                continue
            if not frame.get("description") and not frame.get("ocr"):
                continue
            visual_findings.append(
                {
                    "timestamp": float(frame.get("timestamp") or 0),
                    "description": str(frame.get("description") or "").strip(),
                    "ocr": str(frame.get("ocr") or "").strip() or None,
                    "actions": frame.get("actions") or [],
                }
            )
    source_title = transcript.get("title")
    topic_title = generate_topic_title(
        reduced,
        partials,
        source_title=source_title,
        client=client,
    )
    summary = {
        "asset_id": transcript.get("asset_id"),
        "title": topic_title,
        "source_title": source_title,
        "status": "complete",
        "model": client.model,
        "generation_mode": "hybrid_fallback" if fallback_reasons else "model",
        "source": "local_transcript_and_visual_timeline",
        "generated_at": utc_now(),
        "overview": str(reduced.get("overview") or "").strip(),
        "key_points": unique_strings(list(reduced.get("key_points") or [])),
        "chapters": [
            {
                "start": float(item.get("start") or 0),
                "end": float(item.get("end") or 0),
                "title": str(item.get("chapter_title") or "Фрагмент").strip(),
                "overview": str(item.get("overview") or "").strip(),
            }
            for item in partials
        ],
        "visual_findings": visual_findings,
        "decisions": unique_strings(list(reduced.get("decisions") or [])),
        "action_items": unique_strings(list(reduced.get("action_items") or [])),
        "warnings": [
            "Часть саммари сформирована детерминированным fallback из локального транскрипта: " + reason
            for reason in fallback_reasons
        ],
        "risks": unique_strings(list(reduced.get("risks") or [])),
    }
    atomic_write_json(output_json, summary)
    atomic_write_text(output_markdown, render_summary_markdown(summary))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Local OCR/vision and summaries through Ollama")
    parser.add_argument("--ollama-url", default=DEFAULT_OLLAMA_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--timeout", type=int, default=900)
    subparsers = parser.add_subparsers(dest="command", required=True)

    visuals = subparsers.add_parser("visuals")
    visuals.add_argument("--timeline", type=Path, required=True)
    visuals.add_argument("--force", action="store_true")

    summary = subparsers.add_parser("summary")
    summary.add_argument("--transcript", type=Path, required=True)
    summary.add_argument("--visual-timeline", type=Path)
    summary.add_argument("--output-json", type=Path, required=True)
    summary.add_argument("--output-markdown", type=Path, required=True)
    summary.add_argument("--force", action="store_true")

    args = parser.parse_args()
    client = OllamaClient(url=args.ollama_url, model=args.model, timeout=args.timeout)
    if args.command == "visuals":
        result = analyze_visual_timeline(args.timeline, client=client, force=args.force)
    else:
        result = generate_summary(
            args.transcript,
            visual_timeline_path=args.visual_timeline,
            output_json=args.output_json,
            output_markdown=args.output_markdown,
            client=client,
            force=args.force,
        )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
