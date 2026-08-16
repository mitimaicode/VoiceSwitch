#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
WORKSPACE_ROOT=${PROJECT_ROOT:h:h}
OUTPUT_ROOT="${1:-${WORKSPACE_ROOT}/outputs/VoiceSwitch}"
APP_ROOT="${OUTPUT_ROOT}/VoiceSwitch.app"
CONTENTS="${APP_ROOT}/Contents"

if [[ -n "${SDKROOT:-}" ]]; then
  SDK_PATH="${SDKROOT}"
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

cd "${PROJECT_ROOT}"
mkdir -p \
  "${PROJECT_ROOT}/.build/module-cache" \
  "${PROJECT_ROOT}/.build/swiftpm-cache"

SWIFT_BUILD_FLAGS=()
SDK_INTERFACE=$(
  find \
    "${SDK_PATH}/usr/lib/swift/Swift.swiftmodule" \
    -name '*-apple-macos.swiftinterface' \
    -print \
    -quit
)
if [[ -n "${SDK_INTERFACE}" ]]; then
  SDK_SWIFT_VERSION=$(
    sed -n \
      's#^// swift-compiler-version: Apple Swift version \([0-9.]*\).*#\1#p' \
      "${SDK_INTERFACE}" |
      head -n 1
  )
  COMPILER_SWIFT_VERSION=$(
    swiftc --version |
      sed -n 's#.*Apple Swift version \([0-9.]*\).*#\1#p' |
      head -n 1
  )
  if [[ -n "${SDK_SWIFT_VERSION}" &&
        -n "${COMPILER_SWIFT_VERSION}" &&
        "${SDK_SWIFT_VERSION}" != "${COMPILER_SWIFT_VERSION}" ]]; then
    SWIFT_BUILD_FLAGS+=(
      -Xswiftc -Xfrontend
      -Xswiftc -interface-compiler-version
      -Xswiftc -Xfrontend
      -Xswiftc "${SDK_SWIFT_VERSION}"
    )
  fi
fi

SDKROOT="${SDK_PATH}" \
CLANG_MODULE_CACHE_PATH="${PROJECT_ROOT}/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_ROOT}/.build/module-cache" \
swift build \
  -c release \
  --disable-sandbox \
  --cache-path "${PROJECT_ROOT}/.build/swiftpm-cache" \
  "${SWIFT_BUILD_FLAGS[@]}"

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
cp "${PROJECT_ROOT}/worker/text_worker.py" "${CONTENTS}/Resources/text_worker.py"
cp "${PROJECT_ROOT}/Resources/install_runtime.sh" "${CONTENTS}/Resources/install_runtime.sh"
cp "${PROJECT_ROOT}/README.md" "${OUTPUT_ROOT}/README.md"

chmod +x \
  "${CONTENTS}/MacOS/VoiceSwitch" \
  "${CONTENTS}/Resources/install_runtime.sh"

if [[ "${VOICESWITCH_INCLUDE_RUNTIME:-0}" == "1" && -d "${PROJECT_ROOT}/Runtime" ]]; then
  mkdir -p "${OUTPUT_ROOT}/Runtime"
  cp -cR "${PROJECT_ROOT}/Runtime/." "${OUTPUT_ROOT}/Runtime/"
fi

SIGNING_IDENTITY="${VOICESWITCH_CODESIGN_IDENTITY:--}"
if [[ -z "${VOICESWITCH_CODESIGN_IDENTITY:-}" ]] &&
   security find-identity -v -p codesigning 2>/dev/null |
     /usr/bin/grep -Fq '"VoiceSwitch Local Signing"'; then
  SIGNING_IDENTITY="VoiceSwitch Local Signing"
fi

codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_ROOT}"

print "Собрано: ${APP_ROOT}"
