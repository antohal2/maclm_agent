import SwiftData
import SwiftUI

struct FilePreviewView: View {
    let toolName: String
    let preview: FilePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if preview.canRestore {
                Label(String(localized: "Можно будет откатить"), systemImage: "arrow.uturn.backward")
                    .font(.caption)
            } else {
                let reason = InterfaceLocalization.text(preview.rollbackReason ?? CheckpointError.unavailable.rawValue)
                Text(String(localized: "Без возможности отката: \(reason)"))
                    .foregroundStyle(.red).font(.callout.weight(.semibold))
            }
            switch preview.kind {
            case "unavailable": Text(String(localized: "Превью недоступно"))
            case "new": Text(String(localized: "Новый файл"))
            case "diff": Text("+\(preview.added) −\(preview.removed)").font(.caption.monospaced())
            case "move_file":
                Text(preview.paths.joined(separator: " → ")).font(.caption.monospaced()).textSelection(.enabled)
                if preview.destinationExists {
                    Text(String(localized: "Файл в месте назначения будет перезаписан")).foregroundStyle(.red)
                }
            default:
                let before = ByteCountFormatter.string(fromByteCount: preview.beforeBytes, countStyle: .file)
                let after = ByteCountFormatter.string(fromByteCount: preview.afterBytes, countStyle: .file)
                if toolName == "delete_file" {
                    Text(String(localized: "Размер: \(before)"))
                } else {
                    Text(String(localized: "Размер: \(before) → \(after)"))
                }
            }
            if toolName == "delete_file" {
                Text(InterfaceLocalization.text(preview.objectType ?? "Файл"))
                if preview.kind == "directory" {
                    Text(String(localized: "Элементов: \(preview.count)"))
                }
                if let modified = preview.modified {
                    Text(modified, format: .dateTime)
                }
            }
            if !preview.lines.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.kind == "…" ? "…" : line
                                .kind + (line.kind == "\\" ? InterfaceLocalization.text(line.text) : line.text))
                                .font(.caption.monospaced()).foregroundStyle(color(line.kind)).textSelection(.enabled)
                        }
                    }
                }.frame(maxHeight: 240)
            }
        }
    }

    private func color(_ kind: String) -> Color {
        kind == "+" ? .green : kind == "-" ? .red : .primary
    }
}

struct CheckpointsView: View {
    let conversation: Conversation
    let runner: SessionRunner
    private var isRunning: Bool {
        runner.isGenerating || runner.isRestoringCheckpoint
    }

    @Environment(\.checkpointStore) private var store
    @Query private var records: [Checkpoint]
    @State private var pending: RestorePreview?
    @State private var showRestore = false
    @State private var busy = false
    @State private var error: String?

    init(conversation: Conversation, runner: SessionRunner) {
        self.conversation = conversation
        self.runner = runner
        let id = conversation.id
        _records = Query(filter: #Predicate<Checkpoint> { $0.conversationID == id }, sort: \.createdAt, order: .reverse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if records.isEmpty {
                Text(String(localized: "Нет чекпоинтов")).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.createdAt, format: .dateTime).font(.caption)
                    Text(record.toolName).font(.caption.monospaced().weight(.semibold))
                    ForEach(record.items, id: \.originalPath) { item in
                        Text(item.originalPath).font(.caption).textSelection(.enabled)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file)).font(.caption)
                    Text(record.isRestored ? String(localized: "Восстановлен") : String(localized: "Сохранён"))
                        .font(.caption)
                    Button(String(localized: "Откатить…")) {
                        guard let store else { return }
                        busy = true
                        Task {
                            defer { busy = false }
                            do { pending = try await store.previewRestore(
                                record.snapshot,
                                conversation: conversation
                            ); showRestore = true } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(isRunning || busy || record.isRestored || store == nil)
                }
                Divider()
            }
            Text(String(localized: "Чекпоинты не заменяют Git и резервные копии")).font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "Изменения команд run_shell чекпоинтами не покрываются")).font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            String(localized: "Откатить чекпоинт?"),
            isPresented: $showRestore,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Откатить"), role: .destructive) {
                guard let pending, let store, !isRunning else { return }
                busy = true
                runner.isRestoringCheckpoint = true
                Task {
                    defer { busy = false; runner.isRestoringCheckpoint = false; self.pending = nil }
                    do { try await store.restore(pending, conversation: conversation) }
                    catch { self.error = error.localizedDescription }
                }
            }.disabled(isRunning)
            Button(String(localized: "Отмена"), role: .cancel) { pending = nil }
        } message: {
            if let pending {
                Text(restoreDescription(pending))
            }
        }
    }

    private func restoreDescription(_ preview: RestorePreview) -> String {
        var text = preview
            .changed ? String(localized: "Файлы изменились после операции. Текущие изменения будут заменены.") + "\n" :
            ""
        text += String(localized: "Сначала будет сохранён снимок текущего состояния.") + "\n"
        for (index, item) in preview.checkpoint.items.enumerated() {
            let exists = preview.current.fingerprints[index].exists
            let action = item
                .existedBefore ? (exists ? String(localized: "Перезаписать") : String(localized: "Восстановить")) :
                String(localized: "Удалить")
            text += action + ": " + item.originalPath + "\n"
        }
        return text
    }
}

struct CheckpointSettingsView: View {
    @Environment(\.checkpointStore) private var store
    @State private var volume = 2
    @State private var days = 30
    @State private var clear = false
    @State private var error: String?
    var body: some View {
        Section(String(localized: "Чекпоинты")) {
            Stepper(String(localized: "Лимит объёма: \(volume) ГБ"), value: $volume, in: 1 ... 100)
            Stepper(String(localized: "Срок хранения: \(days) дней"), value: $days, in: 1 ... 3650)
            Text(
                String(
                    localized: "Текущий объём: \(ByteCountFormatter.string(fromByteCount: store?.usage ?? 0, countStyle: .file))"
                )
            )
            Button(String(localized: "Очистить все чекпоинты…"), role: .destructive) { clear = true }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .task { volume = store?.volumeGB ?? 2; days = store?.retentionDays ?? 30; await update() }
        .onChange(of: volume) { _, _ in Task { await update() } }
        .onChange(of: days) { _, _ in Task { await update() } }
        .confirmationDialog(
            String(localized: "Очистить все чекпоинты?"),
            isPresented: $clear,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) {
                Task { do { try await store?.maintain(clear: true) } catch { self.error = error.localizedDescription } }
            }
        } message: { Text(String(localized: "Сохранённые копии будут удалены. Активные чекпоинты сохраняются.")) }
    }

    private func update() async {
        store?.volumeGB = volume
        store?.retentionDays = days
        do { try await store?.maintain() } catch { self.error = error.localizedDescription }
    }
}
