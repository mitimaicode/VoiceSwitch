#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STT_ROOT="${VOICESWITCH_STT_ROOT:-${HOME}/.local/share/mitim-stt}"
VIDEO_ROOT="${VOICESWITCH_VIDEO_ROOT:-${HOME}/.local/share/mitim-video}"
CACHE_ROOT="${VOICESWITCH_CACHE_ROOT:-${HOME}/.cache/mitim-stt}"
UNIT_ROOT="${HOME}/.config/systemd/user"
BIN_ROOT="${HOME}/.local/bin"
PYTHON="${VOICESWITCH_PYTHON:-python3.12}"
INSTALL_VIDEO=1
INSTALL_OPENCLAW=0
START_SERVICE=1

usage() {
  cat <<'EOF'
Usage: ./install.sh [--core-only] [--with-openclaw] [--no-start]

  --core-only  Install resident GigaAM/Whisper STT without the long-video tools.
  --with-openclaw  Also install the optional OpenClaw TaskFlow plugin.
  --no-start   Install files but do not enable or start the user systemd service.

Environment overrides:
  VOICESWITCH_PYTHON, VOICESWITCH_STT_ROOT, VOICESWITCH_VIDEO_ROOT,
  VOICESWITCH_CACHE_ROOT, VOICESWITCH_SETUP_VALIDATE_ONLY=1
EOF
}

while (($#)); do
  case "$1" in
    --core-only) INSTALL_VIDEO=0 ;;
    --with-openclaw) INSTALL_OPENCLAW=1 ;;
    --no-start) START_SERVICE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

require_command "$PYTHON"
require_command systemctl
if ((INSTALL_VIDEO)); then
  if command -v ffprobe >/dev/null 2>&1; then
    FFPROBE_SOURCE="$(command -v ffprobe)"
  elif [[ -x "$STT_ROOT/bin/ffprobe" ]]; then
    FFPROBE_SOURCE="$STT_ROOT/bin/ffprobe"
  else
    echo "Missing ffprobe. Install the ffmpeg package before the full video setup." >&2
    exit 1
  fi
fi

if ((INSTALL_OPENCLAW)); then
  if ((!INSTALL_VIDEO)); then
    echo "--with-openclaw cannot be combined with --core-only" >&2
    exit 2
  fi
  require_command node
  require_command npm
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ;;
  *) echo "VoiceSwitch Server supports Linux x86_64 with an NVIDIA GPU." >&2; exit 1 ;;
esac

if [[ "${VOICESWITCH_SETUP_VALIDATE_ONLY:-0}" == "1" ]]; then
  "$PYTHON" -m py_compile \
    "$SOURCE_ROOT/stt/server.py" \
    "$SOURCE_ROOT/stt/transcribe.py" \
    "$SOURCE_ROOT/video/video_pipeline.py" \
    "$SOURCE_ROOT/video/transcribe_mitim_stt.py" \
    "$SOURCE_ROOT/video/align_qwen.py" \
    "$SOURCE_ROOT/video/diarize_pyannote.py" \
    "$SOURCE_ROOT/video/enrich_ollama.py" \
    "$SOURCE_ROOT/video/telegram_publication.py"
  echo "VoiceSwitch Server installer validation completed."
  exit 0
fi

mkdir -p "$STT_ROOT" "$STT_ROOT/work" "$STT_ROOT/bin" "$CACHE_ROOT" "$UNIT_ROOT" "$BIN_ROOT"
"$PYTHON" -m venv "$STT_ROOT/venv"
"$STT_ROOT/venv/bin/python" -m pip install --upgrade pip
"$STT_ROOT/venv/bin/python" -m pip install -r "$SOURCE_ROOT/requirements-stt.txt"
install -m 0644 "$SOURCE_ROOT/stt/server.py" "$STT_ROOT/server.py"
install -m 0755 "$SOURCE_ROOT/stt/transcribe.py" "$STT_ROOT/transcribe.py"
FFMPEG_SOURCE="$("$STT_ROOT/venv/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
ln -sfn "$FFMPEG_SOURCE" "$STT_ROOT/bin/ffmpeg"

if ((INSTALL_VIDEO)); then
  if [[ "$FFPROBE_SOURCE" != "$STT_ROOT/bin/ffprobe" ]]; then
    ln -sfn "$FFPROBE_SOURCE" "$STT_ROOT/bin/ffprobe"
  fi
fi

STT_ROOT="$STT_ROOT" CACHE_ROOT="$CACHE_ROOT" SOURCE_ROOT="$SOURCE_ROOT" UNIT_ROOT="$UNIT_ROOT" \
  "$PYTHON" - <<'PY'
import os
from pathlib import Path

template = Path(os.environ["SOURCE_ROOT"]) / "systemd" / "mitim-stt.service.in"
content = template.read_text(encoding="utf-8")
content = content.replace("@STT_ROOT@", os.environ["STT_ROOT"])
content = content.replace("@CACHE_ROOT@", os.environ["CACHE_ROOT"])
target = Path(os.environ["UNIT_ROOT"]) / "mitim-stt.service"
target.write_text(content, encoding="utf-8")
PY

if ((INSTALL_VIDEO)); then
  mkdir -p "$VIDEO_ROOT/pipeline"
  "$PYTHON" -m venv "$VIDEO_ROOT/venv"
  "$VIDEO_ROOT/venv/bin/python" -m pip install --upgrade pip
  "$VIDEO_ROOT/venv/bin/python" -m pip install -r "$SOURCE_ROOT/requirements-video.txt"
  install -m 0644 "$SOURCE_ROOT"/video/*.py "$VIDEO_ROOT/pipeline/"
  cat > "$BIN_ROOT/voiceswitch-video" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$STT_ROOT/bin:$VIDEO_ROOT/venv/bin:\${PATH}"
ALIGN_COMMAND="$VIDEO_ROOT/venv/bin/python $VIDEO_ROOT/pipeline/align_qwen.py --audio {audio} --transcript {transcript} --output {output}"
DIARIZE_COMMAND="$VIDEO_ROOT/venv/bin/python $VIDEO_ROOT/pipeline/diarize_pyannote.py --audio {audio} --transcript {transcript} --output {output}"
exec "$VIDEO_ROOT/venv/bin/python" "$VIDEO_ROOT/pipeline/video_pipeline.py" \
  --align-command "\$ALIGN_COMMAND" \
  --diarize-command "\$DIARIZE_COMMAND" \
  --ffmpeg-path "$STT_ROOT/bin/ffmpeg" \
  --ffprobe-path "$STT_ROOT/bin/ffprobe" \
  "\$@"
EOF
  chmod 0755 "$BIN_ROOT/voiceswitch-video"
fi

if ((INSTALL_OPENCLAW)); then
  PLUGIN_ROOT="${HOME}/.openclaw/workspace/plugins/video-transcription-taskflow"
  mkdir -p "$PLUGIN_ROOT"
  cp -R "$SOURCE_ROOT/openclaw-plugin/." "$PLUGIN_ROOT/"
  npm --prefix "$PLUGIN_ROOT" install --omit=dev --omit=peer --ignore-scripts
fi

systemctl --user daemon-reload
if ((START_SERVICE)); then
  systemctl --user enable --now mitim-stt.service
fi

echo "VoiceSwitch Server installed."
echo "Health: http://127.0.0.1:18790/health"
if ((INSTALL_VIDEO)); then
  echo "Video CLI: $BIN_ROOT/voiceswitch-video"
fi
if ((INSTALL_OPENCLAW)); then
  echo "OpenClaw plugin: $PLUGIN_ROOT"
fi
