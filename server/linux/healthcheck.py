#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    url = "http://127.0.0.1:18790/health"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(f"VoiceSwitch Server health check failed: {error}", file=sys.stderr)
        return 1
    if not payload.get("ok") or not payload.get("ready"):
        print(json.dumps(payload, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
