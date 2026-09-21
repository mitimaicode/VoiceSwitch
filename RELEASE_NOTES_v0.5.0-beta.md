# VoiceSwitch v0.5.0-beta — Linux Server Edition

Этот релиз публикует воспроизводимый пакет той версии локального распознавания
речи и видео, которая фактически работает на Linux-сервере владельца проекта.
macOS-приложение остаётся в релизе, но главное изменение v0.5 — отдельный архив
`VoiceSwitch-Server-0.5.0-beta-linux-x86_64.tar.gz`.

## Linux Server Edition

- resident GigaAM v3 E2E RNNT на CUDA;
- Whisper Turbo как явный режим и fallback;
- loopback HTTP endpoint `127.0.0.1:18790`;
- user-systemd service без root;
- длинные локальные файлы, Telegram media и YouTube;
- минутные блоки, checkpoint и resume;
- TXT, Markdown, JSON, SRT и VTT;
- Qwen3 ForcedAligner;
- pyannote diarization;
- локальный визуальный enrichment через Ollama `qwen3-vl:8b`;
- OpenClaw TaskFlow plugin `0.1.6` с start/resume/status/cancel.

Установленные серверные версии PyTorch, GigaAM, Whisper, Qwen ASR и pyannote
закреплены в requirements. В `PROVENANCE.md` опубликованы SHA-256 исходных
файлов серверного снимка и перечислены санитарные изменения перед публикацией.

## Установка Linux

1. Скачайте `VoiceSwitch-Server-0.5.0-beta-linux-x86_64.tar.gz` и файл
   `.sha256`.
2. Проверьте SHA-256 и распакуйте архив.
3. Внутри каталога запустите `./install.sh`.

Требуются Linux x86_64, NVIDIA GPU, Python 3.12, user systemd и `ffprobe`.
Модели и зависимости загружаются локально при установке и первом запуске.

## Безопасность и ограничения

- HTTP endpoint доступен только с localhost и не должен публиковаться наружу.
- В архив не входят модели, cache, медиа, расшифровки, токены, cookies,
  Telegram chat ID или серверные журналы.
- Diarization требует отдельно принять условия модели pyannote и выполнить
  локальную авторизацию Hugging Face.
- Визуальный enrichment требует отдельно установленный Ollama.

Подробная инструкция находится в `server/linux/README.md` внутри исходников и
релизного архива.
