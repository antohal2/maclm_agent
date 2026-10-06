# Шаг 4.7.1 — перезапись move_file и ограничение вывода run_shell

Исходное состояние: v0.4.7 / 2d977db. MARKETING_VERSION остаётся 0.4.7.

## 1. Назначение и тождество объектов

MoveFileTool.computeRisk проверяет стандартизованный путь через lstat: существующим считается сам объект, включая каталог и висячую символическую ссылку. Пробельные края аргументов убираются так же, как в execute. Для source/destination сравниваются st_dev + st_ino, без следования по последней ссылке. Поэтому a.txt → A.txt на регистронезависимой файловой системе не повышает риск, а ссылка на source — отдельный объект и повышает.

Если назначение существует и не тождественно source: dangerous, причина «Назначение существует: файл будет перезаписан». Та же причина добавлена в каталог ru/en; существующий InterfaceLocalization.text переводит её при отображении, дополнительный switch не нужен. Периметр по-прежнему может повысить риск тождественного объекта; max базового/вычисленного уровня и fail-closed не менялись. Сессионное разрешение caution не применяется к dangerous.

Для case-only переименования тождественного объекта execute использует rename без предварительного removeItem: прежний removeItem мог удалить source через destination alias. Совпадающие и вложенные operationPath по-прежнему отвергаются. Перезапись иных объектов, checkpoint, preview и правила не менялись.

Проверены существующие файл/каталог/висячая ссылка, отсутствие назначения, существующее назначение вне зоны, ссылка на source, аргумент с пробельными краями, регистронезависимое переименование с сохранением содержимого, отказ сессионной памяти для dangerous. Тест case-only реально выполнен на текущей файловой системе, не пропущен.

## 2. Ограничение вывода и память

ShellOutputLimits: headBytes=8192, tailBytes=8192, hardBytes=33554432 на каждый поток. Внедряется через RunShellTool(limits:); настроек приложения нет. ShellOutputBuffer хранит начало и кольцевой хвост, счётчик UInt64 с насыщением; отбрасываемая середина не накапливается. При потоковом чтении работа одного прохода ограничена, сохраняются проверки таймаута/отмены и drain при cleanup. Буферы двух потоков вместе сохраняют не более 32768 байт полезного вывода, независимо от прочитанного объёма.

При превышении hardBytes любого потока останавливается существующая POSIX-группа, SIGTERM / grace / SIGKILL; результат isError=true, optional outputLimitExceeded=true, аудит failure с errorDescription «Shell command output limit exceeded». В остальных случаях новое поле отсутствует. Старое усечение audit resultSummary не изменено. Некорректный UTF-8 при усечении декодируется с заменой; корректные пограничные символы сохраняются целиком или отбрасываются с учётом в N. Неусечённый результат сохраняет прежний формат, включая старую обработку не-UTF-8.

Измерение памяти: отдельные оптимизированные Swift-executable из исходного ShellCommandRunner на HEAD и нового runner, одинаковый `/usr/bin/yes`, timeoutSeconds=2; `/usr/bin/time -l`. После изменения для сравнения отключён только hardBytes (UInt64.max), чтобы непрерывное чтение длилось до таймаута. Это RSS изолированного runner, не всего SwiftUI-приложения; фактические объёмы вывода могут различаться из-за планирования.

| Показатель | До | После |
|---|---:|---:|
| Maximum resident set size, байт | 261898240 | 7061504 |
| Размер JSON результата, байт | 43415605 | 24760 |
| Wall time, секунды | 4.10 | 2.25 |

Артефакты измерения: /tmp/maclm471-memory/{before,after}.swift и {before,after}.txt. Процессам заданы разные уникальные в рамках проверки argv-маркеры maclm471-memory-before/after; после возврата процессов с этими именами нет. В XCTest маркеры UUID и defer-очистка, проверка отсутствия процессов после каждого сценария.

Отдельные тесты yes: таймаут 1 с с отключённым hardBytes, жёсткий предел 2 МиБ для stdout и stderr; возврат <6 с, ограниченный JSON, правильные timedOut/outputLimitExceeded и audit errorDescription, оставшихся процессов нет. Для конечного вывода проверены 100 КиБ каждого потока независимо, 86016 пропущенных байт, exitCode=0, отсутствие таймаута, lifecycleNote и resultSummary. Дополнительно проверены exitCode=7, маленький вывод с прежним набором JSON-полей, UTF-8 на границах (буфер и реальная команда), некорректные байты.

## 3. Дословный результат, трейс и контекст модели

Реальный вызов `printf ABCDEFGHIJKLMNOPQRSTUVWX` с тестовыми headBytes=8, tailBytes=8 вернул JSON (порядок ключей не значим):

```json
{"stderr":"","exitCode":0,"timedOut":false,"lifecycleNote":"stdout: Output truncated: kept first 8 and last 8 bytes of 24.","stdout":"ABCDEFGH\n[... 8 bytes omitted ...]\nQRSTUVWX"}
```

AgentLoop передаёт именно result.content как content сообщения role=tool следующему запросу к модели. В существующей ToolCallCard отдельно показываются exitCode/timedOut, затем lifecycleNote и stdout/stderr. Для этого примера видимый вывод:

```text
exitCode: 0 · timedOut: false
stdout: Output truncated: kept first 8 and last 8 bytes of 24.
stdout:
ABCDEFGH
[... 8 bytes omitted ...]
QRSTUVWX
stderr:
```

Формирование JSON и displayContent проверено изолированным runner; отображение карточки описано по действующему коду ToolCallCard, без изменения UI. Отдельный визуальный прогон этих сценариев не выполнялся.

## 4. Проверки и ручной прогон

`make test`: 235 тестов, 0 failures, 1 существующий skip — testMigrationOnLocalRealV042Snapshot (локальный реальный snapshot исключён из Git). Тесты шага выполнены без skip, временные каталоги удалены. Сборка приложения выполнена как часть make test. Приложение открыто через open; подтверждён процесс /private/tmp/maclm-agent-DerivedData/Build/Products/Debug/maclm-agent.app/Contents/MacOS/maclm-agent (PID 38329). SwiftLint для изменённых файлов инструментов и ShellProcessTests, git diff --check — без замечаний. SPEC 5.2 и ROADMAP обновлены; схема SwiftData, AgentLoop, SessionPermissions и MARKETING_VERSION не изменены.

В приложении проверить:

1. run_shell `yes`, timeoutSeconds=5: ограниченный вывод, ошибка и остановка группы. По умолчанию на быстрой машине может раньше сработать предел 32 МиБ — тогда outputLimitExceeded=true, timedOut=false.
2. `cat` файла около 100 КиБ: начало/хвост, корректный N, lifecycleNote в трейсе и аудите. При файле >32 МиБ ожидается принудительная остановка по лимиту.
3. move_file поверх существующего файла внутри allowed_dirs: dangerous, причина, красная строка перезаписи, без чекбокса памяти; checkpoint/откат как прежде. Проверить также при ранее запомненном caution.
4. a.txt → A.txt на регистронезависимой ФС: caution внутри зоны, файл и содержимое сохранены.

Коммит: `fix(tools): treat move overwrite as dangerous and cap run_shell output`. Тег: v0.4.7.1. Публикация в remote не выполняется: задание требует локальный коммит/тег и запрещает сетевые обращения.
