from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class LinuxServerReleaseContractTests(unittest.TestCase):
    def test_installed_versions_are_pinned(self) -> None:
        stt = (ROOT / "requirements-stt.txt").read_text(encoding="utf-8")
        video = (ROOT / "requirements-video.txt").read_text(encoding="utf-8")
        for expected in (
            "torch==2.6.0+cu124",
            "torchaudio==2.6.0+cu124",
            "gigaam==0.2.0",
            "openai-whisper==20250625",
        ):
            self.assertIn(expected, stt)
        for expected in (
            "torch==2.8.0+cu128",
            "torchaudio==2.8.0+cu128",
            "qwen-asr==0.0.6",
            "pyannote.audio==4.0.7",
            "transformers==4.57.6",
            "accelerate==1.12.0",
        ):
            self.assertIn(expected, video)

    def test_service_is_loopback_only(self) -> None:
        unit = (ROOT / "systemd" / "mitim-stt.service.in").read_text(
            encoding="utf-8"
        )
        self.assertIn("--host 127.0.0.1 --port 18790", unit)

    def test_private_server_values_are_not_published(self) -> None:
        forbidden = (
            "/home/" + "ai",
            "-100" + "4497951319",
            "bot:" + "mitim_" + "openclaw",
        )
        for path in ROOT.rglob("*"):
            if not path.is_file() or path.suffix in {".pyc"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for value in forbidden:
                self.assertNotIn(value, text, f"{value!r} leaked through {path}")

    def test_pipeline_and_plugin_versions_match_snapshot(self) -> None:
        pipeline = (ROOT / "video" / "video_pipeline.py").read_text(
            encoding="utf-8"
        )
        plugin = (ROOT / "openclaw-plugin" / "openclaw.plugin.json").read_text(
            encoding="utf-8"
        )
        self.assertIn('PIPELINE_VERSION = "mitim-video-pipeline-v3"', pipeline)
        self.assertIn('"version": "0.1.6"', plugin)


if __name__ == "__main__":
    unittest.main()
