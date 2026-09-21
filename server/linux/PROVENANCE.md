# Provenance: installed Linux server snapshot

Снимок снят 21 сентября 2026 года с фактически установленного серверного
контура. Модели, cache, пользовательские медиа, результаты, токены и журналы в
релиз не входят.

## Resident STT

| Файл | SHA-256 установленного источника |
|---|---|
| `stt/server.py` | `2a7ffdde45929a7f3151620c9795d6a990e88e442d78068ccdaddfee734c3c3e` |
| `stt/transcribe.py` | `8340c4452a89c003c18453d9792ca8f61a27af3247af863bd2518ffdba10ce92` |
| systemd unit | `89d98f730650b7927132520527ce191c783481f4f83257fb33ede8ef153b9436` |

В публичном `transcribe.py` изменён только комментарий с абсолютным домашним
путём. Unit представлен переносимым шаблоном с теми же параметрами запуска.

## Long-video pipeline

| Файл | SHA-256 установленного источника |
|---|---|
| `video/video_pipeline.py` | `0c44b359f4453288048575bd442fc49c497113bfca03fb888629df0679893443` |
| `video/align_qwen.py` | `4390900317e7f98c929497ac075a7af01fd72b1d6f506ac9211bef86f3155f49` |
| `video/diarize_pyannote.py` | `c6af00ab0d74051e94ed37af21122118c52ed73cfa02055bb591bc2f75aa5977` |
| `video/enrich_ollama.py` | `8cca0137d2411bfdc3505768f7ad89bb347fb2a1a45e416644af8ee84fa3d139` |

В Telegram outbox изменено только имя подключения по умолчанию. Реальный chat
ID из внутренних примеров заменён фиктивным. OpenClaw plugin `0.1.6` сохраняет
логику установленной версии, но абсолютные пути заменены путями от домашнего
каталога и переменными окружения.

## Подтверждение работы

На момент снимка `mitim-stt.service` был `active (running)` более трёх недель.
Журнал содержал успешные ответы `/transcribe` за 21 сентября 2026 года.
HTTP endpoint намеренно loopback-only.
