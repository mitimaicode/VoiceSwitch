#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VERSION="${1:-0.1.0-beta}"
ARCH="$(uname -m)"
DIST_ROOT="${PROJECT_ROOT}/dist"
STAGING_ROOT="${DIST_ROOT}/VoiceSwitch-${VERSION}-macos-${ARCH}"
ARCHIVE="${DIST_ROOT}/VoiceSwitch-${VERSION}-macos-${ARCH}.zip"

if [[ "${ARCH}" != "arm64" ]]; then
  print -u2 "Release beta поддерживает только Apple Silicon (arm64)."
  exit 1
fi

/bin/rm -rf "${STAGING_ROOT}"
mkdir -p "${STAGING_ROOT}" "${DIST_ROOT}"

VOICESWITCH_INCLUDE_RUNTIME=0 \
  "${PROJECT_ROOT}/scripts/build_app.sh" "${STAGING_ROOT}"

cp "${PROJECT_ROOT}/INSTALL.md" "${STAGING_ROOT}/INSTALL.md"
cp "${PROJECT_ROOT}/LICENSE" "${STAGING_ROOT}/LICENSE"

/bin/rm -f "${ARCHIVE}"
ditto \
  -c \
  -k \
  --norsrc \
  --noextattr \
  --noqtn \
  --noacl \
  --keepParent \
  "${STAGING_ROOT}" \
  "${ARCHIVE}"

shasum -a 256 "${ARCHIVE}" > "${ARCHIVE}.sha256"
print "Релиз: ${ARCHIVE}"
