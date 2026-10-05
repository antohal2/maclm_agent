import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AuditCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(String(localized: "Журнал аудита…")) { openWindow(id: "audit") }
        }
    }
}

struct AuditLogView: View {
    @Environment(\.modelContext) private var context
    @State private var filter = AuditFilter()
    @State private var useDates = false
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var rows: [AuditRecord] = []
    @State private var selection: UUID?
    @State private var hasMore = true
    @State private var exporting = false
    @State private var status = ""

    private var activeFilter: AuditFilter {
        var value = filter
        value.start = useDates ? start : nil
        value.end = useDates ? end : nil
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(String(localized: "Поиск: инструмент или аргументы"), text: $filter.search)
                TextField(String(localized: "Инструмент (точное имя)"), text: $filter.tool)
                Picker(String(localized: "Риск"), selection: $filter.risk) {
                    Text(String(localized: "Все")).tag(nil as RiskLevel?)
                    ForEach(RiskLevel.allCases, id: \.self) { risk in
                        Text(String(describing: risk)).tag(Optional(risk))
                    }
                }
                Picker(String(localized: "Решение"), selection: $filter.decision) {
                    Text(String(localized: "Все")).tag(nil as AuditDecision?)
                    ForEach(AuditDecision.allCases, id: \.self) { decision in
                        Text(decision.rawValue).tag(Optional(decision))
                    }
                }
            }
            HStack {
                Toggle(String(localized: "Диапазон дат"), isOn: $useDates)
                if useDates {
                    DatePicker(String(localized: "С"), selection: $start)
                    DatePicker(String(localized: "По"), selection: $end)
                }
                Spacer()
                Button(String(localized: "Обновить")) { reload() }
                Button(String(localized: "Экспорт по текущим фильтрам…"), action: export).disabled(exporting)
            }
            Table(rows, selection: $selection) {
                TableColumn(String(localized: "Время")) { Text($0.timestamp.formatted(date: .numeric, time: .standard))
                }
                TableColumn(String(localized: "Инструмент"), value: \.toolName)
                TableColumn(String(localized: "Уровень")) { Text(String(describing: $0.riskLevel)) }
                TableColumn(String(localized: "Решение")) { Text($0.decision.rawValue) }
                TableColumn(String(localized: "Исход")) { Text($0.outcome.rawValue) }
            }
            HStack {
                Text(String(localized: "Загружено: \(rows.count)")).foregroundStyle(.secondary)
                if hasMore {
                    Button(String(localized: "Загрузить ещё 200")) { loadPage() }
                }
                Text(status).foregroundStyle(.secondary)
            }
            if let entry = rows.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Аргументы (сохранённый вид)")).font(.headline)
                        Text(entry.argumentsJSON).font(.system(.body, design: .monospaced))
                        Text(String(localized: "Причина уровня: \(entry.elevationReason ?? "—")"))
                        Text(String(localized: "Правило: \(entry.matchedRuleDescription ?? "—")"))
                        Text(String(localized: "Результат: \(entry.resultSummary)"))
                        if let error = entry.errorDescription {
                            Text(String(localized: "Ошибка: \(error)"))
                        }
                        Text("Длительность выполнения: \(durationLabel(entry.durationMilliseconds))")
                        Text(String(localized: "Диалог: \(entry.conversationID?.uuidString ?? "—")"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 250)
            }
        }
        .padding()
        .frame(minWidth: 950, minHeight: 600)
        .onAppear { reload() }
        .onChange(of: activeFilter) { reload() }
    }

    private func reload() {
        rows = []
        selection = nil
        status = ""
        loadPage()
    }

    private func loadPage() {
        do {
            // A separate context prevents months of entries accumulating in the UI context.
            let pageContext = ModelContext(context.container)
            let entries = try activeFilter.page(context: pageContext, offset: rows.count)
            rows.append(contentsOf: entries.map(\.record))
            hasMore = entries.count == 200
        } catch { status = error.localizedDescription }
    }

    private func durationLabel(_ milliseconds: Int?) -> String {
        milliseconds.map { String(localized: "\($0) мс") } ?? "—"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт журнала по текущим фильтрам")
        panel.nameFieldStringValue = "audit.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        let selectedFilter = activeFilter
        let container = context.container
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            Task {
                let maintenance = await AuditMaintenance.background(container: container)
                defer { exporting = false }
                do {
                    let count = try await maintenance.export(filter: selectedFilter, to: url)
                    status = String(localized: "Экспортировано записей: \(count)")
                } catch { status = error.localizedDescription }
            }
        }
    }
}

extension AuditRecord: Identifiable {}
