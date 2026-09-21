# VoiceSwitch Server Edition for Linux

Этот пакет воспроизводит локальный контур распознавания, установленный на
сервере владельца VoiceSwitch. Это отдельная Linux-версия, а не запуск
SwiftUI-приложения или DMG на сервере.

## Что входит

- resident HTTP STT на `127.0.0.1:18790`;
- GigaAM v3 E2E RNNT на CUDA как основной русский движок;
- Whisper Turbo как явный режим и fallback;
- локальная нормализация аудио через ffmpeg;
- длинные аудио и видео минутными блоками с checkpoint/resume;
- TXT, Markdown, JSON, SRT и VTT;
- профили `quick`, `standard`, `interview`, `multilingual` и `deep`;
- Qwen3 ForcedAligner, pyannote diarization и визуальный enrichment через
  локальный Ollama `qwen3-vl:8b`;
- необязательный OpenClaw TaskFlow plugin `0.1.6` с start/resume/status/cancel.

Исходные медиа, расшифровки и запросы не отправляются во внешние ASR API.
Первоначальная установка загружает Python-пакеты и модели из их официальных
репозиториев. YouTube-режим обращается к YouTube через `yt-dlp`.

## Требования

- Linux x86_64;
- NVIDIA GPU и рабочий драйвер;
- Python 3.12 и user systemd;
- `ffprobe` из системного пакета ffmpeg;
- свободное место для двух Python-окружений и моделей;
- для diarization — принятие условий модели pyannote и локальная авторизация
  Hugging Face (`HF_TOKEN` или `hf auth login`);
- для визуального enrichment — локальный Ollama и модель `qwen3-vl:8b`.

Сервис привязан только к loopback. Не публикуйте порт `18790` наружу: endpoint
принимает абсолютный путь к локальному файлу и рассчитан на доверенные процессы
того же пользователя.

## Установка полного серверного контура

Распакуйте архив `VoiceSwitch-Server-…-linux-x86_64.tar.gz`, перейдите в его
каталог и выполните:

```bash
./install.sh
```

Установщик не требует root и размещает данные в:

- `~/.local/share/mitim-stt` — resident STT;
- `~/.local/share/mitim-video` — длинные видео, alignment и diarization;
- `~/.config/systemd/user/mitim-stt.service` — user service;
- `~/.local/bin/voiceswitch-video` — CLI длинного конвейера.

Только короткая речь без видеоконвейера:

```bash
./install.sh --core-only
```

Добавить установленный на исходном сервере OpenClaw TaskFlow plugin:

```bash
./install.sh --with-openclaw
```

## Проверка

```bash
python3 healthcheck.py
```

Короткое аудио:

```bash
~/.local/share/mitim-stt/transcribe.py /absolute/path/to/audio.ogg
```

Длинное локальное видео:

```bash
~/.local/bin/voiceswitch-video /absolute/path/to/video.mp4 --profile standard
```

YouTube:

```bash
~/.local/bin/voiceswitch-video 'https://youtu.be/VIDEO_ID' --profile standard
```

Результаты по умолчанию сохраняются в
`~/.local/share/mitim-video/pipeline/knowledge/videos/`.

## Закреплённые версии

Resident STT повторяет установленное окружение:

- `torch 2.6.0+cu124`;
- `torchaudio 2.6.0+cu124`;
- `gigaam 0.2.0`;
- `openai-whisper 20250625`;
- `imageio-ffmpeg 0.6.0`.

Видео-окружение:

- `torch 2.8.0+cu128`;
- `torchaudio 2.8.0+cu128`;
- `qwen-asr 0.0.6`;
- `pyannote.audio 4.0.7`;
- `yt-dlp 2026.8.19`.

Полные доказательства происхождения файлов перечислены в `PROVENANCE.md`.
