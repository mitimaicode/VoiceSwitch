# Подпись и нотарификация VoiceSwitch

## Коротко

Подпись и нотарификация — разные проверки.

- **Developer ID Application** криптографически связывает сборку с
  разработчиком и позволяет macOS проверить, что приложение не меняли после
  выпуска.
- **Нотарификация** отправляет подписанную сборку автоматическому сервису
  Apple. Сервис проверяет подпись, Hardened Runtime, структуру пакета и
  отсутствие известного вредоносного кода.
- **Stapling** прикрепляет полученный билет нотарификации к приложению. После
  этого Gatekeeper может подтвердить билет даже без доступа к сети.

Для пользователя результат выглядит просто: приложение, загруженное не из
Mac App Store, открывается обычным двойным щелчком с понятным предупреждением
об идентифицированном разработчике. Обход через правый клик → «Открыть»
больше не нужен.

## Почему это особенно важно для VoiceSwitch

VoiceSwitch использует разрешение «Универсальный доступ» для глобальной
клавиши и автоматической вставки. Текущая beta подписана ad-hoc:

```zsh
codesign --force --deep --sign - VoiceSwitch.app
```

Такая подпись не содержит стабильной идентичности разработчика. После новой
сборки macOS может считать приложение новым экземпляром и перестать применять
старое разрешение TCC. Подпись Developer ID с неизменными Bundle ID и Team ID
даёт приложению стабильную designated requirement и делает обновления
предсказуемее.

Нотарификация сама по себе не выдаёт доступ к микрофону или Accessibility:
пользователь по-прежнему подтверждает эти чувствительные разрешения. Она
подтверждает происхождение и целостность сборки.

## Что потребуется

1. Участие в Apple Developer Program. На июль 2026 года стандартная цена —
   **99 USD в год** или эквивалент в местной валюте. Для некоторых
   некоммерческих, образовательных и государственных организаций доступно
   освобождение от платы.
2. Сертификат **Developer ID Application** вместе с закрытым ключом в
   Keychain.
3. Актуальные Xcode Command Line Tools.
4. Отдельный Apple ID app-specific password или App Store Connect API key для
   `notarytool`.

Официальные источники:

- [Apple Developer Program и стоимость](https://developer.apple.com/support/compare-memberships/)
- [Требования нотарификации](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Как Gatekeeper проверяет приложения](https://support.apple.com/guide/security/sec5599b66df/web)

## Подготовка проекта

### 1. Создать сертификат

В Xcode:

```text
Xcode → Settings → Accounts → Apple ID →
Manage Certificates → + → Developer ID Application
```

Сертификат и соответствующий закрытый ключ должны появиться в Keychain
Access. Проверка:

```zsh
security find-identity -v -p codesigning
```

В выводе должна быть строка вида:

```text
Developer ID Application: Имя или организация (TEAMID)
```

### 2. Включить Hardened Runtime

При ручной сборке эквивалент настройки Xcode — флаг:

```zsh
codesign --options runtime
```

Не следует переносить в release отладочное право
`com.apple.security.get-task-allow`: Apple отклоняет такие сборки.

VoiceSwitch не нужно помещать в App Sandbox для распространения по
Developer ID. Отказ от sandbox оправдан глобальной клавишей, Accessibility и
локальным runtime, но каждое добавляемое entitlement всё равно должно быть
минимально необходимым.

### 3. Подписать вложенный код, затем приложение

Сейчас исполняемый Mach-O внутри app bundle один:

```text
VoiceSwitch.app/Contents/MacOS/VoiceSwitch
```

Python-worker и shell-установщик являются ресурсами. Если позднее в bundle
появятся framework, dylib, helper app или отдельные Mach-O-инструменты, их
нужно подписывать изнутри наружу до подписи основного `.app`.

Пример финальной подписи:

```zsh
IDENTITY='Developer ID Application: Имя или организация (TEAMID)'

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  VoiceSwitch.app
```

`--deep` удобен для диагностики, но не должен заменять явную подпись каждого
вложенного исполняемого объекта.

## Проверка подписи до отправки

```zsh
codesign --verify --deep --strict --verbose=4 VoiceSwitch.app
codesign -dvv VoiceSwitch.app
codesign -d --entitlements :- VoiceSwitch.app
spctl --assess --type execute --verbose=4 VoiceSwitch.app
```

До нотарификации `spctl` ещё может отклонять приложение. Важно, чтобы
`codesign --verify` проходил, в `codesign -dvv` был secure timestamp, а среди
entitlements не было `get-task-allow`.

После подписи нельзя менять ни один файл внутри `.app`: даже правка README или
иконки нарушит подпись.

## Отправка в notary service

### 1. Сохранить учётные данные

Вариант с Apple ID:

```zsh
xcrun notarytool store-credentials VoiceSwitch-notary \
  --apple-id 'APPLE_ID' \
  --team-id 'TEAMID' \
  --password 'APP_SPECIFIC_PASSWORD'
```

Предпочтительный вариант для CI — App Store Connect API key: секреты хранятся
в GitHub Actions Secrets и не попадают в репозиторий или логи.

### 2. Создать временный архив только для отправки

```zsh
ditto -c -k --keepParent VoiceSwitch.app VoiceSwitch-notary.zip
```

### 3. Отправить и дождаться результата

```zsh
xcrun notarytool submit VoiceSwitch-notary.zip \
  --keychain-profile VoiceSwitch-notary \
  --wait
```

Ожидаемый итог — `status: Accepted`. Если ответ `Invalid`, нужно получить
журнал:

```zsh
xcrun notarytool log SUBMISSION_ID \
  --keychain-profile VoiceSwitch-notary
```

Частые причины отказа: неверный Developer ID, отсутствующий timestamp,
выключенный Hardened Runtime, изменённый после подписи файл, неподписанный
вложенный Mach-O или отладочный `get-task-allow`.

## Stapling и финальная проверка

После статуса Accepted:

```zsh
xcrun stapler staple VoiceSwitch.app
xcrun stapler validate VoiceSwitch.app
spctl --assess --type execute --verbose=4 VoiceSwitch.app
```

Затем нужно заново создать публичный ZIP уже из stapled-приложения. Для
VoiceSwitch порядок release pipeline должен быть таким:

```text
build → Developer ID sign → verify → notarize →
staple → Gatekeeper test → package ZIP → checksum → GitHub Release
```

Нотарифицировать ZIP, а затем публиковать старый ZIP нельзя: билет должен быть
прикреплён к той копии приложения, которая попадёт пользователям.

## Проверка как у нового пользователя

Перед публичным выпуском стоит проверить архив на отдельной учётной записи или
чистом Mac:

1. Скачать ZIP через браузер, чтобы файл получил quarantine attribute.
2. Распаковать и открыть приложение обычным двойным щелчком.
3. Разрешить микрофон и Accessibility.
4. Проверить `fn + Option`, запись, HUD и автоматическую вставку.
5. Установить новую подписанную версию поверх старой и убедиться, что
   Accessibility не сломался.

Локальный запуск файла, собранного на том же Mac, не полностью воспроизводит
Gatekeeper-сценарий: quarantine обычно появляется именно после загрузки из
интернета.

## Что подпись не решает

- Apple не подтверждает качество распознавания и безопасность бизнес-логики.
- Нотарификация не является ручной проверкой App Store Review.
- Пользователь всё равно должен разрешить микрофон и Accessibility.
- Developer ID не даёт автоматических обновлений. Для них нужен отдельный
  механизм, например Sparkle, и подпись update-архивов.
- Секрет сертификата и ключи нотарификации нельзя хранить в git.

## Практическое решение для проекта

Пока у проекта нет Developer ID, beta остаётся пригодной для ограниченного
теста с честным предупреждением и инструкцией правого клика. Перед более
широкой рекламой рационально:

1. оформить Apple Developer Program;
2. добавить Developer ID signing в `scripts/build_app.sh`;
3. создать отдельный `scripts/notarize_release.sh`;
4. хранить сертификат и notary credentials только в защищённых секретах;
5. выпустить первую подписанную и нотарифицированную версию как новый релиз.

