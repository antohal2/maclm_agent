import SwiftData
import SwiftUI

extension RuleDimension {
    var title: String {
        switch self {
        case .path: String(localized: "Пути")
        case .command: String(localized: "Команды")
        case .application: String(localized: "Приложения")
        case .host: String(localized: "Сетевые хосты")
        }
    }

    var notice: String {
        switch self {
        case .path: String(localized: "Применяются к шести файловым инструментам. Block всегда приоритетнее allow.")
        case .command: String(localized: "Сохраняются, но пока не применяются. Принуждение — v0.6 (Shell).")
        case .application: String(localized: "Сохраняются, но пока не применяются. Принуждение — v0.7 (AppleScript).")
        case .host: String(
                localized: "Сохраняются, но пока не применяются. Проверка ограничивается явными URL в аргументах: "
            )
                +
                String(
                    localized: """
                    невозможно статически определить адреса npm install, git pull или произвольного \
                    скрипта.
                    """
                )
        }
    }
}

struct SecurityRulesSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SecurityRule.order) private var rules: [SecurityRule]
    @State private var editing: SecurityRule?
    @State private var draft = SecurityRuleDraft()
    @State private var showsEditor = false
    @State private var confirmsReset = false
    @State private var operationError: String?

    private var store: SecurityRuleStore {
        .init(context: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Правила безопасности")).font(.headline)
            Label(
                String(localized: "Правила по путям действуют только на файловые инструменты. ")
                    +
                    String(
                        localized: "run_shell выполняет произвольные команды; правила на него не распространяются. "
                    )
                    + String(localized: "Единственная защита — подтверждение каждой команды на карточке. ")
                    + String(localized: "Блокировка ~/.ssh/** не остановит cat ~/.ssh/id_rsa. ")
                    + String(localized: "Внимательно читайте команду на карточке."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(RuleDimension.allCases, id: \.self) { dimension in
                    Section {
                        Text(dimension.notice).font(.caption).foregroundStyle(.secondary)
                        ForEach(group(dimension)) { rule in
                            HStack {
                                Toggle(
                                    String(localized: "Включено"),
                                    isOn: Binding(get: { rule.isEnabled }, set: { enabled in
                                        perform { try store.setEnabled(rule, enabled) }
                                    })
                                ).labelsHidden()
                                VStack(alignment: .leading) {
                                    Text("\(rule.action.rawValue) · \(rule.pattern)").font(.callout.monospaced())
                                    Text(InterfaceLocalization.text(rule.ruleDescription)).font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rule.isBuiltIn {
                                    Image(systemName: "lock.fill").help(String(localized: "Встроенное правило"))
                                }
                                Button(String(localized: "Изменить")) {
                                    editing = rule
                                    draft = SecurityRuleDraft(rule)
                                    showsEditor = true
                                }.buttonStyle(.borderless)
                                if !rule.isBuiltIn {
                                    Button(role: .destructive) { perform { try store.delete(rule) } } label: {
                                        Image(systemName: "trash")
                                    }.buttonStyle(.borderless).help(String(localized: "Удалить правило"))
                                }
                            }
                        }
                        .onMove { from, to in perform { try store.move(dimension: dimension, from: from, to: to) } }
                    } header: { Text(dimension.title) }
                }
            }.frame(minHeight: 280)
            HStack {
                Button(String(localized: "Добавить правило…")) {
                    editing = nil
                    draft = SecurityRuleDraft()
                    showsEditor = true
                }
                Button(String(localized: "Сбросить встроенные правила…")) { confirmsReset = true }
            }
        }
        .sheet(isPresented: $showsEditor) {
            SecurityRuleEditorView(draft: $draft, rule: editing, rules: rules.map(\.snapshot)) {
                perform {
                    try store.save(draft, rule: editing)
                    showsEditor = false
                }
            }
        }
        .alert(String(localized: "Восстановить встроенные правила?"), isPresented: $confirmsReset) {
            Button(String(localized: "Отмена"), role: .cancel) {}
            Button(String(localized: "Восстановить")) { perform { try store.resetBuiltIns() } }
        } message: {
            Text(
                String(
                    localized: """
                    Будут восстановлены исходные паттерны, действия, описания и порядок всех 16 \
                    встроенных правил;\u{20}
                    """
                )
                    + String(localized: "все они будут включены. Отсутствующие правила появятся снова. ")
                    + String(localized: "Пользовательские правила, их состояния и порядок не изменятся.")
            )
        }
        .alert(String(localized: "Ошибка сохранения"), isPresented: Binding(get: { operationError != nil }, set: {
            if !$0 {
                operationError = nil
            }
        })) {
            Button("OK") { operationError = nil }
        } message: { Text(operationError ?? "") }
    }

    private func group(_ dimension: RuleDimension) -> [SecurityRule] {
        rules.filter { $0.dimension == dimension }.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.pattern < $1.pattern
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { operationError = error.localizedDescription }
    }
}

private struct SecurityRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: SecurityRuleDraft
    let rule: SecurityRule?
    let rules: [SecurityRuleSnapshot]
    let save: () -> Void
    @State private var example = ""
    private var locked: Bool {
        rule?.isBuiltIn == true
    }

    private var error: String? {
        SecurityPattern.error(draft.pattern, dimension: draft.dimension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule == nil ? String(localized: "Новое правило") : String(localized: "Редактирование правила"))
                .font(.headline)
            Picker(String(localized: "Измерение"), selection: $draft.dimension) {
                ForEach(RuleDimension.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(locked)
            Picker(String(localized: "Действие"), selection: $draft.action) {
                Text(String(localized: "Разрешить · allow")).tag(RuleAction.allow)
                Text(String(localized: "Запретить · block")).tag(RuleAction.block)
            }.disabled(locked)
            TextField(String(localized: "Паттерн"), text: $draft.pattern).disabled(locked)
            TextField(String(localized: "Описание"), text: $draft.ruleDescription).disabled(locked)
            Toggle(String(localized: "Включено"), isOn: $draft.isEnabled)
            if locked {
                Text(String(localized: "У встроенного правила меняется только включение.")).font(.caption)
            }
            Text(draft.dimension.notice).font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if draft.dimension == .path, error == nil {
                Text("Канонический паттерн: \(PathCanonicalizer.canonicalizePattern(draft.pattern))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(
                    String(localized: "Глоб: * и ? внутри компонента; ** пересекает /. ")
                        + String(localized: "Совпадение с каталогом распространяется на потомков.")
                )
                .font(.caption)
                if ["**", "/**", "*"].contains(draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text(
                        String(
                            localized: "Внимание: предельно широкий паттерн, включая всю файловую систему для ** и /**."
                        )
                    )
                    .foregroundStyle(.orange)
                }
            }
            TextField(String(localized: "Проверить на примере"), text: $example)
            if !example.isEmpty, error == nil {
                Text(SecurityPattern
                    .matches(example, draft: draft) ? String(localized: "Паттерн совпадает") :
                    String(localized: "Паттерн не совпадает"))
                let decision = SecurityPattern.preview(example, draft: draft, replacing: rule?.snapshot, rules: rules)
                Text(verdict(decision)).textSelection(.enabled)
                Text(
                    String(localized: "Проверка учитывает несохранённый вариант и весь набор правил; ")
                        + String(localized: "путь проверяется как read_file. Это не разрешение на выполнение.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Отмена")) { dismiss() }
                Button(String(localized: "Сохранить"), action: save).disabled(error != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 640)
    }

    private func verdict(_ decision: PolicyDecision) -> String {
        if decision.disposition == .allowed {
            return String(localized: "Разрешено: \(decision.rule?.pattern ?? "")")
        }
        if decision.disposition == .blocked {
            return String(localized: "Запрещено: \(decision.rule?.pattern ?? "")")
        }
        if draft.dimension == .path {
            return String(localized: "Нет решения: совпавших включённых правил нет.")
        }
        return String(localized: "Нет решения: принуждение по этому измерению не включено.")
    }
}
