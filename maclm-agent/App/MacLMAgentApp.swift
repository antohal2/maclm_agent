import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    private let modelContainer: ModelContainer
    private let menuBarController: MenuBarController
    private let sceneActions: SceneActions
    private let accessibilityPermissionService: SystemAccessibilityPermissionService
    @State private var chatViewModel: ChatViewModel
    @State private var settings: AppSettings
    @State private var hotKeyController: GlobalHotKeyController
    @State private var clipboardHotkeyService: ClipboardHotkeyService

    init() {
        do {
            let container = try ModelContainer(
                for: Conversation.self,
                Message.self,
                ToolCall.self,
                ClipboardAction.self
            )
            try ClipboardActionSeeder.seedIfNeeded(context: container.mainContext)
            modelContainer = container
            let viewModel = ChatViewModel(modelContext: container.mainContext)
            let appSettings = AppSettings()
            let accessibilityPermissionService = SystemAccessibilityPermissionService()
            self.accessibilityPermissionService = accessibilityPermissionService
            let pasteService = SystemPasteService(
                accessibilityPermissionService: accessibilityPermissionService
            )
            let frontmostApplicationService = SystemFrontmostApplicationService()
            let clipboardActionRunner = ClipboardActionRunner(
                providerSource: viewModel.providerCoordinator,
                preferences: appSettings,
                accessibilityPermissionService: accessibilityPermissionService,
                pasteService: pasteService,
                frontmostApplicationService: frontmostApplicationService
            )
            let globalHotKeyController = GlobalHotKeyController()
            let clipboardHotkeyService = ClipboardHotkeyService()
            let appSceneActions = SceneActions()
            _chatViewModel = State(initialValue: viewModel)
            _settings = State(initialValue: appSettings)
            _hotKeyController = State(initialValue: globalHotKeyController)
            _clipboardHotkeyService = State(initialValue: clipboardHotkeyService)
            sceneActions = appSceneActions
            menuBarController = MenuBarController(
                viewModel: viewModel,
                clipboardActionRunner: clipboardActionRunner,
                modelContainer: container,
                settings: appSettings,
                hotKeyController: globalHotKeyController,
                clipboardHotkeyService: clipboardHotkeyService,
                sceneActions: appSceneActions,
                accessibilityPermissionService: accessibilityPermissionService
            )
        } catch {
            fatalError("Unable to initialize SwiftData: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        // App-owned state is injected into both scenes so they always observe
        // the same active conversation, draft, and streaming response.
        Window("maclm-agent", id: "main") {
            MainWindowView(
                viewModel: chatViewModel,
                sceneActions: sceneActions
            )
            .preferredColorScheme(settings.theme.colorScheme)
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView(
                providerCoordinator: chatViewModel.providerCoordinator,
                settings: settings,
                hotKeyController: hotKeyController,
                clipboardHotkeyService: clipboardHotkeyService,
                accessibilityPermissionService: accessibilityPermissionService
            )
            .modelContainer(modelContainer)
            .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
