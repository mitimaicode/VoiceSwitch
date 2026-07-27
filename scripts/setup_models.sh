#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
RUNTIME_ROOT="${PROJECT_ROOT}/Runtime"

"${PROJECT_ROOT}/Resources/install_runtime.sh" \
  "${RUNTIME_ROOT}" \
  "${PROJECT_ROOT}/worker/asr_worker.py"
