#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VERSION="${1:-0.1.0-beta}"
ARCH="$(uname -m)"
DIST_ROOT="${PROJECT_ROOT}/dist"
STAGING_ROOT="${DIST_ROOT}/VoiceSwitch-${VERSION}-macos-${ARCH}"
ARCHIVE="${DIST_ROOT}/VoiceSwitch-${VERSION}-macos-${ARCH}.zip"
DMG="${DIST_ROOT}/VoiceSwitch-${VERSION}-macos-${ARCH}.dmg"
DMG_STAGING="${DIST_ROOT}/.dmg-${VERSION}-${ARCH}"

if [[ "${ARCH}" != "arm64" ]]; then
  print -u2 "Release beta поддерживает только Apple Silicon (arm64)."
  exit 1
fi

/bin/rm -rf "${STAGING_ROOT}"
mkdir -p "${STAGING_ROOT}" "${DIST_ROOT}"

VOICESWITCH_INCLUDE_RUNTIME=0 \
VOICESWITCH_CODESIGN_IDENTITY="${VOICESWITCH_CODESIGN_IDENTITY:--}" \
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

ARCHIVE_NAME="${ARCHIVE:t}"
(
  cd "${DIST_ROOT}"
  shasum -a 256 "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"
)

/bin/rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
ditto "${STAGING_ROOT}/VoiceSwitch.app" "${DMG_STAGING}/VoiceSwitch.app"
ln -s /Applications "${DMG_STAGING}/Программы"
cp "${PROJECT_ROOT}/Resources/ПЕРВЫЙ ЗАПУСК.txt" "${DMG_STAGING}/ПЕРВЫЙ ЗАПУСК.txt"

/bin/rm -f "${DMG}"
hdiutil create \
  -volname "VoiceSwitch" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DMG}"
/bin/rm -rf "${DMG_STAGING}"

DMG_NAME="${DMG:t}"
(
  cd "${DIST_ROOT}"
  shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)
print "Релиз: ${ARCHIVE}"
print "Установочный образ: ${DMG}"
