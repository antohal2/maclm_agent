import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    private let modelContainer: ModelContainer
    private let menuBarController: MenuBarController
    private let sceneActions: SceneActions
    @State private var chatViewModel: ChatViewModel
    @State private var settings: AppSettings
    @State private var hotKeyController: GlobalHotKeyController

    init() {
        do {
            let container = try ModelContainer(
                for: Conversation.self,
                Message.self,
                ToolCall.self
            )
            modelContainer = container
            let viewModel = ChatViewModel(modelContext: container.mainContext)
            let appSettings = AppSettings()
            let globalHotKeyController = GlobalHotKeyController()
            let appSceneActions = SceneActions()
            _chatViewModel = State(initialValue: viewModel)
            _settings = State(initialValue: appSettings)
            _hotKeyController = State(initialValue: globalHotKeyController)
            sceneActions = appSceneActions
            menuBarController = MenuBarController(
                viewModel: viewModel,
                modelContainer: container,
                settings: appSettings,
                hotKeyController: globalHotKeyController,
                sceneActions: appSceneActions
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
                hotKeyController: hotKeyController
            )
            .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
