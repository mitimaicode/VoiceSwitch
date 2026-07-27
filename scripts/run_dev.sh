#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}

export VOICESWITCH_RUNTIME="${PROJECT_ROOT}/Runtime"
export VOICESWITCH_WORKER="${PROJECT_ROOT}/worker/asr_worker.py"
export VOICESWITCH_PYTHON="${PROJECT_ROOT}/Runtime/venv/bin/python3"

cd "${PROJECT_ROOT}"
mkdir -p \
  "${PROJECT_ROOT}/.build/module-cache" \
  "${PROJECT_ROOT}/.build/swiftpm-cache"

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
CLANG_MODULE_CACHE_PATH="${PROJECT_ROOT}/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_ROOT}/.build/module-cache" \
swift run \
  --disable-sandbox \
  --cache-path "${PROJECT_ROOT}/.build/swiftpm-cache" \
  VoiceSwitch
