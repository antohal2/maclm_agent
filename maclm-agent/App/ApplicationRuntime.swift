import SwiftData
import SwiftUI

@MainActor
final class ApplicationRuntime {
    let sessionNotifications: SessionNotifications
    let sessionPermissions: SessionPermissions
    let checkpointStore: CheckpointStore
    let modelContainer: ModelContainer
    let petLibrary: PetLibrary
    let petController: PetController
    let menuBarController: MenuBarController
    let sceneActions: SceneActions
    let accessibilityPermissionService: SystemAccessibilityPermissionService
    let chatViewModel: ChatViewModel
    let settings: AppSettings
    let hotKeyController: GlobalHotKeyController
    let clipboardHotkeyService: ClipboardHotkeyService

    init() {
        do {
            let testHost = Self.isTestHost
            let container = try Self.makeContainer(testHost: testHost)
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let storeURL = container.configurations.first?.url
            else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            try Self.prepareStore(container: container, storeURL: storeURL, bundleID: bundleID)
            modelContainer = container
            let policyContext = container.mainContext
            sessionPermissions = SessionPermissions()
            let appSettings = try Self.makeSettings(testHost: testHost)
            let (checkpointService, checkpoints) = Self.makeCheckpoints(
                testHost: testHost, bundleID: bundleID, policyContext: policyContext
            )
            checkpointStore = checkpoints
            Self.scheduleCheckpointMaintenance(checkpoints: checkpoints, testHost: testHost)
            Self.scheduleAuditMaintenance(container: container, appSettings: appSettings)
            let viewModel = Self.makeViewModel(
                policyContext: policyContext, checkpointService: checkpointService, checkpoints: checkpoints,
                permissions: sessionPermissions, appSettings: appSettings
            )
            accessibilityPermissionService = SystemAccessibilityPermissionService()
            let clipboardActionRunner = Self.makeClipboardActionRunner(
                viewModel: viewModel, appSettings: appSettings,
                accessibilityPermissionService: accessibilityPermissionService
            )
            let globalHotKeyController = GlobalHotKeyController()
            let clipboardHotkeyService = ClipboardHotkeyService()
            let appSceneActions = SceneActions()
            self.chatViewModel = viewModel
            self.settings = appSettings
            self.hotKeyController = globalHotKeyController
            self.clipboardHotkeyService = clipboardHotkeyService
            sceneActions = appSceneActions
            (petLibrary, petController) = Self.makePet(
                settings: appSettings, model: viewModel, actions: appSceneActions,
                bundleID: bundleID, testHost: testHost
            )
            sessionNotifications = Self.makeNotifications(appSettings, viewModel, appSceneActions, petController)
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

    private static func makeSettings(testHost: Bool) throws -> AppSettings {
        if !testHost {
            return AppSettings()
        }
        guard let defaults = UserDefaults(suiteName: "maclm-test-host-" + UUID().uuidString) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return AppSettings(defaults: defaults)
    }

    private static func makePet(
        settings: AppSettings, model: ChatViewModel, actions: SceneActions, bundleID: String, testHost: Bool
    ) -> (PetLibrary, PetController) {
        let root = testHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("pet-host-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Pets")
        let library = PetLibrary(settings: settings, store: PetStore(root: root))
        return (library, PetController(settings: settings, viewModel: model, sceneActions: actions, library: library))
    }

    private static func makeNotifications(
        _ settings: AppSettings, _ model: ChatViewModel, _ actions: SceneActions, _ pet: PetController
    ) -> SessionNotifications {
        SessionNotifications(settings: settings, viewModel: model, sceneActions: actions, petController: pet)
    }

    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
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
}
