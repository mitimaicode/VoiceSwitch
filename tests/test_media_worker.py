from __future__ import annotations

import json
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock


WORKER_DIR = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_DIR))

import media_worker  # noqa: E402


class DedupeTests(unittest.TestCase):
    def test_removes_longest_normalized_overlap(self) -> None:
        previous = "Сначала было важное начало. Потом — три нужных слова!"
        current = "ТРИ нужных слова, а затем новый фрагмент."
        self.assertEqual(
            media_worker.deduplicate_prefix(previous, current),
            "а затем новый фрагмент.",
        )

    def test_keeps_overlap_shorter_than_three_words(self) -> None:
        self.assertEqual(
            media_worker.deduplicate_prefix("один два", "Один, два, три"),
            "Один, два, три",
        )

    def test_fully_duplicated_text_becomes_empty(self) -> None:
        self.assertEqual(
            media_worker.deduplicate_prefix("раз два три", "Раз, два, три!"),
            "",
        )


class ChunkBoundaryTests(unittest.TestCase):
    def test_overlapping_ranges_cover_the_tail(self) -> None:
        self.assertEqual(
            media_worker.chunk_boundaries(1_300, 10, 60.0, 1.5),
            [(0, 600), (585, 1_185), (1_170, 1_300)],
        )

    def test_short_audio_is_one_chunk(self) -> None:
        self.assertEqual(
            media_worker.chunk_boundaries(50, 10, 60.0, 1.5),
            [(0, 50)],
        )

    def test_invalid_overlap_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            media_worker.chunk_boundaries(100, 10, 10.0, 10.0)


class TimestampTests(unittest.TestCase):
    def test_formats_srt_and_vtt(self) -> None:
        self.assertEqual(media_worker.format_timestamp(3_661.2344), "01:01:01,234")
        self.assertEqual(
            media_worker.format_timestamp(3_661.2346, decimal="."),
            "01:01:01.235",
        )

    def test_rounding_carries_to_next_second(self) -> None:
        self.assertEqual(media_worker.format_timestamp(59.9996), "00:01:00,000")


class PersistenceTests(unittest.TestCase):
    def test_checkpoint_round_trip_and_fingerprint_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            source = root / "sample.wav"
            source.write_bytes(b"audio")
            fingerprint = media_worker.build_fingerprint(
                source,
                engine="whisper",
                chunk_seconds=60.0,
                overlap_seconds=1.5,
                prompt="словарь",
            )
            checkpoint = root / media_worker.CHECKPOINT_NAME
            segments = [
                {
                    "index": 0,
                    "start": 0.0,
                    "end": 10.0,
                    "text": "готовый текст",
                    "language": "ru",
                    "latency": 1.0,
                }
            ]
            media_worker.write_checkpoint(
                checkpoint,
                fingerprint=fingerprint,
                completed_chunks=1,
                segments=segments,
                duration=10.0,
            )
            loaded = media_worker.load_checkpoint(checkpoint, fingerprint)
            self.assertIsNotNone(loaded)
            self.assertEqual(loaded["completed_chunks"], 1)
            checkpoint_text = checkpoint.read_text(encoding="utf-8")
            self.assertNotIn(str(source.resolve()), checkpoint_text)
            changed_prompt = media_worker.build_fingerprint(
                source,
                engine="whisper",
                chunk_seconds=60.0,
                overlap_seconds=1.5,
                prompt="другой словарь",
            )
            self.assertNotEqual(fingerprint["digest"], changed_prompt["digest"])
            changed = dict(fingerprint, digest="different")
            self.assertIsNone(media_worker.load_checkpoint(checkpoint, changed))
            self.assertEqual(list(root.glob(".transcript.checkpoint.json.*.tmp")), [])

    def test_exports_all_formats_without_full_source_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            source_dir = root / "private" / "folder"
            source_dir.mkdir(parents=True)
            source = source_dir / "видео.mp4"
            source.write_bytes(b"media")
            output = root / "result"
            segments = [
                {
                    "index": 0,
                    "start": 0.0,
                    "end": 2.5,
                    "text": "Первый фрагмент",
                    "language": "ru",
                    "latency": 0.2,
                },
                {
                    "index": 1,
                    "start": 2.0,
                    "end": 5.0,
                    "text": "Второй фрагмент",
                    "language": "ru",
                    "latency": 0.3,
                },
            ]
            paths = media_worker.export_transcript(
                output,
                source=source,
                engine="gigaam",
                duration=5.0,
                chunk_seconds=2.5,
                overlap_seconds=0.5,
                segments=segments,
            )
            self.assertEqual(set(paths), {"text", "srt", "vtt", "json"})
            self.assertTrue(all(path.is_file() for path in paths.values()))
            transcript = json.loads(paths["json"].read_text(encoding="utf-8"))
            self.assertEqual(transcript["source"]["name"], "видео.mp4")
            self.assertNotIn(str(source.resolve()), paths["json"].read_text(encoding="utf-8"))
            self.assertIn("00:00:00,000 --> 00:00:02,500", paths["srt"].read_text())
            self.assertTrue(paths["vtt"].read_text().startswith("WEBVTT\n"))
            self.assertEqual(list(output.glob(".*.tmp")), [])

    def test_process_request_resumes_completed_job_without_loading_model(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            source = root / "sample.wav"
            with wave.open(str(source), "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(16_000)
                wav_file.writeframes(b"\x00\x00" * 33_600)

            class FakeRecognizer:
                texts = iter(
                    (
                        "один два три четыре",
                        "два три четыре пять",
                        "три четыре пять шесть",
                    )
                )

                def __init__(self, _engine: str, _cache: Path):
                    pass

                def load(self) -> None:
                    pass

                def transcribe(self, _audio: Path, _prompt: str) -> tuple[str, str]:
                    return next(self.texts), "ru"

            request = {
                "id": "job-1",
                "input": str(source),
                "output_dir": str(root / "output"),
                "cache": str(root / "cache"),
                "engine": "whisper",
                "prompt": "",
                "chunk_seconds": 1.0,
                "overlap_seconds": 0.1,
            }

            def copy_normalized(input_path: Path, destination: Path) -> None:
                destination.write_bytes(input_path.read_bytes())

            with (
                mock.patch.object(media_worker, "configure_environment"),
                mock.patch.object(media_worker, "normalize_media", copy_normalized),
                mock.patch.object(media_worker, "Recognizer", FakeRecognizer),
                mock.patch.object(media_worker, "emit_progress"),
            ):
                result = media_worker.process_request(request)

            self.assertEqual(result["text"], "один два три четыре\nпять\nшесть")
            self.assertFalse((root / "output" / ".work").exists())
            transcript = json.loads(
                (root / "output" / "transcript.json").read_text(encoding="utf-8")
            )
            starts = [segment["start"] for segment in transcript["segments"]]
            ends = [segment["end"] for segment in transcript["segments"]]
            self.assertTrue(all(start >= end for start, end in zip(starts[1:], ends)))

            class UnexpectedRecognizer:
                def __init__(self, _engine: str, _cache: Path):
                    raise AssertionError("completed checkpoint must skip model loading")

            with (
                mock.patch.object(media_worker, "configure_environment"),
                mock.patch.object(media_worker, "normalize_media", copy_normalized),
                mock.patch.object(media_worker, "Recognizer", UnexpectedRecognizer),
                mock.patch.object(media_worker, "emit_progress"),
            ):
                resumed = media_worker.process_request(request)
            self.assertEqual(resumed["text"], result["text"])


if __name__ == "__main__":
    unittest.main()
