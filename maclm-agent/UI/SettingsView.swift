import SwiftUI

struct SettingsView: View {
    @Bindable var providerCoordinator: ProviderCoordinator
    @Bindable var settings: AppSettings
    @Bindable var hotKeyController: GlobalHotKeyController
    @Bindable var clipboardHotkeyService: ClipboardHotkeyService
    let sessionPermissions: SessionPermissions
    let accessibilityPermissionService: any AccessibilityPermissionService

    @AppStorage("settings.selectedTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            shortcutSettings.tabItem { Label(String(localized: "Основные"), systemImage: "gearshape") }.tag("general")
            ProviderSettingsView(coordinator: providerCoordinator)
                .tabItem { Label(String(localized: "Модели"), systemImage: "server.rack") }.tag("models")
            SecuritySettingsView(settings: settings, sessionPermissions: sessionPermissions)
                .tabItem { Label(String(localized: "Безопасность"), systemImage: "shield") }.tag("security")
            ClipboardActionsSettingsView(
                settings: settings,
                clipboardHotkeyService: clipboardHotkeyService,
                accessibilityPermissionService: accessibilityPermissionService
            ).tabItem { Label(String(localized: "Буфер обмена"), systemImage: "clipboard") }.tag("clipboard")
            PetSettingsView(settings: settings)
                .tabItem { Label(String(localized: "Питомец"), systemImage: "pawprint") }.tag("pet")
            appearanceSettings
                .tabItem { Label(String(localized: "Внешний вид"), systemImage: "circle.lefthalf.filled") }
                .tag("appearance")
        }
        .frame(width: 900, height: 680)
    }

    private var appearanceSettings: some View {
        Form {
            Section(String(localized: "Тема")) {
                Picker(String(localized: "Оформление"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text(String(localized: "Auto следует системной теме macOS."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var shortcutSettings: some View {
        Form {
            Section(String(localized: "Язык интерфейса")) {
                Picker(String(localized: "Язык"), selection: $settings.interfaceLanguage) {
                    Text(String(localized: "Системный")).tag("system")
                    Text(verbatim: String(localized: "Русский")).tag("ru")
                    Text(verbatim: "English").tag("en")
                }
                Text(String(localized: "Применится после перезапуска")).font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Уведомления")) {
                Toggle(String(localized: "О завершении сессии"), isOn: $settings.notifySessionCompletion)
                Toggle(String(localized: "О запросе подтверждения"), isOn: $settings.notifySessionApproval)
                Button(String(localized: "Разрешить уведомления…")) { SessionNotifications.requestPermission() }
            }
            Section(String(localized: "Глобальный хоткей")) {
                LabeledContent(String(localized: "Показать или скрыть панель")) {
                    ShortcutRecorder(
                        shortcut: settings.shortcut,
                        onShortcut: updateShortcut
                    )
                    .frame(width: 150)
                }

                Text(String(localized: "Нажмите поле, затем новое сочетание. Требуется Command, Control или Option."))
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
        if hotKeyController.update(
            to: shortcut,
            conflictingWith: settings.clipboardActionShortcut
        ) {
            settings.shortcut = shortcut
        }
    }
}
