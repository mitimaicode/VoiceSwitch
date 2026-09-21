from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from telegram_publication import (
    SAFE_TEXT_LIMIT,
    action_descriptors,
    build_publication_plan,
    record_message,
    record_topic,
)


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


class TelegramPublicationTests(unittest.TestCase):
    def make_artifacts(self, root: Path, *, youtube: bool = False, long_overview: bool = False) -> Path:
        source = (
            {"kind": "youtube", "canonical_url": "https://youtu.be/abc123", "original": "https://youtu.be/abc123"}
            if youtube
            else {"kind": "telegram", "original": "/private/incoming/video.mp4", "sha256": "a" * 64}
        )
        write_json(
            root / "transcript.json",
            {
                "asset_id": "asset-1",
                "title": "Тестовое видео",
                "duration": 125,
                "profile": "deep",
                "asr": {"engines_used": ["gigaam"]},
                "segments": [],
            },
        )
        write_json(
            root / "manifest.json",
            {
                "asset_id": "asset-1",
                "title": "Тестовое видео",
                "profile": "deep",
                "duration": 125,
                "qc_status": "ok",
                "vision_status": "complete",
                "summary_status": "complete",
            },
        )
        write_json(
            root / "summary.json",
            {
                "title": "Практическая проверка сайта к празднику",
                "overview": "я" * 5000 if long_overview else "Краткое содержание.",
                "key_points": ["Первый тезис"],
                "chapters": [{"start": 65, "title": "Главный фрагмент"}],
                "risks": ["Проверить выводы"],
            },
        )
        write_json(root / "metadata.json", {"channel": "Тестовый канал"})
        write_json(root / "source-info.json", source)
        write_json(root / "qc.json", {"status": "ok"})
        write_json(
            root / "job-state.json",
            {
                "profile": "deep",
                "stages": {
                    "alignment": {"status": "complete"},
                    "diarization": {"status": "complete"},
                    "visuals": {"status": "complete"},
                    "summary": {"status": "complete"},
                },
            },
        )
        (root / "summary.md").write_text("summary", encoding="utf-8")
        (root / "transcript.md").write_text("transcript", encoding="utf-8")
        return root

    def test_build_is_idempotent_and_does_not_publish_local_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            first = build_publication_plan(root, chat_id="-1001234567890", source_topic_id=7)
            second = build_publication_plan(root, chat_id="-1001234567890", source_topic_id=7)
            self.assertEqual(first["topic"]["name"], "🎬 Практическая проверка сайта к празднику")
            self.assertLessEqual(len(first["topic"]["name"]), 60)
            self.assertNotIn("/private/incoming", first["content"]["summary"])
            self.assertEqual(first["topic"]["idempotency_key"], second["topic"]["idempotency_key"])
            self.assertEqual(2, len(first["attachments"]))

    def test_youtube_timestamp_and_message_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory), youtube=True)
            plan = build_publication_plan(root, chat_id=-1001234567890)
            self.assertIn("https://youtu.be/abc123?t=65", plan["content"]["summary"])
            write_json(
                root / "summary.json",
                {"title": "Практическая проверка сайта к празднику", "overview": "я" * 5000},
            )
            plan = build_publication_plan(root, chat_id=-1001234567890)
            self.assertLessEqual(len(plan["content"]["summary"]), SAFE_TEXT_LIMIT)
            self.assertIn("Текст сокращён", plan["content"]["summary"])

    def test_internal_stage_error_is_not_published(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            write_json(
                root / "job-state.json",
                {
                    "profile": "deep",
                    "stages": {
                        "visuals": {
                            "status": "partial",
                            "error": 'Traceback: File "/home/private/enrich.py" RuntimeError: Ollama failed',
                        }
                    },
                },
            )
            plan = build_publication_plan(root, chat_id=-1001234567890)
            summary = plan["content"]["summary"]
            self.assertIn("OCR/vision: partial", summary)
            self.assertNotIn("Traceback", summary)
            self.assertNotIn("/home/private", summary)

    def test_idempotency_keys_follow_payload_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            first_plan = build_publication_plan(root, chat_id=-1001234567890)
            first = {item["kind"]: item["idempotency_key"] for item in action_descriptors(first_plan, topic_id=777)}

            write_json(
                root / "summary.json",
                {"title": "Практическая проверка сайта к празднику", "overview": "Новая версия."},
            )
            (root / "summary.md").write_text("updated summary", encoding="utf-8")
            second_plan = build_publication_plan(root, chat_id=-1001234567890)
            second = {
                item["kind"]: item["idempotency_key"]
                for item in action_descriptors(second_plan, topic_id=777)
            }

            self.assertEqual(first["status"], second["status"])
            self.assertEqual(first["transcript_document"], second["transcript_document"])
            self.assertNotEqual(first["summary"], second["summary"])
            self.assertNotEqual(first["summary_document"], second["summary_document"])

    def test_actions_resume_without_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            plan_path = root / "telegram-publication.json"
            plan = build_publication_plan(root, chat_id=-1001234567890)
            topic_action = action_descriptors(plan)
            self.assertEqual("create_forum_topic", topic_action[0]["operation"])
            self.assertTrue(topic_action[0]["owner_direct_approval"])
            record_topic(plan_path, 777)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            actions = action_descriptors(plan)
            self.assertEqual({"status", "summary", "summary_document", "transcript_document"}, {a["kind"] for a in actions})
            self.assertTrue(all(action["owner_direct_approval"] for action in actions))
            for index, action in enumerate(actions, start=100):
                record_message(plan_path, action["kind"], index)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual("completed", plan["delivery"]["status"])
            self.assertEqual([], action_descriptors(plan))

    def test_required_publication_documents_must_exist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            (root / "summary.md").unlink()
            with self.assertRaisesRegex(FileNotFoundError, "обязательный файл публикации"):
                build_publication_plan(root, chat_id=-1001234567890)

    def test_topic_name_must_be_semantic_and_come_from_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            write_json(root / "summary.json", {"title": "video-1234.mp4", "overview": "Содержание."})
            with self.assertRaisesRegex(ValueError, "именем файла"):
                build_publication_plan(root, chat_id=-1001234567890)

            write_json(root / "summary.json", {"overview": "Содержание без заголовка."})
            with self.assertRaisesRegex(ValueError, "отсутствует смысловое название"):
                build_publication_plan(root, chat_id=-1001234567890)

    def test_legacy_complete_delivery_is_migrated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_artifacts(Path(directory))
            plan_path = root / "telegram-publication.json"
            build_publication_plan(root, chat_id=-1001234567890)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            plan["delivery"] = {
                "status": "complete",
                "topic_id": 777,
                "messages": {
                    "status": 10,
                    "summary": 11,
                    "summary_document": 12,
                    "transcript_document": 13,
                },
                "completed_at": "2026-08-30T07:00:00+00:00",
            }
            write_json(plan_path, plan)
            rebuilt = build_publication_plan(root, chat_id=-1001234567890)
            self.assertEqual("completed", rebuilt["delivery"]["status"])


if __name__ == "__main__":
    unittest.main()
