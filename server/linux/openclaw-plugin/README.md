# Video Transcription TaskFlow restart survival

Плагин устанавливается в
`~/.openclaw/workspace/plugins/video-transcription-taskflow`.

Версия 0.1.6 запускает тяжёлый локальный worker в отдельном user-systemd scope,
привязанном к `flow_id`. Scope получает пониженный CPU/IO weight, `nice=10`,
`CPUQuota=300%`, `MemoryHigh=3G`, `MemoryMax=4G` и `TasksMax=256`.

`video_transcription_start` требует стабильный `idempotencyKey`, а старт
резервируется на диске. Повтор с тем же ключом возвращает ту же работу, а
конфликтующий payload отклоняется. Каждая работа получает отдельный каталог
`jobs/<job_id>`; состояние соседней или более новой транскрибации больше не
может быть принято за состояние текущей.

Инструмент `video_transcription_resume` продолжает тот же оборванный Flow,
включая `failed` после смерти старого gateway-child процесса, без создания
дубликата. `cancelled` и `succeeded` Flow не возобновляются.

Успешный терминальный статус дополнительно возвращает `ok=true`. Это не даёт
Codex-провайдеру ошибочно трактовать штатный `status=succeeded` как tool error и
запускать лишние повторные проверки уже завершённой задачи.

Проверки:

```text
node --check index.js
node --test index.test.js source-validation.test.js tool-result.test.js worker-scope.test.js
```
