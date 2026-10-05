import Foundation
import SwiftData

@MainActor
final class AutoTitleService {
    private let context: ModelContext
    private let titleTimeout: Duration
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var titleTimeouts: [UUID: Task<Void, Never>] = [:]
    private var titleTokens: [UUID: UUID] = [:]

    init(context: ModelContext, timeout: Duration = .seconds(20)) {
        self.context = context
        titleTimeout = timeout
    }

    func hasRequest(for id: UUID) -> Bool {
        titleTokens[id] != nil
    }

    func applyFallbackTitle(_ conversation: Conversation) {
        guard !conversation.titleIsManual, conversation.title == Conversation.defaultTitle,
              let user = conversation.orderedMessages.first(where: { $0.role == .user }) else { return }
        conversation.title = ConversationTitle.fallback(user.content)
        saveContext()
    }

    func cancelTitle(for conversation: Conversation) {
        guard titleTokens.removeValue(forKey: conversation.id) != nil else { return }
        titleTasks.removeValue(forKey: conversation.id)?.cancel()
        titleTimeouts.removeValue(forKey: conversation.id)?.cancel()
        if !conversation.titleIsManual, conversation.title == Conversation.defaultTitle {
            conversation.title = ConversationTitle.fallback(
                conversation.orderedMessages.first(where: { $0.role == .user })?.content ?? ""
            )
            saveContext()
        }
    }

    func requestTitle(conversationID: UUID?, provider: any LLMProvider) {
        guard let conversationID else { return }
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationID })
        guard let conversation = try? context.fetch(descriptor).first,
              !conversation.titleIsManual, conversation.title == Conversation.defaultTitle,
              conversation.orderedMessages.filter({ $0.role == .user }).count == 1,
              let user = conversation.orderedMessages.first(where: { $0.role == .user }),
              let answer = conversation.orderedMessages.last(where: { $0.role == .assistant }),
              !answer.content.isEmpty else { return }
        let token = UUID()
        titleTokens[conversationID] = token
        let request = [
            ChatMessage(role: .system, content: ConversationTitle.prompt),
            ChatMessage(role: .user, content: user.content + "\n\n" + String(answer.content.prefix(500))),
        ]
        titleTasks[conversationID] = Task { [weak self] in
            var title = ""
            do {
                for try await event in provider.streamChat(messages: request, tools: []) {
                    try Task.checkCancellation()
                    if case let .contentDelta(delta) = event {
                        title += delta
                    }
                }
                try Task.checkCancellation()
            } catch { title = "" }
            guard let self, self.titleTokens[conversationID] == token else { return }
            self.titleTokens.removeValue(forKey: conversationID)
            self.titleTimeouts.removeValue(forKey: conversationID)?.cancel()
            self.titleTasks.removeValue(forKey: conversationID)
            if !conversation.titleIsManual, conversation.title == Conversation.defaultTitle {
                let cleaned = ConversationTitle.clean(title)
                conversation.title = cleaned.isEmpty ? ConversationTitle.fallback(user.content) : cleaned
                self.saveContext()
            }
        }
        titleTimeouts[conversationID] = Task { [weak self] in
            do { try await Task.sleep(for: self?.titleTimeout ?? .seconds(20)) } catch { return }
            guard let self, self.titleTokens[conversationID] == token else { return }
            self.cancelTitle(for: conversation)
        }
    }

    private func saveContext() {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
