import SwiftData
import SwiftUI

@main
struct MacLMAgentApp: App {
    @NSApplicationDelegateAdaptor(SessionApplicationDelegate.self) private var applicationDelegate
    private let sessionNotifications: SessionNotifications
    private let sessionPermissions: SessionPermissions
    private let checkpointStore: CheckpointStore
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
            let container = try Self.makeContainer(testHost: testHost)
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let storeURL = container.configurations.first?.url
            else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            try Self.prepareStore(container: container, storeURL: storeURL, bundleID: bundleID)
            modelContainer = container
            let policyContext = container.mainContext
            let permissions = SessionPermissions()
            sessionPermissions = permissions
            let appSettings = AppSettings()
            let (checkpointService, checkpoints) = Self.makeCheckpoints(
                testHost: testHost, bundleID: bundleID, policyContext: policyContext
            )
            checkpointStore = checkpoints
            Self.scheduleCheckpointMaintenance(checkpoints: checkpoints, testHost: testHost)
            Self.scheduleAuditMaintenance(container: container, appSettings: appSettings)
            let viewModel = Self.makeViewModel(
                policyContext: policyContext, checkpointService: checkpointService, checkpoints: checkpoints,
                permissions: permissions, appSettings: appSettings
            )
            let accessibilityPermissionService = SystemAccessibilityPermissionService()
            self.accessibilityPermissionService = accessibilityPermissionService
            let clipboardActionRunner = Self.makeClipboardActionRunner(
                viewModel: viewModel, appSettings: appSettings,
                accessibilityPermissionService: accessibilityPermissionService
            )
            let globalHotKeyController = GlobalHotKeyController()
            let clipboardHotkeyService = ClipboardHotkeyService()
            let appSceneActions = SceneActions()
            _chatViewModel = State(initialValue: viewModel)
            _settings = State(initialValue: appSettings)
            _hotKeyController = State(initialValue: globalHotKeyController)
            _clipboardHotkeyService = State(initialValue: clipboardHotkeyService)
            sceneActions = appSceneActions
            sessionNotifications = .init(settings: appSettings, viewModel: viewModel, sceneActions: appSceneActions)
            menuBarController = MenuBarController(
                viewModel: viewModel, clipboardActionRunner: clipboardActionRunner,
                modelContainer: container, settings: appSettings,
                hotKeyController: globalHotKeyController, clipboardHotkeyService: clipboardHotkeyService,
                sceneActions: appSceneActions, accessibilityPermissionService: accessibilityPermissionService
            )
        } catch {
            Self.reportStartupFailure(error)
        }
    }

    private static func prepareStore(container: ModelContainer, storeURL: URL, bundleID: String) throws {
        try ApplicationProtection.ensure(context: container.mainContext, storeURL: storeURL, bundleID: bundleID)
        try ClipboardActionSeeder.seedIfNeeded(context: container.mainContext)
        try SecurityRuleSeeder.seedIfNeeded(context: container.mainContext)
    }

    private static func makeCheckpoints(
        testHost: Bool, bundleID: String, policyContext: ModelContext
    ) -> (CheckpointService, CheckpointStore) {
        let checkpointRoot = testHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("maclm-test-host-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Checkpoints")
        let checkpointService =
            CheckpointService(root: URL(fileURLWithPath: PathCanonicalizer.canonicalize(checkpointRoot.path)))
        let checkpoints = CheckpointStore(service: checkpointService, context: policyContext)
        return (checkpointService, checkpoints)
    }

    private static func scheduleCheckpointMaintenance(checkpoints: CheckpointStore, testHost: Bool) {
        if !testHost {
            Task { do { try await checkpoints.maintain() } catch { NSLog(
                "Checkpoint maintenance failed: %@",
                error.localizedDescription
            ) } }
        }
    }

    private static func makeViewModel(
        policyContext: ModelContext, checkpointService: CheckpointService, checkpoints: CheckpointStore,
        permissions: SessionPermissions, appSettings: AppSettings
    ) -> ChatViewModel {
        ChatViewModel(
            modelContext: policyContext,
            agentLoop: AgentLoop(checkpoints: checkpointService, checkpointSink: { value in
                try checkpoints.persist(value)
            }, checkpointMaintenance: {
                try await checkpoints.maintain()
            }, sessionPermissions: permissions, riskContext: {
                ToolRiskContext(allowedDirectories: appSettings.allowedDirectories)
            }, auditSink: { record in
                policyContext.insert(AuditEntry(record))
                try policyContext.save()
            }, securityRules: {
                try SecurityRuleSeeder.snapshots(context: policyContext)
            })
        )
    }

    private static func makeClipboardActionRunner(
        viewModel: ChatViewModel, appSettings: AppSettings,
        accessibilityPermissionService: SystemAccessibilityPermissionService
    ) -> ClipboardActionRunner {
        let pasteService = SystemPasteService(
            accessibilityPermissionService: accessibilityPermissionService
        )
        let frontmostApplicationService = SystemFrontmostApplicationService()
        return ClipboardActionRunner(
            providerSource: viewModel.providerCoordinator,
            preferences: appSettings,
            accessibilityPermissionService: accessibilityPermissionService,
            pasteService: pasteService,
            frontmostApplicationService: frontmostApplicationService
        )
    }

    private static func reportStartupFailure(_ error: Error) -> Never {
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

    private static func scheduleAuditMaintenance(container: ModelContainer, appSettings: AppSettings) {
        let retentionDays = appSettings.auditRetentionDays
        Task {
            let maintenance = await AuditMaintenance.background(container: container)
            do {
                try await maintenance.prune(days: retentionDays)
            } catch {
                NSLog("Audit retention failed: %@", error.localizedDescription)
            }
        }
    }

    private static func makeContainer(testHost: Bool) throws -> ModelContainer {
        try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            Checkpoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: testHost)
        )
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
        .environment(\.checkpointStore, checkpointStore)

        Window("Журнал аудита", id: "audit") {
            AuditLogView()
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .modelContainer(modelContainer)
        .environment(\.checkpointStore, checkpointStore)
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
            .environment(\.checkpointStore, checkpointStore)
            .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
