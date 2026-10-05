import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AuditCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Журнал аудита…") { openWindow(id: "audit") }
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
                TextField("Поиск: инструмент или аргументы", text: $filter.search)
                TextField("Инструмент (точное имя)", text: $filter.tool)
                Picker("Риск", selection: $filter.risk) {
                    Text("Все").tag(nil as RiskLevel?)
                    ForEach(RiskLevel.allCases, id: \.self) { risk in
                        Text(String(describing: risk)).tag(Optional(risk))
                    }
                }
                Picker("Решение", selection: $filter.decision) {
                    Text("Все").tag(nil as AuditDecision?)
                    ForEach(AuditDecision.allCases, id: \.self) { decision in
                        Text(decision.rawValue).tag(Optional(decision))
                    }
                }
            }
            HStack {
                Toggle("Диапазон дат", isOn: $useDates)
                if useDates {
                    DatePicker("С", selection: $start)
                    DatePicker("По", selection: $end)
                }
                Spacer()
                Button("Обновить") { reload() }
                Button("Экспорт по текущим фильтрам…", action: export).disabled(exporting)
            }
            Table(rows, selection: $selection) {
                TableColumn("Время") { Text($0.timestamp.formatted(date: .numeric, time: .standard)) }
                TableColumn("Инструмент", value: \.toolName)
                TableColumn("Уровень") { Text(String(describing: $0.riskLevel)) }
                TableColumn("Решение") { Text($0.decision.rawValue) }
                TableColumn("Исход") { Text($0.outcome.rawValue) }
            }
            HStack {
                Text("Загружено: \(rows.count)").foregroundStyle(.secondary)
                if hasMore {
                    Button("Загрузить ещё 200") { loadPage() }
                }
                Text(status).foregroundStyle(.secondary)
            }
            if let entry = rows.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Аргументы (сохранённый вид)").font(.headline)
                        Text(entry.argumentsJSON).font(.system(.body, design: .monospaced))
                        Text("Причина уровня: \(entry.elevationReason ?? "—")")
                        Text("Правило: \(entry.matchedRuleDescription ?? "—")")
                        Text("Результат: \(entry.resultSummary)")
                        if let error = entry.errorDescription {
                            Text("Ошибка: \(error)")
                        }
                        Text("Длительность выполнения: \(entry.durationMilliseconds.map { "\($0) мс" } ?? "—")")
                        Text("Диалог: \(entry.conversationID?.uuidString ?? "—")")
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

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Экспорт журнала по текущим фильтрам"
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
                    status = "Экспортировано записей: \(count)"
                } catch { status = error.localizedDescription }
            }
        }
    }
}

extension AuditRecord: Identifiable {}
