# Step 5.2 — list_skill_files and read_skill_file

Дата: 2026-10-21. Исходная версия: `v0.5.1`. Результат: `v0.5.2`.
SPEC, раздел 15 (Rev 5), прочитан до реализации. Конфликтов с заданием нет;
в 15.7 внесена разрешённая заданием замена realpath на обход через дескрипторы.

## Реализация

- `list_skill_files(skill)` и `read_skill_file(skill, path)` зарегистрированы в
  основном ToolRegistry с базовым уровнем safe. Описания для модели на английском
  требуют подключения навыка к текущей сессии; path по умолчанию — SKILL.md.
- SessionRunner передаёт вызовы через SessionSkills в единственный SkillStore,
  предоставленный ApplicationRuntime. Проверяется подключение именно к текущей
  сессии, enabled-состояние, источник и сохранённые метаданные доверия. Чужая
  сессия, неизвестный или неподключённый навык получают ошибку not attached;
  выключенный после подключения — unavailable с причиной.
- SkillFileIO содержит общий validateModelPath / withResolvedPath для обоих
  инструментов. Лексическая проверка выполняется до открытия пути: отклоняются
  пустые, абсолютные и ведущие ~ пути, пустые компоненты, . и .., обратный слэш,
  NUL и управляющие символы, percent encoding, меняющий строку при декодировании,
  завершающий / и NFKC-варианты . / .. / разделителя.
- После проверки папка навыка закрепляется файловым дескриптором. Каждый компонент
  открывается через openat с O_NOFOLLOW; конечная цель проверяется fstat и должна
  быть обычным файлом. Нет realpath с последующим open. Общий readFile сканера
  использует тот же обход и прежнее ограниченное чтение с проверками размера,
  mtime и ctime до/после. Сам сканер, хэш и правила учёта лимитов сохранены.
- Listing обходит вложенные папки тем же resolver, получает метаданные через
  fstatat без следования ссылкам, исключает симлинки и специальные файлы. Пути
  сортируются по UTF-8, результат — JSON объектов path/size. Дополнительные
  предохранители обхода: 200 файлов, 2000 записей, глубина менее 64 каталогов;
  превышение возвращает ошибку целиком.
- Любой компонент с начальной точкой скрыт при listing и запрещён при чтении,
  включая .git, .env, .DS_Store, ._* и вложенные скрытые имена. Более узкая
  SkillFilePolicy.isIgnored не менялась: хэширование и лимиты не расширяли
  исключения на остальные скрытые файлы.
- Read возвращает полный UTF-8 текст размером до 32768 байт включительно.
  Больший файл, невалидный UTF-8, бинарные управляющие символы, каталог,
  отсутствующий файл или подмена симлинком дают ошибку без частичного содержимого.
  Переводы строк и табуляция разрешены.
- Эти инструменты не загружают проектные правила путей и не используют их для
  разрешения относительного пути. Все остальные инструменты продолжают работать
  через прежнюю SecurityPolicyEngine, включая обязательный запрет данных приложения.
  Статическая оценка риска и общий аудит вызова сохраняются.
- В SwiftData добавляются события skill.fileList / skill.fileRead: skill, source,
  path, byteCount, conversationID и reason. Успехи и отказы записываются до выдачи
  результата. Для listing path пустой, byteCount — сумма размеров перечисленных
  файлов; для read — число возвращённых байт. При отказе byteCount равен нулю.
  Если сохранение аудита не удалось, содержимое модели не выдаётся. Содержимое
  файла не дублируется в summary ни специального, ни общего события аудита.
  Формат JSONL экспорта не менялся.
- Заголовки вызовов в ToolCallCard локализованы ru/en; идентификаторы инструментов,
  ответы модели и записи аудита остаются на английском. Тест полноты каталога зелёный.
- Проверка хэша при каждом чтении намеренно отсутствует (SPEC 15.13). Состояние
  доверия проверяется по метаданным; изменённый во время сессии обычный файл может
  читаться до следующей штатной проверки. Описания инструментов не обещают integrity.
- Новых зависимостей и сетевых обращений в реализации нет. SwiftData-схема не
  менялась. Версия в project.yml и сгенерированном проекте обновлена до 0.5.2.
  Небольшие вспомогательные методы выделены для сохранения лимитов линтера.

## Проверки

Среда: Xcode 27.1 (27A9275), Swift 6, macOS arm64.

Команды:

- `make generate`
- `make build DERIVED_DATA=/tmp/maclm-step52`
- `make test DERIVED_DATA=/tmp/maclm-step52`
- `make lint`
- `git diff --check`

Итог: **367 тестов: 363 прошли, 4 пропущены, 0 ошибок**.
Добавлено **22 теста** SkillFileToolTests. Сборка успешна; новых Swift 6 strict
concurrency diagnostics нет. Ожидание количества инструментов в существующем
SessionContextTests обновлено с 8 на 10.

Проверены все формы путей из задания, скрытые компоненты, вложенное чтение,
размеры listing, SKILL.md по умолчанию, границы 32 КиБ, бинарные и невалидные
UTF-8 данные, каталог и отсутствующий файл. Отдельно проверены симлинки файла
и каталога после сканирования, подмена файла между list/read и подмена самой
папки навыка. Проверены изоляция сессий, disable/detach, неизвестный навык,
неверные аргументы, успешный и отказной аудит, отсутствие контента в audit summary.

Интеграционный провайдер проверяет реальную цепочку AgentLoop → SessionSkills →
SkillStore → list/read → tool results для модели. Другой интеграционный тест
проверяет wiring SessionRunner. Правила проекта в первом тесте бросают ошибку
при попытке загрузки: оба инструмента успешно работают без обращения к ним.
Существующий SkillSecurityTests.testAttachedSkillDoesNotBypassMandatoryFileBlock
остаётся зелёным: обычные файловые инструменты блокируются для skills/ при
подключённом навыке даже с дополнительным allow-правилом.
Существующие scanner/store/hash, migration, dangerous approval, caution memory,
pet и localization regression tests также прошли.

Полный список пропусков — прежние, новых нет:

| Тест | Причина |
| --- | --- |
| CheckpointMigrationTests.testRealV045StoreCopyMigrationPreservesRowsAndDefaults | Нет /tmp/maclm-46-migration-source/default.store; Explicit v0.4.5 real-store copy not present. |
| SessionContextMigrationTests.testRealV046StoreCopyMigrationPreservesRowsAndDefaults | Нет /tmp/maclm-47-migration-source/default.store; Explicit v0.4.6 real-store copy not present. |
| SessionLoadTests.testMigrationOnLocalRealV042Snapshot | Нет build/step43-validation/before.store; Local real snapshot is intentionally excluded from Git. |
| WorkspaceMigrationTests.testMigrationOfExplicitRealStoreCopy | Нет /tmp/maclm-44-migration-source/default.store; Explicit migration fixture not present. |

Предупреждения — только исходные: deprecated appendInterpolation в
ToolCallCard.swift:46; порядок await try в ClipboardActionRunnerTests.swift
на строках 51, 71, 96, 117, 139, 165, 236; AppIntents metadata extraction skipped
из-за отсутствия AppIntents.framework dependency. Новых предупреждений нет.
SwiftFormat проходит. make lint возвращает ненулевой код только из-за двух
исходных SwiftLint line_length: PetSettingsView.swift:13 и PetLibraryTests.swift:36.
Новых замечаний SwiftLint нет.

В runtime-логах тестового приложения также есть прежние сообщения macOS о linkd,
недоступных локальных провайдерах, повреждённых PNG fixtures и удаляемых временных
SQLite migration fixtures. Ошибок тестов они не вызывают.

Логи: /tmp/maclm-step52-build-final.log, /tmp/maclm-step52-test-final.log,
/tmp/maclm-step52-lint-final.log. Результат XCTest:
/tmp/maclm-step52/Logs/Test/Test-maclm-agent-2026.10.21_21-33-38-+0700.xcresult.

## Ручная проверка

Ручная проверка UI и вызовы реальной локальной LLM не выполнялись. Цепочка
function calling проверена автоматическим провайдером; визуальная проверка
локализованных заголовков и поведение конкретной модели остаются ручными.

1. Создать валидный навык с SKILL.md и refs/reference.txt, включить в Settings →
   Skills, подключить к чату через @ или подтверждённое suggest_skill.
2. Выбрать локальную модель с native function calling. Запросить:
   RU: «Вызови list_skill_files для подключённого навыка sample, затем прочитай
   refs/reference.txt через read_skill_file».
   EN: “Call list_skill_files for the attached skill sample, then read
   refs/reference.txt with read_skill_file.”
3. Проверить относительные пути и размеры, полный reference в ответе,
   отсутствие запроса подтверждения для safe и заголовки вызовов ru/en.
4. Вызвать read_skill_file без path — должен вернуться SKILL.md.
5. Проверить .., ../x, абсолютный путь, .env, sub/.hidden и каталог:
   каждый read должен вернуть ошибку, скрытых имён в list быть не должно.
6. После подключения добавить симлинки на файл и каталог вне навыка, затем
   заменить reference.txt симлинком: список не должен следовать ссылкам,
   чтение должно отклоняться.
7. Выключить или отключить навык; повторить вызовы. В другом чате без подключения
   запросить тот же skill id. Доступа быть не должно.
8. Обычным read_file запросить файл skills/ в Application Support приложения:
   обязательный block должен сохраниться.
9. Проверить в журнале skill.fileList / skill.fileRead, conversationID, source,
   относительный path, byteCount и причины отказов; проверить JSONL экспорт.
