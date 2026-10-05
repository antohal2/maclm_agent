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

    let modelContext: ModelContext
    private let agentLoop: AgentLoop
    let autoTitles: AutoTitleService
    private let providerFactory: (() throws -> any LLMProvider)?
    private(set) var generatingConversationID: UUID?
    private var generationToken: UUID?
    private var deferredDeletions: [Conversation] = []
    private var deferredProjectDeletions: [Project] = []
    private var generationTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        providerCoordinator: ProviderCoordinator = ProviderCoordinator(),
        agentLoop: AgentLoop = AgentLoop(),
        providerFactory: (() throws -> any LLMProvider)? = nil,
        titleTimeout: Duration = .seconds(20)
    ) {
        self.modelContext = modelContext
        self.providerCoordinator = providerCoordinator
        self.agentLoop = agentLoop
        autoTitles = AutoTitleService(context: modelContext, timeout: titleTimeout)
        self.providerFactory = providerFactory
        restoreSelection()
    }

    func discoverProvidersIfNeeded() async {
        await providerCoordinator.discoverIfNeeded()
    }

    @discardableResult
    func createConversation(project: Project? = nil) -> Conversation {
        let conversation = Conversation()
        conversation.project = project
        modelContext.insert(conversation)
        saveContext()
        selectConversation(conversation)
        return conversation
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        messages = conversation.orderedMessages
    }

    func toggleArchive(_ conversation: Conversation) {
        if generatingConversationID == conversation.id {
            stopGeneration()
        }
        conversation.isArchived.toggle()
        saveContext()
    }

    func deleteProject(_ project: Project, includingConversations: Bool = false) {
        let sessions = project.conversations
        if includingConversations {
            for conversation in sessions {
                deleteConversation(conversation)
            }
            if sessions.contains(where: { $0.id == generatingConversationID }) {
                deferredProjectDeletions.append(project)
                return
            }
        } else {
            for conversation in sessions {
                conversation.project = nil
            }
        }
        modelContext.delete(project)
        saveContext()
    }

    func deleteConversation(_ conversation: Conversation) {
        autoTitles.cancelTitle(for: conversation)
        if generatingConversationID == conversation.id {
            stopGeneration()
            if !deferredDeletions.contains(where: { $0.id == conversation.id }) {
                deferredDeletions.append(conversation)
            }
            return
        }
        removeConversation(conversation)
    }

    private func removeConversation(_ conversation: Conversation) {
        if selectedConversationID == conversation.id {
            selectedConversation = nil
            messages = []
        }
        modelContext.delete(conversation)
        saveContext()
        ensureConversationSelected()
    }

    func send() {
        let content = input
        guard
            ComposerRules.canSubmit(content),
            !isGenerating,
            let conversation = selectedConversation
        else {
            return
        }

        autoTitles.cancelTitle(for: conversation)
        input = ""
        generatingConversationID = conversation.id
        isGenerating = true
        isWaitingForFirstToken = true

        let generation = persistPrompt(content, in: conversation)
        generatingMessageID = generation.assistantID
        do {
            let provider = try providerFactory?() ?? providerCoordinator.makeProvider()
            startGeneration(
                requestMessages: generation.requestMessages,
                assistantID: generation.assistantID,
                provider: provider
            )
        } catch {
            show(error: error, in: generation.assistantID)
            autoTitles.applyFallbackTitle(conversation)
            finishGeneration()
        }
    }

    func stopGeneration() {
        guard isGenerating else { return }
        generationTask?.cancel()
        // Resolve visible requests as Reject as well as cancelling their waiter.
        let calls = generatingMessageID.flatMap { persistentMessage(id: $0) }?.toolCalls ?? []
        for call in calls where call.status == .pending {
            resolveConfirmation(toolCallID: call.id, decision: .rejected)
        }
    }

    func resolveConfirmation(
        toolCallID: UUID,
        decision: ConfirmationDecision,
        rememberForSession: Bool = false
    ) {
        guard
            let toolCall = persistentToolCall(id: toolCallID),
            toolCall.status == .pending
        else {
            return
        }

        toolCall.status = decision == .approved ? .approved : .rejected
        saveContext()

        Task { [agentLoop] in
            await agentLoop.resolveConfirmation(
                requestID: toolCallID,
                decision: decision,
                rememberForSession: rememberForSession
            )
        }
    }

    private func persistPrompt(
        _ content: String,
        in conversation: Conversation
    ) -> (requestMessages: [ChatMessage], assistantID: UUID) {
        let previousMessages = conversation.orderedMessages
        let lastTimestamp = previousMessages.last?.timestamp ?? .distantPast
        let userTimestamp = max(Date(), lastTimestamp.addingTimeInterval(0.000_001))
        let userMessage = Message(
            role: .user,
            content: content,
            timestamp: userTimestamp,
            conversation: conversation
        )
        modelContext.insert(userMessage)

        let prompt = SystemPromptBuilder.build(
            projectName: conversation.project?.name,
            instructions: conversation.project?.instructions ?? ""
        )
        let systemMessages = prompt.isEmpty ? [] : [ChatMessage(role: .system, content: prompt)]
        let requestMessages = systemMessages + previousMessages.map(\.chatMessage) + [userMessage.chatMessage]
        let assistantMessage = Message(
            role: .assistant,
            content: "",
            timestamp: userTimestamp.addingTimeInterval(0.000_001),
            conversation: conversation
        )
        modelContext.insert(assistantMessage)

        conversation.updatedAt = assistantMessage.timestamp
        if selectedConversationID == conversation.id {
            messages = conversation.orderedMessages
        }
        saveContext()

        return (requestMessages, assistantMessage.id)
    }

    private func startGeneration(
        requestMessages: [ChatMessage],
        assistantID: UUID,
        provider: any LLMProvider
    ) {
        let conversationID = generatingConversationID
        let token = UUID()
        generationToken = token
        generationTask = Task { [weak self, agentLoop, requestMessages, provider] in
            do {
                try await agentLoop.streamResponse(
                    to: requestMessages,
                    using: provider,
                    conversationID: conversationID
                ) { [weak self] event in
                    guard await self?.generationToken == token else { return }
                    await self?.consume(event, assistantID: assistantID)
                }
                try Task.checkCancellation()
                self?.autoTitles.requestTitle(conversationID: conversationID, provider: provider)
            } catch is CancellationError {
                self?.completeCancelledCalls()
                self?.removeEmptyMessage(id: self?.generatingMessageID ?? assistantID)
            } catch {
                if Task.isCancelled {
                    self?.completeCancelledCalls()
                    self?.removeEmptyMessage(id: self?.generatingMessageID ?? assistantID)
                } else {
                    self?.show(error: error, in: assistantID)
                }
            }

            if let self, self.generationToken == token {
                if let conversationID, !self.autoTitles.hasRequest(for: conversationID) {
                    let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationID })
                    if let conversation = try? self.modelContext.fetch(descriptor).first {
                        self.autoTitles.applyFallbackTitle(conversation)
                    }
                }
                self.finishGeneration()
            }
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
        case let .confirmationRequested(request):
            isWaitingForFirstToken = false
            persistConfirmation(
                request,
                assistantID: generatingMessageID ?? assistantID
            )
        case let .toolCallsCompleted(executions):
            isWaitingForFirstToken = false
            persist(executions, assistantID: generatingMessageID ?? assistantID)
        case .done:
            guard !Task.isCancelled else { return }
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
        if selectedConversationID == conversation.id {
            messages = conversation.orderedMessages
        }
        saveContext()
    }
}

private extension ChatViewModel {
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
            let toolCall: ToolCall
            if let pendingToolCall = confirmedToolCall(for: execution) {
                toolCall = pendingToolCall
                timestamp = max(timestamp, toolCall.timestamp)
            } else {
                timestamp = timestamp.addingTimeInterval(0.000_001)
                toolCall = ToolCall(
                    providerCallID: execution.toolCall.id,
                    toolName: execution.toolCall.function.name,
                    argumentsJSON: execution.toolCall.function.arguments,
                    timestamp: timestamp,
                    message: nil
                )
                modelContext.insert(toolCall)
                assistantMessage.toolCalls.append(toolCall)
            }

            toolCall.resultJSON = execution.result.displayContent ?? execution.result.content
            if execution.confirmationDecision == .rejected {
                toolCall.status = .rejected
            } else {
                toolCall.status = execution.result.isError ? .failed : .completed
            }

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
        if selectedConversationID == conversation.id {
            messages = conversation.orderedMessages
        }
        saveContext()
    }

    private func confirmedToolCall(
        for execution: AgentToolCallExecution
    ) -> ToolCall? {
        guard let requestID = execution.confirmationRequestID else {
            return nil
        }
        return persistentToolCall(id: requestID)
    }

    private func persistConfirmation(
        _ request: ConfirmationRequest,
        assistantID: UUID
    ) {
        guard
            persistentToolCall(id: request.id) == nil,
            let assistantMessage = persistentMessage(id: assistantID),
            let conversation = assistantMessage.conversation
        else {
            return
        }

        let lastTimestamp = conversation.orderedMessages.last?.timestamp
            ?? assistantMessage.timestamp
        let toolCall = ToolCall(
            id: request.id,
            providerCallID: request.toolCall.id,
            toolName: request.toolCall.function.name,
            argumentsJSON: request.toolCall.function.arguments,
            status: .pending,
            timestamp: lastTimestamp.addingTimeInterval(0.000_001),
            message: nil
        )
        toolCall.confirmationRiskRawValue = request.riskLevel.rawValue
        toolCall.confirmationRiskReason = request.riskReason
        modelContext.insert(toolCall)
        assistantMessage.toolCalls.append(toolCall)
        conversation.updatedAt = toolCall.timestamp
        if selectedConversationID == conversation.id {
            messages = conversation.orderedMessages
        }
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

    private func completeCancelledCalls() {
        guard let id = generatingMessageID, let message = persistentMessage(id: id) else { return }
        for call in message.toolCalls where call.resultJSON == nil {
            call.resultJSON = "Cancelled by user"
            call.status = .rejected
            if let conversation = message.conversation {
                modelContext.insert(Message(
                    role: .tool,
                    content: "Cancelled by user",
                    toolCallID: call.providerCallID,
                    timestamp: Date(),
                    conversation: conversation
                ))
            }
        }
        if selectedConversationID == message.conversation?.id {
            messages = message.conversation?.orderedMessages ?? []
        }
        saveContext()
    }

    private func removeEmptyMessage(id: UUID) {
        guard let message = persistentMessage(id: id), message.content.isEmpty, message.toolCalls.isEmpty else {
            return
        }

        modelContext.delete(message)
        if selectedConversationID == message.conversation?.id {
            messages.removeAll { $0.id == id }
        }
        saveContext()
    }

    private func finishGeneration() {
        generationToken = nil
        generatingConversationID = nil
        isGenerating = false
        isWaitingForFirstToken = false
        generatingMessageID = nil
        generationTask = nil
        let conversations = deferredDeletions
        deferredDeletions = []
        for conversation in conversations {
            removeConversation(conversation)
        }
        for project in deferredProjectDeletions {
            modelContext.delete(project)
        }
        deferredProjectDeletions = []
        saveContext()
    }
}
