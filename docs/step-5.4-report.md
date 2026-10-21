# Step 5.4 — Create a skill from this session

Дата: 2026-10-21. Исходная версия: `v0.5.3` (`9a52665`). Результат: `v0.5.4`.
SPEC, раздел 15 (Rev 5), прочитан до реализации. Конфликтов с заданием нет.

## Реализация

- `create_skill_draft(name, description, instructions, files[])` постоянно
  зарегистрирован в общем ToolRegistry. Набор инструментов не зависит от запроса
  черновика. Настройки доступности tools для конкретной модели работают как прежде.
- Меню сессии «Создать навык из этой сессии» и `/skill new` вызывают один метод
  SessionRunner. Он устанавливает одноразовый запрос только в текущем чате
  и отправляет точную встроенную английскую инструкцию как сообщение пользователя.
  Команда работает также через Quick Chat. Запрос не сохраняется между генерациями:
  первый вызов, дошедший до карточки, расходует его; ошибка валидации оставляет
  возможность исправления; завершение, ошибка провайдера и отмена очищают запрос.
- Без запроса вызов возвращает `not requested` до разбора и проверки аргументов,
  без карточки и файловых записей. Работает и для вызова без SkillStore/session.
  Записывается `skill.draftUnrequested`; для него имя пустое, хэш вычислен от
  сырых аргументов, число предупреждений 0 — содержимое не валидируется.
- Валидатор использует SkillParser, лимиты SkillScanner и общий
  SkillFileIO.validateModelPath. Frontmatter собирается приложением:
  description — JSON-quoted scalar, поддерживаемый строгим парсером, с защитой
  от инъекции полей через переводы строк. Текст instructions остаётся неизменным,
  включая CRLF. Лимиты: description 1–1024 символа, весь SKILL.md ≤ 16 КиБ,
  ≤ 10 вспомогательных файлов по ≤ 32 КиБ; UTF-8 без бинарных управляющих
  символов (CR/LF/tab разрешены). Проверяются скрытые/небезопасные пути,
  дубликаты, case/Unicode aliases, SKILL.md в files и конфликты файл/каталог.
  Ошибка возвращается модели до карточки, на английском независимо от языка UI.
- Карточка использует существующие ConfirmationRequest/ConfirmationCoordinator
  и Approval flow. Полный сырой SKILL.md показан сразу; у каждого вспомогательного
  файла видны путь, размер и доступный до Approve сворачиваемый полный текст.
  Содержимое отображается verbatim, без выполнения Markdown или скриптов.
- Предупреждения привязаны к конкретному файлу: AWS/OpenAI/GitHub/Slack keys,
  private key header, JWT, присваивания password/passwd/secret/token/api-key
  без учёта регистра и личные пути `/Users/<name>/`. Предупреждения не запрещают
  Approve. warningCount — количество сработавших типов предупреждений по файлам.
- Базовый риск `caution`. Узкий флаг ToolApprovalPolicy.neverRemember исключает
  этот инструмент из чтения и записи session memory и убирает checkbox карточки.
  PetApprovalPolicy, AgentLoop, SessionRunner и пузырь исключают его из pet Approve:
  доступно «Открыть в чате». Обычные caution/dangerous инструменты сохраняют
  прежние правила и память решений.
- Проверка имени учитывает папки и записи SkillRecord любого источника;
  предлагает до трёх свободных имён. Повторная проверка выполняется при Approve;
  окончательную гонку закрывает `renameatx_np(..., RENAME_EXCL)`.
- Пишет только код SkillStore: приватная папка
  `~/Library/Application Support/local.maclm-agent/skill-staging/<UUID>/`,
  вне skills/ и на том же томе. Каталоги открываются существующим no-follow
  descriptor walker; файлы создаются с O_EXCL/O_NOFOLLOW, правами 0600,
  каталоги — 0700; файлы и каталоги fsync-ятся. Промежуточный сбой/отмена
  очищает staging. Rename никогда не заменяет существующую папку. После записи
  выполняется rescan и сохраняются метаданные disabled, origin=model-drafted.
  При ошибке сохранения метаданных папка удаляется. Скрипты не запускаются.
- При старте единственный SkillStore из ApplicationRuntime очищает прерванные
  staging-папки до сканирования. Очистка не следует симлинкам. Обязательный
  block данных приложения уже покрывает staging; отдельные ослабляющие правила
  не добавлялись. Сканер skills/ не видит staging даже в середине записи.
- Settings → Skills показывает «Создан моделью» до первого включения.
  Optional SkillRecord.firstEnabledAt сохраняет факт первого ручного enable;
  origin остаётся model-drafted и после включения/выключения. Схема расширена
  аддитивно, schema snapshot обновлён. Миграционный тест на исходном SQLite
  fixture v0.5.2 проверяет nil для нового поля и его сохранение после reopen.
- Аудит: skill.draftUnrequested, skill.draftShown, skill.draftApproved,
  skill.draftRejected с именем, хэшем, conversationID, warningCount. Подтверждение
  и сохранение метаданных проходят в существующем SwiftData store;
  формат AuditEntry/JSONL не менялся. Отмена открытой карточки также журналируется.
- Новые строки локализованы ru/en; SPEC 15.9 дополнен правилами запроса,
  полного содержимого, личных путей и staging. Обновлены список аудита 15.11,
  CHANGELOG и версия project.yml (через make generate).
- Новых зависимостей, внешних сервисов или сетевых обращений для функции нет.
  Общие runtime-зависимости не дублировались. SessionSkillDraft получает
  существующий SkillStore раннера; дополнительные data container/settings
  в production не создаются. Новых force unwrap нет, Swift 6 concurrency чистая.

## Автоматические проверки

Среда: Xcode 27.1, macOS arm64, Swift 6 strict concurrency.

- `make generate`
- `make build`
- `make test`
- `make lint`
- `git diff --check`

Итог: **423 теста: 419 прошли, 4 пропущены, 0 ошибок**.
Добавлено **30 тестов**: SkillDraftValidationTests (8), SkillDraftStoreTests (7),
SkillDraftFlowTests (12), SkillDraftPolicyTests (3).

Покрыты: gate без запроса до валидации и между чатами; ровно одна карточка;
исправление после ошибки; очистка запроса при завершении/отмене; неизменный
полный текст файлов; CRLF; размеры и типы текста; опасные пути/дубликаты;
конфликты имён и предложения; Reject без файлов; создание disabled и origin;
первое включение и постоянное исчезновение badge; отсутствие enable-инструмента;
невидимость staging сканеру; сбой после записи двух файлов; гонка непосредственно
перед rename без перезаписи; symlink staging; startup cleanup без перехода
по симлинкам; повторный Approve с remember=true снова требует карточки;
исключение питомца; неизменная память других инструментов; все шаблоны
предупреждений в правильном файле, включая description; обязательный блок
staging для всех обычных файловых инструментов; команда и обработчик меню;
события аудита; полнота локализации и миграции.

Полный список пропусков — прежний, новых нет:

| Тест | Причина |
| --- | --- |
| CheckpointMigrationTests.testRealV045StoreCopyMigrationPreservesRowsAndDefaults | Нет /tmp/maclm-46-migration-source/default.store; Explicit v0.4.5 real-store copy not present. |
| SessionContextMigrationTests.testRealV046StoreCopyMigrationPreservesRowsAndDefaults | Нет /tmp/maclm-47-migration-source/default.store; Explicit v0.4.6 real-store copy not present. |
| SessionLoadTests.testMigrationOnLocalRealV042Snapshot | Нет build/step43-validation/before.store; Local real snapshot is intentionally excluded from Git. |
| WorkspaceMigrationTests.testMigrationOfExplicitRealStoreCopy | Нет /tmp/maclm-44-migration-source/default.store; Explicit migration fixture not present. |

Сборка и тесты проходят. Новых compiler/concurrency warnings нет. Исходные
предупреждения: ToolCallCard.swift:46 (deprecated appendInterpolation),
ClipboardActionRunnerTests.swift (try/await на строках 51, 71, 96, 117, 139,
165, 236), AppIntents metadata extraction skipped. При инкрементальной сборке
неизменённые файлы могут не компилироваться повторно и не выводить эти warnings.

SwiftFormat проходит. make lint возвращает ненулевой код только из-за двух
исходных SwiftLint line_length: PetSettingsView.swift:13 и PetLibraryTests.swift:36.
Новых замечаний SwiftLint нет. git diff --check проходит.
Runtime-сообщения macOS linkd, недоступного Ollama и намеренно повреждённых
миграционных/image fixtures остаются прежними и не вызывают ошибок тестов.

До работы каталог Localizable.xcstrings уже был переформатирован локально
и содержал новую запись «Пересканировать» без переводов. Для прохождения
проверки полноты добавлены ru/en. Исходное форматирование сохранено в рабочем
файле; в коммит входит семантически эквивалентное добавление семи переводов,
без постороннего большого форматирующего diff. После коммита исходная разница
форматирования остаётся незакоммиченной.

Логи: /tmp/maclm-step54-generate-final.log, /tmp/maclm-step54-build-final.log,
/tmp/maclm-step54-test-final.log, /tmp/maclm-step54-lint-final.log.
Точный xcresult указан в конце test-final.log.

## Проверка с реальной локальной моделью

Дополнительно выполнен отдельный live integration run через штатные
LMStudioProvider → SessionRunner → AgentLoop → confirmation → SkillStore.
Он использовал только временное in-memory хранилище и временные папки,
без изменения пользовательских сессий или каталога навыков.

- LM Studio: localhost:1234, уже загруженная
  gemma-4-e4b-uncensored-hauhaucs-aggressive; новые модели не загружались.
- Сначала модель выполнила небольшую задачу: разобрала синтетическую
  последовательность login failure → login success → privilege elevation
  и сформулировала checklist. Затем выполнено Create skill from session.
- Первый запуск выявил, что модель помещала SKILL.md в files. Проверка
  отклоняла это без карточки/записи. Уточнены описания schema и конкретные
  ошибки: SKILL.md body принадлежит instructions, files — только supporting
  files или []. Проверки не ослаблены, встроенная инструкция не изменена.
- Повторный запуск прошёл: появился настоящий native confirmation card с полным
  SKILL.md, без памяти решений. Approve создал auth-triage-checklist как
  disabled, origin=model-drafted; хэш записанных файлов совпал с просмотренным:
  `07d909d34dc64ee43bd5b78cae49c5ed891e91ee80a197c97fea4cb110653188`.
  Проверен один skill.draftApproved. Модель сформировала только SKILL.md,
  без лишних supporting files. Это **1 дополнительный live-тест**, отдельно
  от 423 тестов постоянного offline-набора.
- Native SwiftUI/AppKit карточка отрендерена в PNG и визуально проверена:
  весь SKILL.md виден, кнопки Approve/Reject присутствуют, checkbox памяти нет.
  Снимок: /tmp/maclm-step54-live-card.png. Лог успешного запуска:
  /tmp/maclm-step54-live-retry.log; harness сохранён в
  /tmp/maclm-step54-live-validation.swift и исключён из постоянного test target,
  чтобы make test не зависел от локальной модели и не добавлял пропуски.

Интерактивный обход всей оболочки приложения (нажатие меню/Settings и раскрытие
supporting files мышью) не выполнялся; эти элементы остаются для ручной проверки.
Отрисовка карточки и реальная модель проверены указанным способом, не через
симуляцию ответа модели.

## Ручная проверка

1. После успешной задачи открыть меню её чата → «Создать навык из этой сессии».
   Проверить точную английскую инструкцию в ленте и карточку caution.
   Повторить через `/skill new` (также можно через Quick Chat).
2. Прочитать сырой SKILL.md полностью. Для draft с supporting files раскрыть
   каждый файл и проверить путь, размер и полный текст до подтверждения.
3. На синтетических данных проверить предупреждения ключей/токенов и
   `/Users/example/`; Approve должен оставаться доступным.
4. Нажать Reject: навык и staging-файлы не должны появиться. Повторный вызов
   модели без нового запроса должен вернуть not requested без approval card.
5. Запросить снова и нажать Approve. Settings → Skills: disabled, «Создан моделью»,
   preview и файлы совпадают с карточкой. Каталог модели не содержит этот навык.
6. Включить вручную: badge исчезает. Выключить/перезапустить: badge не возвращается.
7. Запросить ещё один draft: memory checkbox отсутствует. Питомец показывает
   «Открыть в чате». Другой обычный caution-инструмент сохраняет session memory.
8. Отменить генерацию до вызова или на карточке; последующий обычный ход
   не должен наследовать запрос. Проверить оба режима интерфейса ru/en.
9. Проверить четыре события draft в аудите и JSONL-экспорт. Попытки read_file/
   write_file для skill-staging/ должны отклоняться обязательным block.

## Результат

Один атомарный коммит `feat(skills): create skill from session`, локальный тег
`v0.5.4`. Публикация в remote не входит в шаг.
