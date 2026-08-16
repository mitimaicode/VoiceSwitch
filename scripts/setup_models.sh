#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
RUNTIME_ROOT="${PROJECT_ROOT}/Runtime"
COMPONENTS="${1:-gigaam,whisper,qwen,text}"

"${PROJECT_ROOT}/Resources/install_runtime.sh" \
  "${RUNTIME_ROOT}" \
  "${PROJECT_ROOT}/worker/asr_worker.py" \
  "${PROJECT_ROOT}/worker/text_worker.py" \
  "${COMPONENTS}"
