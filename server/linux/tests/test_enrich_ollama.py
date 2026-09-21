#!/usr/bin/env python3

import json
import unittest
from unittest.mock import patch

from enrich_ollama import (
    OllamaClient,
    SUMMARY_SCHEMA,
    generate_topic_title,
    normalize_topic_title,
    reduce_summaries,
    summarize_chunk,
)


class FakeResponse:
    def __init__(self, content: str) -> None:
        self.payload = json.dumps({"message": {"content": content}}, ensure_ascii=False).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self) -> bytes:
        return self.payload


class BrokenClient:
    model = "broken-model"

    def chat(self, prompt, *, schema, images=None):
        raise ValueError("невалидный JSON")


class EnrichOllamaTests(unittest.TestCase):
    def test_client_retries_invalid_json(self) -> None:
        responses = iter(
            [
                FakeResponse("это не JSON"),
                FakeResponse(
                    json.dumps(
                        {
                            "chapter_title": "Тема",
                            "overview": "Обзор",
                            "key_points": [],
                            "decisions": [],
                            "action_items": [],
                            "risks": [],
                        },
                        ensure_ascii=False,
                    )
                ),
            ]
        )
        calls = []

        def fake_urlopen(request, timeout):
            calls.append(json.loads(request.data.decode("utf-8")))
            return next(responses)

        client = OllamaClient(url="http://ollama.test", model="test", json_attempts=2)
        with patch("enrich_ollama.urlopen", side_effect=fake_urlopen):
            result = client.chat("Сделай саммари", schema=SUMMARY_SCHEMA)

        self.assertEqual(result["chapter_title"], "Тема")
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(calls[1]["messages"]), 3)

    def test_chunk_uses_deterministic_fallback(self) -> None:
        result = summarize_chunk(
            {
                "start": 0,
                "end": 5,
                "text": "[0:00] Первая мысль.\n[0:03] Вторая мысль.",
            },
            client=BrokenClient(),
        )

        self.assertTrue(result["_fallback"])
        self.assertIn("Первая мысль", result["overview"])
        self.assertEqual(result["key_points"], ["Первая мысль.", "Вторая мысль."])

    def test_reduce_uses_deterministic_fallback(self) -> None:
        items = [
            {
                "start": 0,
                "end": 5,
                "overview": "Первая часть.",
                "key_points": ["Тезис 1"],
                "decisions": [],
                "action_items": [],
                "risks": [],
            },
            {
                "start": 5,
                "end": 10,
                "overview": "Вторая часть.",
                "key_points": ["Тезис 2"],
                "decisions": [],
                "action_items": [],
                "risks": [],
            },
        ]

        result = reduce_summaries(items, client=BrokenClient())

        self.assertTrue(result["_fallback"])
        self.assertEqual(result["key_points"], ["Тезис 1", "Тезис 2"])

    def test_topic_title_is_short_and_semantic(self) -> None:
        title = normalize_topic_title("🎬 Проверка сайта к первому сентября 2026")
        self.assertEqual(title, "Проверка сайта к первому сентября 2026")
        self.assertLessEqual(len(title.split()), 8)
        self.assertLessEqual(len(title), 56)

    def test_topic_title_rejects_generic_and_file_names(self) -> None:
        with self.assertRaises(ValueError):
            normalize_topic_title("Видео")
        with self.assertRaises(ValueError):
            normalize_topic_title("camera-upload-1234.mp4")

    def test_topic_title_has_deterministic_summary_fallback(self) -> None:
        title = generate_topic_title(
            {"overview": "Подробная проверка готовности сайта.", "key_points": []},
            [{"chapter_title": "Проверка сайта к первому сентября"}],
            source_title="camera-upload-1234.mp4",
            client=BrokenClient(),
        )
        self.assertEqual(title, "Проверка сайта к первому сентября")


if __name__ == "__main__":
    unittest.main()
