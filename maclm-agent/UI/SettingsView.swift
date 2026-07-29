import SwiftUI

struct SettingsView: View {
    @Bindable var providerCoordinator: ProviderCoordinator
    @Bindable var settings: AppSettings
    @Bindable var hotKeyController: GlobalHotKeyController

    var body: some View {
        TabView {
            ProviderSettingsView(coordinator: providerCoordinator)
                .tabItem {
                    Label("Provider", systemImage: "server.rack")
                }

            appearanceSettings
                .tabItem {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }

            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 520, height: 470)
    }

    private var appearanceSettings: some View {
        Form {
            Section("Тема") {
                Picker("Оформление", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text("Auto следует системной теме macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var shortcutSettings: some View {
        Form {
            Section("Глобальный хоткей") {
                LabeledContent("Показать или скрыть панель") {
                    ShortcutRecorder(
                        shortcut: settings.shortcut,
                        onShortcut: updateShortcut
                    )
                    .frame(width: 150)
                }

                Text("Нажмите поле, затем новое сочетание. Требуется Command, Control или Option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = hotKeyController.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func updateShortcut(_ shortcut: GlobalShortcut) {
        if hotKeyController.update(to: shortcut) {
            settings.shortcut = shortcut
        }
    }
}
