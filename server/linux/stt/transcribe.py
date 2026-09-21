#!/usr/bin/env python3
"""OpenClaw CLI adapter: print only the transcript to stdout."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


AUDIO_SUFFIXES = {".oga", ".ogg", ".opus", ".mp3", ".m4a", ".wav", ".webm"}


def resolve_audio_path(raw: str) -> Path:
    """Resolve OpenClaw's path and tolerate its empty-path fallback."""
    candidate = Path(os.path.abspath(os.path.expanduser(raw)))
    if candidate.is_file():
        return candidate

    # Some Telegram preflight paths arrive as an empty CLI argument. In that
    # case abspath() becomes the gateway working directory. Limit
    # the recovery search to OpenClaw's own inbound media directories and only
    # accept files written very recently.
    if candidate.is_dir():
        roots = [
            Path.home() / ".openclaw" / "media" / "inbound",
            Path.home() / ".openclaw" / "workspace" / "media" / "inbound",
        ]
        deadline = time.time() - 300
        recent = [
            path
            for root in roots
            if root.is_dir()
            for path in root.rglob("*")
            if path.is_file()
            and path.suffix.lower() in AUDIO_SUFFIXES
            and path.stat().st_mtime >= deadline
        ]
        if recent:
            return max(recent, key=lambda path: path.stat().st_mtime)
    return candidate


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: mitim-stt-transcribe AUDIO_PATH", file=sys.stderr)
        return 2

    request = urllib.request.Request(
        os.environ.get("MITIM_STT_URL", "http://127.0.0.1:18790/transcribe"),
        data=json.dumps(
            {
                "path": str(resolve_audio_path(sys.argv[1])),
                "engine": os.environ.get("MITIM_STT_ENGINE", "auto"),
            }
        ).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(f"mitim-stt request failed: {error}", file=sys.stderr)
        return 1

    if payload.get("error"):
        print(str(payload["error"]), file=sys.stderr)
        return 1
    text = str(payload.get("text", "")).strip()
    if text:
        sys.stdout.write(text)
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
