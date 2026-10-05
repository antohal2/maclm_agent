import SwiftData
import SwiftUI

extension RuleDimension {
    var title: String {
        switch self {
        case .path: "Пути"
        case .command: "Команды"
        case .application: "Приложения"
        case .host: "Сетевые хосты"
        }
    }

    var notice: String {
        switch self {
        case .path: "Применяются к шести файловым инструментам. Block всегда приоритетнее allow."
        case .command: "Сохраняются, но пока не применяются. Принуждение — v0.6 (Shell)."
        case .application: "Сохраняются, но пока не применяются. Принуждение — v0.7 (AppleScript)."
        case .host: "Сохраняются, но пока не применяются. Проверка ограничивается явными URL в аргументах: "
            + "невозможно статически определить адреса npm install, git pull или произвольного скрипта."
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
            Text("Правила безопасности").font(.headline)
            Label(
                "Правила по путям действуют только на файловые инструменты. "
                    + "run_shell выполняет произвольные команды; правила на него не распространяются. "
                    + "Единственная защита — подтверждение каждой команды на карточке. "
                    + "Блокировка ~/.ssh/** не остановит cat ~/.ssh/id_rsa. "
                    + "Внимательно читайте команду на карточке.",
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
                                Toggle("Включено", isOn: Binding(get: { rule.isEnabled }, set: { enabled in
                                    perform { try store.setEnabled(rule, enabled) }
                                })).labelsHidden()
                                VStack(alignment: .leading) {
                                    Text("\(rule.action.rawValue) · \(rule.pattern)").font(.callout.monospaced())
                                    Text(rule.ruleDescription).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rule.isBuiltIn {
                                    Image(systemName: "lock.fill").help("Встроенное правило")
                                }
                                Button("Изменить") {
                                    editing = rule
                                    draft = SecurityRuleDraft(rule)
                                    showsEditor = true
                                }.buttonStyle(.borderless)
                                if !rule.isBuiltIn {
                                    Button(role: .destructive) { perform { try store.delete(rule) } } label: {
                                        Image(systemName: "trash")
                                    }.buttonStyle(.borderless).help("Удалить правило")
                                }
                            }
                        }
                        .onMove { from, to in perform { try store.move(dimension: dimension, from: from, to: to) } }
                    } header: { Text(dimension.title) }
                }
            }.frame(minHeight: 280)
            HStack {
                Button("Добавить правило…") {
                    editing = nil
                    draft = SecurityRuleDraft()
                    showsEditor = true
                }
                Button("Сбросить встроенные правила…") { confirmsReset = true }
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
        .alert("Восстановить встроенные правила?", isPresented: $confirmsReset) {
            Button("Отмена", role: .cancel) {}
            Button("Восстановить") { perform { try store.resetBuiltIns() } }
        } message: {
            Text(
                "Будут восстановлены исходные паттерны, действия, описания и порядок всех 16 встроенных правил; "
                    + "все они будут включены. Отсутствующие правила появятся снова. "
                    + "Пользовательские правила, их состояния и порядок не изменятся."
            )
        }
        .alert("Ошибка сохранения", isPresented: Binding(get: { operationError != nil }, set: {
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
            Text(rule == nil ? "Новое правило" : "Редактирование правила").font(.headline)
            Picker("Измерение", selection: $draft.dimension) {
                ForEach(RuleDimension.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(locked)
            Picker("Действие", selection: $draft.action) {
                Text("Разрешить · allow").tag(RuleAction.allow)
                Text("Запретить · block").tag(RuleAction.block)
            }.disabled(locked)
            TextField("Паттерн", text: $draft.pattern).disabled(locked)
            TextField("Описание", text: $draft.ruleDescription).disabled(locked)
            Toggle("Включено", isOn: $draft.isEnabled)
            if locked {
                Text("У встроенного правила меняется только включение.").font(.caption)
            }
            Text(draft.dimension.notice).font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if draft.dimension == .path, error == nil {
                Text("Канонический паттерн: \(PathCanonicalizer.canonicalizePattern(draft.pattern))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(
                    "Глоб: * и ? внутри компонента; ** пересекает /. "
                        + "Совпадение с каталогом распространяется на потомков."
                )
                .font(.caption)
                if ["**", "/**", "*"].contains(draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text("Внимание: предельно широкий паттерн, включая всю файловую систему для ** и /**.")
                        .foregroundStyle(.orange)
                }
            }
            TextField("Проверить на примере", text: $example)
            if !example.isEmpty, error == nil {
                Text(SecurityPattern.matches(example, draft: draft) ? "Паттерн совпадает" : "Паттерн не совпадает")
                let decision = SecurityPattern.preview(example, draft: draft, replacing: rule?.snapshot, rules: rules)
                Text(verdict(decision)).textSelection(.enabled)
                Text(
                    "Проверка учитывает несохранённый вариант и весь набор правил; "
                        + "путь проверяется как read_file. Это не разрешение на выполнение."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save).disabled(error != nil).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 640)
    }

    private func verdict(_ decision: PolicyDecision) -> String {
        switch decision.disposition {
        case .allowed: "Разрешено: \(decision.rule?.pattern ?? "")"
        case .blocked: "Запрещено: \(decision.rule?.pattern ?? "")"
        case .noDecision:
            draft.dimension == .path ? "Нет решения: совпавших включённых правил нет."
                : "Нет решения: принуждение по этому измерению не включено."
        }
    }
}
