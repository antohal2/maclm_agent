import AppKit
import SwiftUI

struct SecuritySettingsView: View {
    @Bindable var settings: AppSettings
    let sessionPermissions: SessionPermissions
    @State private var broadDirectory: String?
    @State private var showBroadWarning = false

    var body: some View {
        Form {
            Section("Разрешённые директории · allowed_dirs") {
                Text("Запись и перемещение внутри этих папок получают уровень caution: разрешение можно запомнить на сессию. Вне них — dangerous с подтверждением каждого вызова.")
                    .font(.callout)
                if settings.allowedDirectories.isEmpty {
                    Text("Пока не задано: любая запись и перемещение файлов требуют подтверждения каждый раз (уровень dangerous)")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.allowedDirectories.enumerated()), id: \.offset) { index, directory in
                        HStack {
                            Text(directory).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button {
                                settings.removeAllowedDirectory(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Убрать из разрешённых директорий")
                            .accessibilityLabel("Убрать \(directory) из разрешённых директорий")
                        }
                    }
                }
                Button("Добавить папку…", action: chooseDirectory)
                Text("Этот список меняет только уровень риска. Запреты SecurityRule продолжают действовать независимо от него.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Разрешения текущей сессии") {
                if sessionPermissions.permissions.isEmpty {
                    Text("Нет запомненных разрешений.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionPermissions.sortedPermissions) { permission in
                        Label("\(permission.toolName) · caution", systemImage: "checkmark.shield")
                    }
                }
                Text("Запоминаются только разрешения caution. Dangerous подтверждается каждый раз. При перезапуске приложения память очищается.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Сбросить") { sessionPermissions.reset() }
                    .disabled(sessionPermissions.permissions.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Широкая область разрешения", isPresented: $showBroadWarning) {
            Button("Отмена", role: .cancel) { broadDirectory = nil }
            Button("Добавить всё равно") {
                if let directory = broadDirectory { settings.addAllowedDirectory(directory) }
                broadDirectory = nil
            }
        } message: {
            Text("Папка \(broadDirectory ?? "") включает конфигурации оболочки и автозапуска. Запись в них без подтверждения каждый раз опасна. Разрешение caution на инструмент можно будет запомнить для всей этой области.")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Добавить разрешённую директорию"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let directory = PathCanonicalizer.canonicalize(url.path)
            if AppSettings.isBroadDirectory(directory) {
                broadDirectory = directory
                showBroadWarning = true
            } else {
                settings.addAllowedDirectory(directory)
            }
        }
    }
}
