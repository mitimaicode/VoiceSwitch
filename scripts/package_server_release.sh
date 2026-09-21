#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/server/linux/VERSION")}"
OUTPUT_ROOT="$ROOT/dist"
ARCHIVE_NAME="VoiceSwitch-Server-${VERSION}-linux-x86_64"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/voiceswitch-server-package.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_ROOT" "$TEMP_ROOT/$ARCHIVE_NAME"
cp -R "$ROOT/server/linux/." "$TEMP_ROOT/$ARCHIVE_NAME/"
find "$TEMP_ROOT/$ARCHIVE_NAME" -type d -name __pycache__ -prune -exec rm -rf {} +
chmod 0755 \
  "$TEMP_ROOT/$ARCHIVE_NAME/install.sh" \
  "$TEMP_ROOT/$ARCHIVE_NAME/healthcheck.py"

tar -C "$TEMP_ROOT" -czf "$OUTPUT_ROOT/$ARCHIVE_NAME.tar.gz" "$ARCHIVE_NAME"
(
  cd "$OUTPUT_ROOT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ARCHIVE_NAME.tar.gz" > "$ARCHIVE_NAME.tar.gz.sha256"
  else
    shasum -a 256 "$ARCHIVE_NAME.tar.gz" > "$ARCHIVE_NAME.tar.gz.sha256"
  fi
)

echo "$OUTPUT_ROOT/$ARCHIVE_NAME.tar.gz"
