import AppKit
import SwiftData
import UserNotifications

@MainActor
final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let settings: AppSettings
    private let viewModel: ChatViewModel
    private let sceneActions: SceneActions
    var mainWindowIsVisible = false
    var mainWindowIsKey = false

    init(settings: AppSettings, viewModel: ChatViewModel, sceneActions: SceneActions) {
        self.settings = settings
        self.viewModel = viewModel
        self.sceneActions = sceneActions
        super.init()
        center.delegate = self
        viewModel.registry.onCompletion = { [weak self] conversation, status in
            guard let self, self.settings.notifySessionCompletion, !self.isVisible(conversation) else { return }
            let body = if case .failed = status {
                String(localized: "Ошибка")
            } else {
                String(localized: "Готово")
            }
            self.post(conversation, body: body)
        }
        viewModel.registry.onApproval = { [weak self] conversation, request in
            guard let self, self.settings.notifySessionApproval, !self.isVisible(conversation) else { return }
            self.post(conversation, body: String(localized: "Нужно подтверждение: \(request.toolCall.function.name)"))
        }
    }

    func isVisible(_ conversation: Conversation) -> Bool {
        mainWindowIsVisible && mainWindowIsKey && NSApp.isActive
            && viewModel.selectedConversationID == conversation.id
    }

    static func requestPermission() {
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                NSLog("Notification authorization failed: %@", error.localizedDescription)
            }
        }
    }

    private func post(_ conversation: Conversation, body: String) {
        let content = Self.content(conversation, body: body)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Never prompt from a background event or at launch.
        Task {
            let authorization = await center.notificationSettings().authorizationStatus
            guard authorization == .authorized || authorization == .provisional else { return }
            do {
                try await center.add(request)
            } catch {
                NSLog("Session notification failed: %@", error.localizedDescription)
            }
        }
    }

    static func content(_ conversation: Conversation, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = conversation.interfaceTitle
        content.body = body
        content.sound = .default
        content.userInfo = ["conversationID": conversation.id.uuidString]
        return content
    }

    func openConversation(id: String?) {
        guard let id, let uuid = UUID(uuidString: id),
              let conversation = try? viewModel.modelContext.fetch(
                  FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == uuid })
              ).first else { return }
        viewModel.selectConversation(conversation)
        sceneActions.openMainWindow()
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["conversationID"] as? String
        Task { @MainActor [weak self] in
            self?.openConversation(id: id)
        }
        completionHandler()
    }
}

/// Delay termination until tool cancellation and audit writes have finished.
@MainActor
final class SessionApplicationDelegate: NSObject, NSApplicationDelegate {
    var registry: SessionRunnerRegistry?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let registry else { return .terminateNow }
        Task {
            await registry.cancelAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
