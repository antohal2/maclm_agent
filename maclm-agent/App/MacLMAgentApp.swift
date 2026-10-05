import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var applicationDelegate
    private let sessionNotifications: SessionNotifications
    private let sessionPermissions: SessionPermissions
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
            let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
            let container = try ModelContainer(
                for: Conversation.self,
                Project.self,
                Message.self,
                ToolCall.self,
                ClipboardAction.self,
                SecurityRule.self,
                AuditEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: testHost)
            )
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let storeURL = container.configurations.first?.url else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            try ApplicationProtection.ensure(context: container.mainContext, storeURL: storeURL, bundleID: bundleID)
            try ClipboardActionSeeder.seedIfNeeded(context: container.mainContext)
            try SecurityRuleSeeder.seedIfNeeded(context: container.mainContext)
            modelContainer = container
            let policyContext = container.mainContext
            let permissions = SessionPermissions()
            sessionPermissions = permissions
            let appSettings = AppSettings()
            let retentionDays = appSettings.auditRetentionDays
            Task {
                let maintenance = await AuditMaintenance.background(container: container)
                do {
                    try await maintenance.prune(days: retentionDays)
                } catch {
                    NSLog("Audit retention failed: %@", error.localizedDescription)
                }
            }
            let viewModel = ChatViewModel(
                modelContext: policyContext,
                agentLoop: AgentLoop(sessionPermissions: permissions, riskContext: {
                    ToolRiskContext(allowedDirectories: appSettings.allowedDirectories)
                }, auditSink: { record in
                    policyContext.insert(AuditEntry(record))
                    try policyContext.save()
                }, securityRules: {
                    try SecurityRuleSeeder.snapshots(context: policyContext)
                })
            )
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
            sessionNotifications = SessionNotifications(
                settings: appSettings,
                viewModel: viewModel,
                sceneActions: appSceneActions
            )
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
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "Не удалось запустить приложение")
            alert
                .informativeText =
                String(
                    localized: """
                    Не удалось открыть хранилище или обеспечить защиту данных: \
                    \(error.localizedDescription)
                    """
                )
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        // App-owned state is injected into both scenes so they always observe
        // the same active conversation, draft, and streaming response.
        Window("maclm-agent", id: "main") {
            MainWindowView(
                viewModel: chatViewModel,
                sceneActions: sceneActions,
                sessionNotifications: sessionNotifications
            )
            .onAppear { applicationDelegate.registry = chatViewModel.registry }
            .preferredColorScheme(settings.theme.colorScheme)
        }
        .modelContainer(modelContainer)

        Window("Журнал аудита", id: "audit") {
            AuditLogView()
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .modelContainer(modelContainer)
        .commands { AuditCommands() }

        Settings {
            SettingsView(
                providerCoordinator: chatViewModel.providerCoordinator,
                settings: settings,
                hotKeyController: hotKeyController,
                clipboardHotkeyService: clipboardHotkeyService,
                sessionPermissions: sessionPermissions,
                accessibilityPermissionService: accessibilityPermissionService
            )
            .modelContainer(modelContainer)
            .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
