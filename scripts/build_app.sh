#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
WORKSPACE_ROOT=${PROJECT_ROOT:h:h}
OUTPUT_ROOT="${1:-${WORKSPACE_ROOT}/outputs/VoiceSwitch}"
APP_ROOT="${OUTPUT_ROOT}/VoiceSwitch.app"
CONTENTS="${APP_ROOT}/Contents"
LOCAL_COMPATIBILITY_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -n "${SDKROOT:-}" ]]; then
  SDK_PATH="${SDKROOT}"
elif [[ -d "${LOCAL_COMPATIBILITY_SDK}" ]]; then
  SDK_PATH="${LOCAL_COMPATIBILITY_SDK}"
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

cd "${PROJECT_ROOT}"
mkdir -p \
  "${PROJECT_ROOT}/.build/module-cache" \
  "${PROJECT_ROOT}/.build/swiftpm-cache"

SDKROOT="${SDK_PATH}" \
CLANG_MODULE_CACHE_PATH="${PROJECT_ROOT}/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_ROOT}/.build/module-cache" \
swift build \
  -c release \
  --disable-sandbox \
  --cache-path "${PROJECT_ROOT}/.build/swiftpm-cache"

if [[ -d "${APP_ROOT}" ]]; then
  /bin/rm -rf "${APP_ROOT}"
fi

mkdir -p \
  "${CONTENTS}/MacOS" \
  "${CONTENTS}/Resources" \
  "${OUTPUT_ROOT}"

cp "${PROJECT_ROOT}/.build/release/VoiceSwitch" "${CONTENTS}/MacOS/VoiceSwitch"
cp "${PROJECT_ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "${PROJECT_ROOT}/worker/asr_worker.py" "${CONTENTS}/Resources/asr_worker.py"
cp "${PROJECT_ROOT}/Resources/install_runtime.sh" "${CONTENTS}/Resources/install_runtime.sh"
cp "${PROJECT_ROOT}/README.md" "${OUTPUT_ROOT}/README.md"

chmod +x \
  "${CONTENTS}/MacOS/VoiceSwitch" \
  "${CONTENTS}/Resources/install_runtime.sh"

if [[ "${VOICESWITCH_INCLUDE_RUNTIME:-0}" == "1" && -d "${PROJECT_ROOT}/Runtime" ]]; then
  mkdir -p "${OUTPUT_ROOT}/Runtime"
  cp -cR "${PROJECT_ROOT}/Runtime/." "${OUTPUT_ROOT}/Runtime/"
fi

codesign --force --deep --sign - "${APP_ROOT}"

print "Собрано: ${APP_ROOT}"
