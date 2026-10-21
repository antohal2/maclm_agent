import AppKit
import SwiftUI

struct SkillsSettingsView: View {
    let store: SkillStore
    var contextWindow: Int?
    @State private var entries: [SkillSnapshot] = []
    @State private var selectedID: String?
    @State private var busy = false
    @State private var visible = false
    @State private var errorMessage: String?
    @State private var pendingReconfirm: SkillSnapshot?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button(String(localized: "Пересканировать навыки")) { rescan() }
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(
                    String(localized: "Включённые навыки видны в каталоге модели. Текст передаётся после подключения.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(entries) { entry in
                        row(entry).tag(entry.id)
                    }
                }.frame(minWidth: 270, idealWidth: 310)
                ScrollView {
                    if let selected = entries.first(where: { $0.id == selectedID }) {
                        details(selected)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Выберите навык для просмотра.")).font(.headline)
                            Text(String(localized: "Поместите папку с SKILL.md в каталог навыков приложения."))
                            Text(verbatim: store.root.path).font(.caption).textSelection(.enabled)
                        }.padding()
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .disabled(busy)
        .onAppear { visible = true; rescan() }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if visible {
                rescan()
            }
        }
        .alert(String(localized: "Ошибка навыка"), isPresented: Binding(
            get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button(String(localized: "OK")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(String(localized: "Подтвердить изменённый навык?"), isPresented: Binding(
            get: { pendingReconfirm != nil }, set: {
                if !$0 {
                    pendingReconfirm = nil
                }
            }
        ), titleVisibility: .visible) {
            Button(String(localized: "Подтвердить и включить")) {
                if let entry = pendingReconfirm, let hash = entry.hash {
                    Task { await perform { try await store.reconfirm(entry.id, expectedHash: hash) } }
                }
                pendingReconfirm = nil
            }
            Button(String(localized: "Отмена"), role: .cancel) { pendingReconfirm = nil }
        } message: {
            Text(String(localized: "Проверьте обновлённый SKILL.md и файлы. Подтверждение сохранит новый хэш навыка."))
        }
    }

    private func row(_ entry: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: entry.id).font(.headline)
                Spacer()
                Toggle(String(localized: "Включить навык"), isOn: Binding(
                    get: { entry.state == .enabled }, set: { toggle(entry, enabled: $0) }
                ))
                .labelsHidden()
                .disabled(entry.state == .invalid)
            }
            Text(entry.state.displayName).font(.caption)
                .foregroundStyle(entry.state == .invalid || entry.state == .needsReconfirm ? .orange : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            if entry.state == .enabled, !SkillCatalogBuilder.build(entries, contextWindow: contextWindow)
                .components(separatedBy: "\n").contains(where: { $0.hasPrefix("\(entry.id): ") })
            {
                Text(String(localized: "Не вошёл в каталог"))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(String(localized: "Папка приложения")).font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            HStack {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                if let hash = entry.hash {
                    Text(verbatim: String(hash.prefix(12))).monospaced()
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func details(_ entry: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: entry.id).font(.title2)
            if let problem = entry.problem {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if entry.largeInstructionWarning {
                Text(String(localized: "SKILL.md занимает не менее 8 КиБ: большой объём инструкций."))
                    .foregroundStyle(.orange)
            }
            if entry.state == .needsReconfirm {
                Button(String(localized: "Подтвердить изменённый навык…")) { pendingReconfirm = entry }
                Button(String(localized: "Выключить навык")) {
                    Task { await perform { try await store.disable(entry.id) } }
                }
            }
            GroupBox(String(localized: "Предпросмотр записи каталога")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: entry.id).font(.headline)
                    Text(verbatim: entry.catalogDescription)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let hash = entry.hash {
                Text(String(localized: "Полный хэш навыка")).font(.headline)
                Text(verbatim: hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let enabledHash = entry.enabledHash, enabledHash != entry.hash {
                Text(String(localized: "Хэш при включении")).font(.headline)
                Text(verbatim: enabledHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text(String(localized: "Предпросмотр SKILL.md")).font(.headline)
            Text(verbatim: entry.text).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Файлы навыка")).font(.headline)
            ForEach(entry.files) { file in
                HStack {
                    Text(verbatim: file.path)
                    Spacer()
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                }.font(.caption)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ entry: SkillSnapshot, enabled: Bool) {
        selectedID = entry.id
        if enabled, entry.state == .needsReconfirm {
            pendingReconfirm = entry; return
        }
        Task {
            await perform {
                if enabled, let hash = entry.hash {
                    return try await store.enable(entry.id, expectedHash: hash)
                }
                return try await store.disable(entry.id)
            }
        }
    }

    private func rescan() {
        Task { await perform { try await store.rescan() } }
    }

    @MainActor private func perform(_ operation: () async throws -> [SkillSnapshot]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            entries = try await operation()
            if !entries.contains(where: { $0.id == selectedID }) {
                selectedID = entries.first?.id
            }
        } catch {
            // Refresh after a rejected stale approval to display the new trust state.
            if let refreshed = try? await store.rescan() {
                entries = refreshed
            }
            errorMessage = (error as? SkillValidationError)?.localizedDescription
                ?? String(localized: "Не удалось обновить хранилище навыков.")
        }
    }
}
