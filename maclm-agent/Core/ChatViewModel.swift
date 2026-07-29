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
    let providerCoordinator: ProviderCoordinator

    var selectedConversationID: UUID? {
        selectedConversation?.id
    }

    var canSend: Bool {
        selectedConversation != nil
            && !isGenerating
            && providerCoordinator.hasActiveProvider
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let modelContext: ModelContext
    private let agentLoop: AgentLoop
    private var generationTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        providerCoordinator: ProviderCoordinator = ProviderCoordinator(),
        agentLoop: AgentLoop = AgentLoop()
    ) {
        self.modelContext = modelContext
        self.providerCoordinator = providerCoordinator
        self.agentLoop = agentLoop
        restoreSelection()
    }

    func discoverProvidersIfNeeded() async {
        await providerCoordinator.discoverIfNeeded()
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
        do {
            let provider = try providerCoordinator.makeProvider()
            startGeneration(
                requestMessages: generation.requestMessages,
                assistantID: generation.assistantID,
                provider: provider
            )
        } catch {
            show(error: error, in: generation.assistantID)
            finishGeneration()
        }
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
        assistantID: UUID,
        provider: any LLMProvider
    ) {
        generationTask = Task { [weak self, agentLoop, requestMessages, provider] in
            do {
                try await agentLoop.streamResponse(
                    to: requestMessages,
                    using: provider
                ) { [weak self] event in
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

    private func consume(_ event: AgentLoopEvent, assistantID: UUID) {
        switch event {
        case .assistantResponseStarted:
            startAssistantResponse(after: assistantID)
        case let .contentDelta(delta):
            isWaitingForFirstToken = false
            updateMessage(id: generatingMessageID ?? assistantID) { message in
                message.content += delta
            }
        case let .toolCallsCompleted(executions):
            isWaitingForFirstToken = false
            persist(executions, assistantID: generatingMessageID ?? assistantID)
        case .done:
            isWaitingForFirstToken = false
            updateMessage(id: generatingMessageID ?? assistantID) { message in
                if message.content.isEmpty {
                    message.content = "LLM-сервер завершил ответ без текста."
                }
            }
        }
    }

    private func show(error: Error, in assistantID: UUID) {
        isWaitingForFirstToken = false
        updateMessage(id: generatingMessageID ?? assistantID) { message in
            message.content = "Ошибка: \(error.localizedDescription)"
        }
    }

    private func startAssistantResponse(after fallbackID: UUID) {
        guard
            let previousMessage = persistentMessage(id: generatingMessageID ?? fallbackID),
            let conversation = previousMessage.conversation
        else {
            return
        }

        let lastTimestamp = conversation.orderedMessages.last?.timestamp
            ?? previousMessage.timestamp
        let message = Message(
            role: .assistant,
            content: "",
            timestamp: lastTimestamp.addingTimeInterval(0.000_001),
            conversation: conversation
        )
        modelContext.insert(message)
        conversation.updatedAt = message.timestamp
        generatingMessageID = message.id
        isWaitingForFirstToken = true
        messages = conversation.orderedMessages
        saveContext()
    }

    private func persist(
        _ executions: [AgentToolCallExecution],
        assistantID: UUID
    ) {
        guard
            let assistantMessage = persistentMessage(id: assistantID),
            let conversation = assistantMessage.conversation
        else {
            return
        }

        var timestamp = assistantMessage.timestamp
        for execution in executions {
            timestamp = timestamp.addingTimeInterval(0.000_001)
            let toolCall = ToolCall(
                providerCallID: execution.toolCall.id,
                toolName: execution.toolCall.function.name,
                argumentsJSON: execution.toolCall.function.arguments,
                resultJSON: execution.result.displayContent ?? execution.result.content,
                status: execution.result.isError ? .failed : .completed,
                timestamp: timestamp,
                message: nil
            )
            modelContext.insert(toolCall)
            assistantMessage.toolCalls.append(toolCall)

            timestamp = timestamp.addingTimeInterval(0.000_001)
            let toolMessage = Message(
                role: .tool,
                content: execution.result.content,
                toolCallID: execution.toolCall.id,
                timestamp: timestamp,
                conversation: conversation
            )
            modelContext.insert(toolMessage)
        }

        conversation.updatedAt = timestamp
        messages = conversation.orderedMessages
        saveContext()
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
