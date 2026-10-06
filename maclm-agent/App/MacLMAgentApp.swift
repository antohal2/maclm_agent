import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        let runtime = applicationDelegate.runtime
        // App-owned state is injected into both scenes so they always observe
        // the same active conversation, draft, and streaming response.
        Window("maclm-agent", id: "main") {
            MainWindowView(
                viewModel: runtime.chatViewModel,
                sceneActions: runtime.sceneActions,
                sessionNotifications: runtime.sessionNotifications
            )
            .onAppear { applicationDelegate.registry = runtime.chatViewModel.registry }
            .preferredColorScheme(runtime.settings.theme.colorScheme)
        }
        .modelContainer(runtime.modelContainer)
        .environment(\.checkpointStore, runtime.checkpointStore)

        Window("Журнал аудита", id: "audit") {
            AuditLogView()
                .preferredColorScheme(runtime.settings.theme.colorScheme)
        }
        .modelContainer(runtime.modelContainer)
        .environment(\.checkpointStore, runtime.checkpointStore)
        .commands { AuditCommands() }

        Settings {
            SettingsView(
                providerCoordinator: runtime.chatViewModel.providerCoordinator,
                settings: runtime.settings,
                hotKeyController: runtime.hotKeyController,
                clipboardHotkeyService: runtime.clipboardHotkeyService,
                sessionPermissions: runtime.sessionPermissions,
                accessibilityPermissionService: runtime.accessibilityPermissionService
            )
            .modelContainer(runtime.modelContainer)
            .environment(\.checkpointStore, runtime.checkpointStore)
            .preferredColorScheme(runtime.settings.theme.colorScheme)
        }
    }
}
