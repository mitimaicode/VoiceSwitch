# VoiceSwitch

<p align="center">
  <img src="assets/banner.svg" alt="VoiceSwitch — локальная диктовка для macOS" width="100%">
</p>

> Локальная диктовка для macOS с быстрым переключением между GigaAM и Whisper.

[![CI](https://github.com/mitimaicode/VoiceSwitch/actions/workflows/ci.yml/badge.svg)](https://github.com/mitimaicode/VoiceSwitch/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/mitimaicode/VoiceSwitch?include_prereleases)](https://github.com/mitimaicode/VoiceSwitch/releases)
[![Downloads](https://img.shields.io/github/downloads/mitimaicode/VoiceSwitch/total)](https://github.com/mitimaicode/VoiceSwitch/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

VoiceSwitch записывает речь по глобальной горячей клавише, распознаёт её
полностью локально и вставляет текст в активное приложение.

- **GigaAM v3 E2E RNNT** — основной режим для русской речи;
- **Whisper Large V3 Turbo (MLX)** — для смешанной русско-английской речи;
- `fn + ⌥ Option` — начать или остановить запись;
- HUD показывает запись, длительную расшифровку и результат;
- аудио и текст не отправляются во внешние API;
- журнал сравнения помогает выбрать модель под собственную речь.

> [!IMPORTANT]
> Это beta-релиз для Mac с Apple Silicon. Приложение пока подписано ad-hoc и
> не нотарифицировано Apple.

## Системные требования

- Mac с Apple Silicon (`M1` или новее);
- macOS 14 Sonoma или новее;
- рекомендуется 16 ГБ оперативной памяти;
- около 4–5 ГБ свободного места для Python, зависимостей и двух моделей;
- интернет только во время первоначальной установки моделей.

## Установка

1. Откройте раздел [Releases](https://github.com/mitimaicode/VoiceSwitch/releases)
   и скачайте архив `VoiceSwitch-…-macos-arm64.zip`.
2. Распакуйте архив и перенесите `VoiceSwitch.app` в «Программы».
3. При первом запуске щёлкните приложение правой кнопкой и выберите
   **Открыть**. Подтвердите запуск beta-версии.
4. Нажмите значок VoiceSwitch в строке меню и выберите
   **Установить модели**. Загрузка занимает несколько гигабайт.
5. Разрешите доступ к микрофону. Для глобальной клавиши и автоматической
   вставки включите VoiceSwitch в
   **Системные настройки → Конфиденциальность и безопасность →
   Универсальный доступ**.

Подробности и решение типовых проблем приведены в [INSTALL.md](INSTALL.md).

## Использование

1. Выберите GigaAM или Whisper в меню VoiceSwitch.
2. Нажмите `fn + ⌥ Option`, чтобы начать запись.
3. Отпустите клавиши и нажмите сочетание ещё раз, чтобы остановить запись.
4. Дождитесь завершения расшифровки. Текст будет вставлен в ранее активное
   окно или останется в буфере обмена, если универсальный доступ отключён.

Во время записи отображается красный пульсирующий индикатор с таймером.
Во время распознавания он сменяется индикатором модели и времени ожидания.
HUD не перехватывает клики.

Модель загружается лениво. При переключении предыдущая модель выгружается,
чтобы не занимать память.

## Где хранятся данные

Runtime и веса моделей:

```text
~/Library/Application Support/VoiceSwitch/Runtime
```

Журнал сравнительных тестов:

```text
~/Library/Application Support/VoiceSwitch/comparison.jsonl
```

В журнале сохраняются модель, длительность записи, время распознавания, RTF,
определённый язык, результат и ваша оценка. Временные аудиофайлы удаляются
после обработки.

## Как выбрать модель

Проверьте обе модели на одинаковом наборе из 10–20 фраз:

- обычная русская диктовка;
- имена, названия продуктов и профессиональные термины;
- числа, даты и адреса;
- переключения русского и английского внутри одной фразы;
- короткие и длинные голосовые сообщения.

На MacBook Air M3 официальный 11-секундный русский WAV-пример обрабатывался
после загрузки модели примерно за 0,4–0,6 секунды в GigaAM и 3,8–4,1 секунды
в Whisper. Это проверка работоспособности, а не универсальный тест качества.

## Сборка из исходников

```zsh
git clone https://github.com/mitimaicode/VoiceSwitch.git
cd VoiceSwitch
chmod +x scripts/*.sh Resources/install_runtime.sh
./scripts/build_app.sh
```

Установка обеих моделей для разработки:

```zsh
./scripts/setup_models.sh
```

Создание компактного release-архива без весов моделей:

```zsh
./scripts/package_release.sh 0.1.0-beta
```

## Обратная связь

- воспроизводимые ошибки — [Issues](https://github.com/mitimaicode/VoiceSwitch/issues);
- вопросы, идеи и результаты сравнения моделей —
  [Discussions](https://github.com/mitimaicode/VoiceSwitch/discussions);
- правила участия — [CONTRIBUTING.md](CONTRIBUTING.md);
- сообщения об уязвимостях — [SECURITY.md](SECURITY.md).

История публичных показателей проекта сохраняется в
[`metrics/github-stats.json`](metrics/github-stats.json). GitHub также
показывает владельцу просмотры, источники переходов и клоны за последние
14 дней в разделе **Insights → Traffic**.

## Зависимости и лицензии

Код VoiceSwitch распространяется по лицензии MIT. Модели и движки
загружаются отдельно из исходных проектов:

- [GigaAM](https://github.com/salute-developers/GigaAM) — MIT;
- [OpenAI Whisper](https://github.com/openai/whisper) — MIT;
- [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper);
- [uv](https://github.com/astral-sh/uv) — Apache-2.0 / MIT.

VoiceSwitch не связан с авторами перечисленных проектов.

---

<details>
<summary>English summary</summary>

VoiceSwitch is a local macOS dictation menu-bar app for Apple Silicon. It
switches between GigaAM for Russian speech and Whisper Large V3 Turbo (MLX)
for mixed Russian/English speech. Press `fn + Option` to start or stop
recording. Audio and transcripts stay on the Mac. See [INSTALL.md](INSTALL.md)
for installation details and use GitHub Issues or Discussions for feedback.

</details>
