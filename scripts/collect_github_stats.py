#!/usr/bin/env python3
"""Archive GitHub traffic and release metrics for the VoiceSwitch repository."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


API_ROOT = "https://api.github.com"


def api_get(path: str, token: str) -> Any:
    request = urllib.request.Request(
        API_ROOT + path,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "VoiceSwitch-metrics-workflow",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def optional_api_get(path: str, token: str) -> Any | None:
    try:
        return api_get(path, token)
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            return None
        raise


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not token or "/" not in repository:
        print("GITHUB_TOKEN and GITHUB_REPOSITORY are required.", file=sys.stderr)
        return 2

    encoded_repository = urllib.parse.quote(repository, safe="/")
    prefix = f"/repos/{encoded_repository}"

    metadata = api_get(prefix, token)
    releases = api_get(f"{prefix}/releases?per_page=100", token)
    traffic_views = optional_api_get(f"{prefix}/traffic/views?per=day", token)
    traffic_clones = optional_api_get(f"{prefix}/traffic/clones?per=day", token)
    referrers = optional_api_get(f"{prefix}/traffic/popular/referrers", token)
    popular_paths = optional_api_get(f"{prefix}/traffic/popular/paths", token)

    release_rows = []
    total_downloads = 0
    for release in releases:
        assets = []
        for asset in release.get("assets", []):
            count = int(asset.get("download_count", 0))
            total_downloads += count
            assets.append(
                {
                    "name": asset.get("name"),
                    "downloads": count,
                    "size": asset.get("size"),
                    "updated_at": asset.get("updated_at"),
                }
            )
        release_rows.append(
            {
                "tag": release.get("tag_name"),
                "name": release.get("name"),
                "published_at": release.get("published_at"),
                "prerelease": release.get("prerelease"),
                "assets": assets,
            }
        )

    snapshot = {
        "schema_version": 1,
        "collected_at": datetime.now(UTC).isoformat(),
        "repository": repository,
        "community": {
            "stars": metadata.get("stargazers_count"),
            "forks": metadata.get("forks_count"),
            "watchers": metadata.get("subscribers_count"),
            "open_issues_and_pull_requests": metadata.get("open_issues_count"),
        },
        "releases": {
            "total_asset_downloads": total_downloads,
            "items": release_rows,
        },
        "traffic_last_14_days": {
            "views": traffic_views,
            "clones": traffic_clones,
            "referrers": referrers,
            "popular_paths": popular_paths,
        },
    }

    metrics_root = Path("metrics")
    metrics_root.mkdir(parents=True, exist_ok=True)
    latest = metrics_root / "github-stats.json"
    history = metrics_root / "github-stats.jsonl"

    latest.write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    with history.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(snapshot, ensure_ascii=False) + "\n")

    print(
        f"Collected {total_downloads} release downloads for {repository}.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
