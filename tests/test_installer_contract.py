from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class InstallerContractTests(unittest.TestCase):
    def test_gigaam_installs_explicit_compatible_torch_pair(self) -> None:
        script = (PROJECT_ROOT / "Resources" / "install_runtime.sh").read_text()

        self.assertIn('TORCH_VERSION="2.13.0"', script)
        self.assertIn('TORCHAUDIO_VERSION="2.11.0"', script)
        self.assertIn('"torch==${TORCH_VERSION}"', script)
        self.assertIn('"torchaudio==${TORCHAUDIO_VERSION}"', script)
        self.assertIn("VOICESWITCH_SETUP_DEPENDENCIES_ONLY", script)

    def test_swift_and_installer_expect_same_runtime_version(self) -> None:
        script = (PROJECT_ROOT / "Resources" / "install_runtime.sh").read_text()
        runtime_paths = (
            PROJECT_ROOT / "Sources" / "VoiceSwitch" / "RuntimePaths.swift"
        ).read_text()

        marker_match = re.search(r'print -r -- "runtime_version=(\d+)"', script)
        swift_match = re.search(r"expectedRuntimeVersion = (\d+)", runtime_paths)
        self.assertIsNotNone(marker_match)
        self.assertIsNotNone(swift_match)
        self.assertEqual(marker_match.group(1), swift_match.group(1))


if __name__ == "__main__":
    unittest.main()
