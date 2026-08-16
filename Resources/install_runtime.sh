#!/bin/zsh
set -euo pipefail

RUNTIME_ROOT=${1:?Usage: install_runtime.sh RUNTIME_ROOT ASR_WORKER TEXT_WORKER}
ASR_WORKER=${2:?Usage: install_runtime.sh RUNTIME_ROOT ASR_WORKER TEXT_WORKER}
TEXT_WORKER=${3:?Usage: install_runtime.sh RUNTIME_ROOT ASR_WORKER TEXT_WORKER}
COMPONENTS_CSV=${4:-gigaam,whisper,qwen,text}
TOOLS_ROOT="${RUNTIME_ROOT}/Tools"
UV_ROOT="${TOOLS_ROOT}/uv"
UV_EXECUTABLE="${UV_ROOT}/uv"
PYTHON_ROOT="${RUNTIME_ROOT}/Python"
VENV_ROOT="${RUNTIME_ROOT}/venv"
MODEL_ROOT="${RUNTIME_ROOT}/Models"
BIN_ROOT="${RUNTIME_ROOT}/bin"
UV_CACHE="${RUNTIME_ROOT}/uv-cache"
LOG_FILE="${RUNTIME_ROOT}/install.log"
COMPONENT_MARKERS_ROOT="${RUNTIME_ROOT}/components"

UV_VERSION="0.11.32"
GIGAAM_COMMIT="559d88d6b72541412743929f633a6ae7c9950b85"
GIGAAM_ARCHIVE="https://github.com/salute-developers/GigaAM/archive/${GIGAAM_COMMIT}.zip"

STATUS_MARKER="__VOICESWITCH_SETUP__"
ERROR_MARKER="__VOICESWITCH_SETUP_ERROR__"
RETRY_DELAY_SECONDS="${VOICESWITCH_RETRY_DELAY_SECONDS:-2}"
REQUESTED_COMPONENTS=("${(@s:,:)COMPONENTS_CSV}")

component_requested() {
  local candidate=$1
  local component
  for component in "${REQUESTED_COMPONENTS[@]}"; do
    [[ "${component}" == "${candidate}" ]] && return 0
  done
  return 1
}

mark_component() {
  local component=$1
  mkdir -p "${COMPONENT_MARKERS_ROOT}"
  print -r -- "installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "${COMPONENT_MARKERS_ROOT}/${component}.ready"
}

write_install_marker() {
  local temporary_marker="${RUNTIME_ROOT}/install-complete.txt.tmp"
  {
    print -r -- "runtime_version=4"
    print -r -- "selective_install=1"
    print -r -- "uv_version=${UV_VERSION}"
    print -r -- "gigaam_commit=${GIGAAM_COMMIT}"
    local marker
    for marker in "${COMPONENT_MARKERS_ROOT}"/*.ready(N); do
      print -r -- "component=${marker:t:r}"
    done
  } > "${temporary_marker}"
  mv "${temporary_marker}" "${RUNTIME_ROOT}/install-complete.txt"
}

status() {
  print -r -- "${STATUS_MARKER}$1"
}

report_error() {
  print -r -- "${ERROR_MARKER}$1"
}

fail() {
  status "Ошибка: $1"
  report_error "$1"
  print -u2 -r -- "$1"
  exit 1
}

fail_step() {
  fail \
    "Сбой на этапе «$1». Повторный запуск продолжит загрузку. Журнал: ${LOG_FILE}"
}

run_with_retries() {
  local description=$1
  local maximum_attempts=$2
  shift 2

  status "${description}"

  local attempt=1
  local exit_code=0
  while (( attempt <= maximum_attempts )); do
    "$@" && return 0
    exit_code=$?
    if (( attempt >= maximum_attempts )); then
      return "${exit_code}"
    fi

    attempt=$(( attempt + 1 ))
    status \
      "Этап не завершён. Повтор ${attempt} из ${maximum_attempts}; загруженные файлы сохраняются…"
    /bin/sleep $(( attempt * RETRY_DELAY_SECONDS ))
  done

  return "${exit_code}"
}

download_with_resume() {
  local url=$1
  local destination=$2
  local description=$3
  local partial="${destination}.part"

  run_with_retries \
    "${description}" \
    3 \
    curl \
      --fail \
      --location \
      --retry 5 \
      --retry-all-errors \
      --connect-timeout 30 \
      --continue-at - \
      --silent \
      --show-error \
      "${url}" \
      --output "${partial}" || fail_step "${description}"
  mv "${partial}" "${destination}"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "VoiceSwitch поддерживает только macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Эта beta-версия предназначена для Mac с Apple Silicon."
[[ -f "${ASR_WORKER}" ]] || fail "Не найден модуль распознавания."
[[ -f "${TEXT_WORKER}" ]] || fail "Не найден модуль локального редактора."
command -v curl >/dev/null 2>&1 || fail "В macOS не найден curl."

for component in "${REQUESTED_COMPONENTS[@]}"; do
  case "${component}" in
    gigaam|whisper|qwen|text) ;;
    *) fail "Неизвестный компонент установки: ${component}" ;;
  esac
done
(( ${#REQUESTED_COMPONENTS[@]} > 0 )) || fail "Не выбраны модели для установки."

if [[ "${VOICESWITCH_SETUP_VALIDATE_ONLY:-0}" == "1" ]]; then
  status "Проверка установщика завершена: ${COMPONENTS_CSV}."
  exit 0
fi

RESUMING=0
if [[ -d "${VENV_ROOT}" || -d "${MODEL_ROOT}" || -d "${UV_CACHE}" ]]; then
  RESUMING=1
fi

mkdir -p \
  "${TOOLS_ROOT}" \
  "${PYTHON_ROOT}" \
  "${MODEL_ROOT}" \
  "${BIN_ROOT}" \
  "${UV_CACHE}" \
  "${COMPONENT_MARKERS_ROOT}"

exec > >(/usr/bin/tee -a "${LOG_FILE}") 2>&1
print -r -- "=== Запуск установки $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

if (( RESUMING == 1 )); then
  status "Продолжаю установку: готовые компоненты и недокачанные файлы будут использованы повторно."
else
  status "Начинаю установку локальных моделей."
fi

# Все установки Runtime v4 до появления выборочных компонентов были полными.
# Создаём маркеры миграции до перезаписи общего файла состояния.
if [[ -f "${RUNTIME_ROOT}/install-complete.txt" ]] && \
   grep -q '^runtime_version=4$' "${RUNTIME_ROOT}/install-complete.txt" && \
   ! grep -q '^selective_install=1$' "${RUNTIME_ROOT}/install-complete.txt"; then
  for component in gigaam whisper qwen text; do
    [[ -f "${COMPONENT_MARKERS_ROOT}/${component}.ready" ]] || \
      print -r -- "migrated_from=runtime-v4" \
        > "${COMPONENT_MARKERS_ROOT}/${component}.ready"
  done
fi

export UV_NO_MODIFY_PATH=1
export UV_NO_PROGRESS=1
export UV_HTTP_RETRIES=5
export UV_HTTP_TIMEOUT=120
export UV_CACHE_DIR="${UV_CACHE}"
export UV_PYTHON_INSTALL_DIR="${PYTHON_ROOT}"
export HF_HOME="${MODEL_ROOT}/huggingface"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export HF_HUB_DOWNLOAD_TIMEOUT=120
export HF_HUB_ETAG_TIMEOUT=30
export TORCH_HOME="${MODEL_ROOT}/torch"
export TOKENIZERS_PARALLELISM=false
export PATH="${BIN_ROOT}:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ ! -x "${UV_EXECUTABLE}" ]]; then
  INSTALLER="${TOOLS_ROOT}/uv-install.sh"
  if [[ ! -s "${INSTALLER}" ]]; then
    download_with_resume \
      "https://astral.sh/uv/${UV_VERSION}/install.sh" \
      "${INSTALLER}" \
      "Загружаю менеджер Python…"
  fi
  run_with_retries \
    "Устанавливаю менеджер Python…" \
    2 \
    /usr/bin/env "UV_UNMANAGED_INSTALL=${UV_ROOT}" /bin/sh "${INSTALLER}" || \
    fail_step "Устанавливаю менеджер Python"
fi

[[ -x "${UV_EXECUTABLE}" ]] || fail "Не удалось установить uv."

run_with_retries \
  "Устанавливаю изолированный Python 3.12…" \
  3 \
  "${UV_EXECUTABLE}" python install 3.12 --install-dir "${PYTHON_ROOT}" --no-bin || \
  fail_step "Устанавливаю изолированный Python 3.12"

if [[ ! -x "${VENV_ROOT}/bin/python3" ]]; then
  run_with_retries \
    "Создаю Python-окружение…" \
    2 \
    "${UV_EXECUTABLE}" venv \
      "${VENV_ROOT}" \
      --python 3.12 \
      --managed-python || fail_step "Создаю Python-окружение"
fi

PYTHON="${VENV_ROOT}/bin/python3"
[[ -x "${PYTHON}" ]] || fail "Не удалось создать Python-окружение."

run_with_retries \
  "Устанавливаю базовое локальное окружение…" \
  3 \
  "${UV_EXECUTABLE}" pip install \
    --python "${PYTHON}" \
    "numpy<3" \
    huggingface_hub \
    imageio-ffmpeg || fail_step "Устанавливаю базовое локальное окружение"

if ! FFMPEG_EXECUTABLE=$(
  "${PYTHON}" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'
); then
  fail_step "Настраиваю ffmpeg"
fi
ln -sf "${FFMPEG_EXECUTABLE}" "${BIN_ROOT}/ffmpeg" || \
  fail_step "Настраиваю ffmpeg"

if component_requested gigaam; then
  run_with_retries \
    "Устанавливаю движок GigaAM…" \
    3 \
    "${UV_EXECUTABLE}" pip install \
      --python "${PYTHON}" \
      torchaudio \
      "${GIGAAM_ARCHIVE}" || fail_step "Устанавливаю движок GigaAM"

  status "Проверяю зависимости GigaAM…"
  if ! "${PYTHON}" -c 'import torch, torchaudio, gigaam'; then
    fail \
      "Не удалось загрузить зависимости GigaAM (torch/torchaudio). Нажмите «Продолжить установку», чтобы восстановить окружение. Журнал: ${LOG_FILE}"
  fi

  run_with_retries \
    "Загружаю GigaAM v3 E2E RNNT…" \
    3 \
    "${PYTHON}" "${ASR_WORKER}" \
      --download \
      --engine gigaam \
      --cache "${MODEL_ROOT}" || fail_step "Загружаю GigaAM v3 E2E RNNT"
  mark_component gigaam
fi

if component_requested whisper; then
  run_with_retries \
    "Устанавливаю движок Whisper…" \
    3 \
    "${UV_EXECUTABLE}" pip install \
      --python "${PYTHON}" \
      mlx-whisper || fail_step "Устанавливаю движок Whisper"

  run_with_retries \
    "Загружаю Whisper Large V3 Turbo…" \
    3 \
    "${PYTHON}" "${ASR_WORKER}" \
      --download \
      --engine whisper \
      --cache "${MODEL_ROOT}" || fail_step "Загружаю Whisper Large V3 Turbo"
  mark_component whisper
fi

if component_requested qwen; then
  run_with_retries \
    "Устанавливаю движок Qwen3-ASR…" \
    3 \
    "${UV_EXECUTABLE}" pip install \
      --python "${PYTHON}" \
      "mlx-qwen3-asr==0.3.5" || fail_step "Устанавливаю движок Qwen3-ASR"

  run_with_retries \
    "Загружаю Qwen3-ASR 1.7B…" \
    3 \
    "${PYTHON}" "${ASR_WORKER}" \
      --download \
      --engine qwen \
      --cache "${MODEL_ROOT}" || fail_step "Загружаю Qwen3-ASR 1.7B"
  mark_component qwen
fi

if component_requested text; then
  run_with_retries \
    "Устанавливаю локальный редактор…" \
    3 \
    "${UV_EXECUTABLE}" pip install \
      --python "${PYTHON}" \
      "mlx-lm==0.31.3" || fail_step "Устанавливаю локальный редактор"

  run_with_retries \
    "Загружаю локальный редактор Qwen3-4B…" \
    3 \
    "${PYTHON}" "${TEXT_WORKER}" \
      --download \
      --cache "${MODEL_ROOT}" || fail_step "Загружаю локальный редактор Qwen3-4B"
  mark_component text
fi

write_install_marker

status "Готово — выбранные локальные модели установлены."
print -r -- "=== Установка успешно завершена $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
