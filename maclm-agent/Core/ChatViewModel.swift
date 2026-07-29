import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ChatViewModel {
    var input = ""
    private(set) var selectedConversation: Conversation?
    private(set) var messages: [Message] = []
    private(set) var isGenerating = false
    private(set) var isWaitingForFirstToken = false
    private(set) var generatingMessageID: UUID?

    var selectedConversationID: UUID? {
        selectedConversation?.id
    }

    var canSend: Bool {
        selectedConversation != nil
            && !isGenerating
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let modelContext: ModelContext
    private let agentLoop: AgentLoop
    private var generationTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        agentLoop: AgentLoop = AgentLoop(provider: LMStudioProvider())
    ) {
        self.modelContext = modelContext
        self.agentLoop = agentLoop
        restoreSelection()
    }

    @discardableResult
    func createConversation() -> Conversation {
        let conversation = Conversation()
        modelContext.insert(conversation)
        saveContext()
        selectConversation(conversation)
        return conversation
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        messages = conversation.orderedMessages
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        conversation.title = trimmedTitle
        conversation.updatedAt = Date()
        saveContext()
    }

    func deleteConversation(_ conversation: Conversation) {
        if selectedConversationID == conversation.id {
            selectedConversation = nil
            messages = []
        }
        modelContext.delete(conversation)
        saveContext()
    }

    func ensureConversationSelected() {
        guard selectedConversation == nil else {
            return
        }
        restoreSelection()
    }

    func send() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !content.isEmpty,
            !isGenerating,
            let conversation = selectedConversation
        else {
            return
        }

        input = ""
        isGenerating = true
        isWaitingForFirstToken = true

        let generation = persistPrompt(content, in: conversation)
        generatingMessageID = generation.assistantID
        startGeneration(
            requestMessages: generation.requestMessages,
            assistantID: generation.assistantID
        )
    }

    private func persistPrompt(
        _ content: String,
        in conversation: Conversation
    ) -> (requestMessages: [ChatMessage], assistantID: UUID) {
        let previousMessages = conversation.orderedMessages
        let hasUserMessages = previousMessages.contains { $0.role == .user }
        let shouldGenerateTitle = !hasUserMessages
            && conversation.title == Conversation.defaultTitle
        if shouldGenerateTitle {
            conversation.title = Conversation.generatedTitle(from: content)
        }

        let lastTimestamp = previousMessages.last?.timestamp ?? .distantPast
        let userTimestamp = max(Date(), lastTimestamp.addingTimeInterval(0.000_001))
        let userMessage = Message(
            role: .user,
            content: content,
            timestamp: userTimestamp,
            conversation: conversation
        )
        modelContext.insert(userMessage)

        let requestMessages = previousMessages.map(\.chatMessage) + [userMessage.chatMessage]
        let assistantMessage = Message(
            role: .assistant,
            content: "",
            timestamp: userTimestamp.addingTimeInterval(0.000_001),
            conversation: conversation
        )
        modelContext.insert(assistantMessage)

        conversation.updatedAt = assistantMessage.timestamp
        messages = conversation.orderedMessages
        saveContext()

        return (requestMessages, assistantMessage.id)
    }

    private func startGeneration(
        requestMessages: [ChatMessage],
        assistantID: UUID
    ) {
        generationTask = Task { [weak self, agentLoop, requestMessages] in
            do {
                try await agentLoop.streamResponse(to: requestMessages) { [weak self] event in
                    await self?.consume(event, assistantID: assistantID)
                }
            } catch is CancellationError {
                self?.removeEmptyMessage(id: assistantID)
            } catch {
                self?.show(error: error, in: assistantID)
            }

            self?.finishGeneration()
        }
    }

    private func consume(_ event: ChatStreamEvent, assistantID: UUID) {
        switch event {
        case let .contentDelta(delta):
            isWaitingForFirstToken = false
            updateMessage(id: assistantID) { message in
                message.content += delta
            }
        case .toolCallDelta:
            // Tool execution and presentation are intentionally deferred to step 1.5.
            break
        case .done:
            isWaitingForFirstToken = false
            updateMessage(id: assistantID) { message in
                if message.content.isEmpty {
                    message.content = "LM Studio завершил ответ без текста."
                }
            }
        }
    }

    private func show(error: Error, in assistantID: UUID) {
        isWaitingForFirstToken = false
        updateMessage(id: assistantID) { message in
            message.content = "Ошибка: \(error.localizedDescription)"
        }
    }

    private func updateMessage(
        id: UUID,
        update: (Message) -> Void
    ) {
        guard let message = persistentMessage(id: id) else {
            return
        }

        update(message)
        message.conversation?.updatedAt = Date()
        saveContext()
    }

    private func removeEmptyMessage(id: UUID) {
        guard let message = persistentMessage(id: id), message.content.isEmpty else {
            return
        }

        modelContext.delete(message)
        if selectedConversationID == message.conversation?.id {
            messages.removeAll { $0.id == id }
        }
        saveContext()
    }

    private func persistentMessage(id: UUID) -> Message? {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.id == id
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func finishGeneration() {
        isGenerating = false
        isWaitingForFirstToken = false
        generatingMessageID = nil
        generationTask = nil
    }

    private func restoreSelection() {
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let conversation = try? modelContext.fetch(descriptor).first {
            selectConversation(conversation)
        } else {
            createConversation()
        }
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
