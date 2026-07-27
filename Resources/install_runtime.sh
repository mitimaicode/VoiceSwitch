#!/bin/zsh
set -euo pipefail

RUNTIME_ROOT=${1:?Usage: install_runtime.sh RUNTIME_ROOT WORKER_SCRIPT}
WORKER_SCRIPT=${2:?Usage: install_runtime.sh RUNTIME_ROOT WORKER_SCRIPT}
TOOLS_ROOT="${RUNTIME_ROOT}/Tools"
UV_ROOT="${TOOLS_ROOT}/uv"
UV_EXECUTABLE="${UV_ROOT}/uv"
PYTHON_ROOT="${RUNTIME_ROOT}/Python"
VENV_ROOT="${RUNTIME_ROOT}/venv"
MODEL_ROOT="${RUNTIME_ROOT}/Models"
BIN_ROOT="${RUNTIME_ROOT}/bin"
UV_CACHE="${RUNTIME_ROOT}/uv-cache"

UV_VERSION="0.11.32"
GIGAAM_COMMIT="559d88d6b72541412743929f633a6ae7c9950b85"
GIGAAM_ARCHIVE="https://github.com/salute-developers/GigaAM/archive/${GIGAAM_COMMIT}.zip"

status() {
  print -r -- "__VOICESWITCH_SETUP__$1"
}

fail() {
  status "Ошибка: $1"
  print -u2 -r -- "$1"
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "VoiceSwitch поддерживает только macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Эта beta-версия предназначена для Mac с Apple Silicon."
[[ -f "${WORKER_SCRIPT}" ]] || fail "Не найден модуль распознавания."
command -v curl >/dev/null 2>&1 || fail "В macOS не найден curl."

if [[ "${VOICESWITCH_SETUP_VALIDATE_ONLY:-0}" == "1" ]]; then
  status "Проверка установщика завершена."
  exit 0
fi

mkdir -p \
  "${TOOLS_ROOT}" \
  "${PYTHON_ROOT}" \
  "${MODEL_ROOT}" \
  "${BIN_ROOT}" \
  "${UV_CACHE}"

export UV_NO_MODIFY_PATH=1
export UV_NO_PROGRESS=1
export UV_CACHE_DIR="${UV_CACHE}"
export UV_PYTHON_INSTALL_DIR="${PYTHON_ROOT}"
export HF_HOME="${MODEL_ROOT}/huggingface"
export TORCH_HOME="${MODEL_ROOT}/torch"
export TOKENIZERS_PARALLELISM=false
export PATH="${BIN_ROOT}:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ ! -x "${UV_EXECUTABLE}" ]]; then
  status "Загружаю менеджер Python…"
  INSTALLER="${TOOLS_ROOT}/uv-install.sh"
  curl \
    --fail \
    --location \
    --retry 3 \
    --silent \
    --show-error \
    "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    --output "${INSTALLER}"
  UV_UNMANAGED_INSTALL="${UV_ROOT}" /bin/sh "${INSTALLER}"
fi

[[ -x "${UV_EXECUTABLE}" ]] || fail "Не удалось установить uv."

status "Устанавливаю изолированный Python 3.12…"
"${UV_EXECUTABLE}" python install 3.12 --install-dir "${PYTHON_ROOT}" --no-bin

if [[ ! -x "${VENV_ROOT}/bin/python3" ]]; then
  "${UV_EXECUTABLE}" venv \
    "${VENV_ROOT}" \
    --python 3.12 \
    --managed-python
fi

PYTHON="${VENV_ROOT}/bin/python3"
[[ -x "${PYTHON}" ]] || fail "Не удалось создать Python-окружение."

status "Устанавливаю локальные движки распознавания…"
"${UV_EXECUTABLE}" pip install \
  --python "${PYTHON}" \
  "numpy<3" \
  "huggingface_hub[hf_xet]" \
  imageio-ffmpeg \
  mlx-whisper \
  "mlx-qwen3-asr==0.3.5" \
  "${GIGAAM_ARCHIVE}"

FFMPEG_EXECUTABLE=$(
  "${PYTHON}" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
)
ln -sf "${FFMPEG_EXECUTABLE}" "${BIN_ROOT}/ffmpeg"

status "Загружаю Whisper Large V3 Turbo…"
"${PYTHON}" "${WORKER_SCRIPT}" \
  --download \
  --engine whisper \
  --cache "${MODEL_ROOT}"

status "Загружаю GigaAM v3 E2E RNNT…"
"${PYTHON}" "${WORKER_SCRIPT}" \
  --download \
  --engine gigaam \
  --cache "${MODEL_ROOT}"

status "Загружаю Qwen3-ASR 1.7B…"
"${PYTHON}" "${WORKER_SCRIPT}" \
  --download \
  --engine qwen \
  --cache "${MODEL_ROOT}"

print -r -- "runtime_version=2" > "${RUNTIME_ROOT}/install-complete.txt"
print -r -- "uv_version=${UV_VERSION}" >> "${RUNTIME_ROOT}/install-complete.txt"
print -r -- "gigaam_commit=${GIGAAM_COMMIT}" >> "${RUNTIME_ROOT}/install-complete.txt"
print -r -- "qwen_model=Qwen/Qwen3-ASR-1.7B" >> "${RUNTIME_ROOT}/install-complete.txt"

status "Готово — три локальные модели установлены."
