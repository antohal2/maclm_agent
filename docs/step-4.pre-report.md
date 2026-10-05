# Шаг 4.pre — Doc-sync Rev 4

## 1. Имена SPEC → код

Полная таблица — приложение A в SPEC. Основные соответствия:

| SPEC | Код |
|---|---|
| AppState | общий ChatViewModel + AppSettings |
| ToolCallRecord | ToolCall |
| StreamEvent | ChatStreamEvent |
| ModelInfo | отсутствует; DetectedProvider.availableModels: [String] |
| LLMProvider.identifier | name |
| LLMProvider.availableModels() | отдельный ProviderDiscovery.discover() |
| LLMProvider.stream(ChatRequest) | streamChat(messages:tools:); ChatRequest отсутствует |
| Tool.parameterSchema | parametersSchema |
| Tool.riskLevel(for:context:) | computeRisk(arguments:context:) → RiskAssessment |
| Arguments / ToolResult | [String: Any] / ToolExecutionResult |
| Tool.execute(_:), execute(_:policy:) | execute(arguments:), execute(arguments:policy:) |
| Decision / Outcome | AuditDecision / AuditOutcome |
| AuditEntry.riskLevel / decision | вычисляемые свойства; хранение riskRaw / decisionRaw |

RiskLevel, isPolicyEnforceable, SecurityRule, RuleDimension, RuleAction, AuditEntry, LLMProvider, Tool совпадают. Не реализованные Project, Checkpoint, SessionRunner, usage, userInitiated не считаются переименованиями.

## 2. Правки сверх пользовательской замены на Rev 4

1. SPEC 2: реальная структура каталогов; отсутствующие Clipboard/Workspace/Pet отделены от текущего кода; контейнер без VersionedSchema/SchemaMigrationPlan.
2. SPEC 2.1: Window вместо WindowGroup, AppKit MenuBarController вместо MenuBarExtra; общий ChatViewModel и AppSettings.
3. SPEC 2.2: фактический владелец цикла, одна генерация, восемь итераций, полный ответ до последовательного выполнения tool calls; точки проверки риска, правил, подтверждения и аудита.
4. SPEC 3: провайдер/модель глобальные в UserDefaults; ToolCall хранит статус, snapshot риска и причины, а не отдельное решение. Контейнер содержит шесть моделей; новые модели Rev 4 остаются планом.
5. SPEC 4.1/4.3: фактический контракт событий/ошибок, discovery отдельно; автоматической проверки поддержки tool calling нет, AgentLoop всегда передаёт tools, Clipboard Actions — tools: []. Условные имена сохранены и сопоставлены в приложении A.
6. SPEC 5.1: name/description/schema — свойства экземпляра; вычисление риска возвращает RiskAssessment с контекстом, инварианты обеспечивает ToolRiskEvaluator; policy-перегрузка execute.
7. SPEC 5.2: седьмой инструмент run_shell, dangerous/universal; zsh -c, таймаут 30 с, отмена, stdout/stderr/exitCode/timedOut; direct/streaming/cwd отсутствуют, path-политики не применяются.
8. SPEC 6.1: существующий run_shell вместо будущего Shell; allowed_dirs как отдельная настройка с пустым значением по умолчанию, повышение write_file/move_file; max(base, computed) и universal dangerous.
9. SPEC 6.2: текущая общая RAM-память на пару инструмент+уровень, явный сброс и перезапуск; будущая область на беседу сохранена.
10. SPEC 6.3: только path принуждается; реальные дополнительные поля SecurityRule, сортировка и block priority, канонизация, ancestor/globs, List/Search-фильтрация, CRUD/reset/preview и загрузка перед каждым вызовом; host пока storage-only.
11. SPEC 6.4/6.6: уточнена роль path-фильтра и человеческого подтверждения; описание текущего run_shell и будущие требования маршрутизации.
12. SPEC 6.5: причина повышения, сработавшее правило, errorDescription, durationMilliseconds, notExecuted; реальные фильтры и поиск, JSONL, отсутствие маскирования; retention по умолчанию 90 дней. checkpointID и userInitiated помечены будущими.
13. SPEC 6.7: глобальный allow включает allowed_dirs, внутри проектного периметра он не действует; будущий неотключаемый block каталога данных защищает файловые инструменты, но не подтверждённый run_shell. Это ограничение также отражено в 6.9.
14. SPEC 9.1: v0.6 развивает существующий run_shell; direct/streaming/cwd/command/Terminal.app — план; классификация direct открыта.
15. SPEC 10 и ROADMAP: v0.3 завершена по существующему тегу v0.3.4, v0.4 активна. Исторические теги завершения MVP/Clipboard сохранены.
16. ROADMAP: исправлены заявления о будущем получении shell с нуля; 4.3 переносит цикл из общего ChatViewModel, а не из представления.
17. docs/step-3.4-report.md: старые ссылки фаз актуализированы под Rev 4.
18. SPEC: приложение A с таблицей имён и отсутствующих сущностей.

### Перенесено из прежней SPEC

Из Rev 3 перенесены принятые формулировки 6.3–6.5: действующая область политик, сортировка/block priority, канонизация и фильтрация потомков, редактор, реальные поля аудита, notExecuted, фильтры/retention и отсутствие маскирования. Из 6.6 сохранены «Граница безопасности», «Маршрутизация возможностей», открытый direct-режим и предварительные требования AppleScript. Номера обновлены: Shell v0.6, AppleScript v0.7, Native API v0.8. Маршрутизация явно помечена будущим требованием, которого текущий run_shell не реализует. Устаревшие утверждения прежних разделов 2/3 о ещё не реализованных правилах и аудите не переносились: код v0.3.4 уже содержит их.

## 3. Разрыв между планом Rev 4 и кодом

- 6.7: Project, project-связь правила, рабочая папка, локальный периметр и неотключаемый block данных отсутствуют. Сейчас глобальные path-правила и allowedDirectories; встроенные правила отключаемы.
- 6.8: нет Checkpoint, снимков, квот, очистки, отката, checkpointID и userInitiated. Подтверждённый shell также не получит защиту будущих файловых чекпоинтов автоматически.
- 6.9: нет трейса со счётчиками, чипа периметра, диффов/отката и питомца. Текущие карточки подтверждения уже видны отдельно; dangerous не сворачивается.
- 13: нет проектов, закрепления/архива/форка, инструкций проекта, SessionRunner на беседу, параллельных прогонов, unread/status/уведомлений, инспектора, git-ветки, модели сессии, usage/контекста, новой локализации и согласованного настроечного UI.
- Авто-заголовок сейчас синхронно получается из первого пользовательского сообщения (до 40 символов), без отдельного запроса к LLM и titleIsManual. Предупреждение с подтверждением non-loopback endpoint пока не реализовано.
- Цикл уже принадлежит view model, а не представлению. Закрытие окна/смена беседы не означает независимых фоновых раннеров: генерация одна на приложение.

Эти различия сохранены как задачи будущих шагов; код не менялся.

## 4. Владение агентным циклом — вход для 4.3

Actor AgentLoop определён в maclm-agent/Core/Core.swift. ChatViewModel (Core/ChatViewModel.swift, @MainActor @Observable) хранит private let agentLoop и generationTask; send запускает streamResponse, consume сохраняет события в SwiftData, resolveConfirmation передаёт решение обратно actor.

MacLMAgentApp создаёт AgentLoop с общими SessionPermissions, замыканиями riskContext/securityRules/auditSink, затем ChatViewModel и хранит его в @State. Сцена Window(id: main) → MainWindowView → ChatView получает этот объект. MenuBarController получает тот же view model и показывает SwiftUI-контент через NSHostingController в NSPopover при NSStatusItem. MenuBarExtra отсутствует. Нужен переход от одного общего раннера к раннеру на беседу, а не буквальный перенос из View.

## 5. Сессионная память — вход для 4.4

Security/SessionPermissions.swift: @MainActor @Observable SessionPermissions содержит Set<SessionPermission>. Ключ — toolName: String + riskLevel: RiskLevel. allows/remember принимают только caution; dangerous никогда не запоминается. Пути, аргументы и conversationID в ключ не входят.

MacLMAgentApp создаёт один объект, передаёт AgentLoop и SettingsView. Память общая для всех бесед, только RAM, живёт до перезапуска приложения или reset из настроек; не сохраняется в SwiftData/UserDefaults. Смена беседы её не сбрасывает. resolveConfirmation добавляет разрешение только при approved + rememberForSession. Повышение риска до dangerous исключает повторное использование caution-grant.

## 6. Обход AgentLoop

В production найдена одна точка dispatch Tool.execute — Core/Core.swift внутри AgentLoop после проверки риска, правил и подтверждения. ClipboardActionRunner обращается к провайдеру с tools: [] и отвергает неожиданные вызовы; инструменты не выполняет. UI передаёт решения, инструменты напрямую не запускает.

Сами Tool.execute доступны без AgentLoop; list_dir/search_files имеют перегрузки с пустым SecurityPolicyEngine, остальные инструменты также не принуждают весь permission flow внутри execute. Это возможность прямого вызова из будущего кода/тестов, но действующего production-пути обхода не обнаружено. run_shell проходит AgentLoop и dangerous-подтверждение, однако намеренно исключён из path-политик — это ограничение политик, а не обход actor.

## Проверка

- Заголовки обоих документов: Revision 4.
- git diff --check: без ошибок.
- make build: BUILD SUCCEEDED (Debug, macOS arm64); лог /tmp/maclm-docsync-build.log.
- Собранное приложение открыто; процесс maclm-agent наблюдается. Инициализация контейнера предшествует запуску UI и fatalError при ошибке: запуск подтверждает открытие хранилища, но отдельная проверка количества/содержимого записей до и после не проводилась.
- Схемы SwiftData и исходники не изменены. Новые тесты не добавлялись; интеграционный прогон с LLM и ручная проверка UI не проводились.
- Один документационный коммит: docs: sync SPEC and ROADMAP to Rev 4, close v0.3; тег v0.3.5.
