import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SessionRunner {
    let conversation: Conversation
    var conversationID: UUID {
        conversation.id
    }

    var messages: [Message] {
        conversation.orderedMessages
    }

    private(set) var traceEndings: [UUID: TraceRunEnd] = [:]
    private(set) var lastRunCancelled = false
    private(set) var lastRunEndedAt: Date?
    var isRestoringCheckpoint = false
    private(set) var isGenerating = false
    private(set) var isWaitingForFirstToken = false
    private(set) var generatingMessageID: UUID?
    private(set) var status: SessionStatus = .idle
    let modelContext: ModelContext
    private let agentLoop: AgentLoop
    let autoTitles: AutoTitleService
    private let providerFactory: () throws -> any LLMProvider
    private var generationToken: UUID?
    private var generationTask: Task<Void, Never>?
    var toolsEnabled: () -> Bool = { true }
    var canStart: () -> Bool = { true }
    var onFinish: ((SessionRunner, Bool) -> Void)?
    var onApproval: ((Conversation, ConfirmationRequest) -> Void)?
    private var generatingConversationID: UUID? {
        conversation.id
    }

    init(
        conversation: Conversation,
        modelContext: ModelContext,
        agentLoop: AgentLoop,
        autoTitles: AutoTitleService,
        providerFactory: @escaping () throws -> any LLMProvider
    ) {
        self.conversation = conversation
        self.modelContext = modelContext
        self.agentLoop = agentLoop
        self.autoTitles = autoTitles
        self.providerFactory = providerFactory
    }

    func send(_ content: String) {
        guard canStart(), ComposerRules.canSubmit(content), !isRestoringCheckpoint, !isGenerating else { return }
        autoTitles.cancelTitle(for: conversation)
        isGenerating = true
        lastRunCancelled = false
        lastRunEndedAt = nil
        status = .running
        isWaitingForFirstToken = true
        let generation = persistPrompt(content, in: conversation)
        generatingMessageID = generation.assistantID
        do {
            let provider = try providerFactory()
            startGeneration(
                requestMessages: generation.requestMessages,
                assistantID: generation.assistantID,
                provider: provider
            )
        } catch {
            show(error: error, in: generation.assistantID)
            autoTitles.applyFallbackTitle(conversation)
            finishGeneration(cancelled: false)
        }
    }

    func retry(after user: Message) {
        guard !isGenerating, !isRestoringCheckpoint, canStart(), user.role == .user,
              !messages.flatMap(\.toolCalls).contains(where: { $0.status == .pending || $0.status == .approved }),
              let index = messages.firstIndex(where: { $0.id == user.id }) else { return }
        autoTitles.cancelTitle(for: conversation)
        let history = Array(messages.prefix(index + 1))
        traceEndings = traceEndings.filter { key, _ in history.contains { $0.id == key } }
        traceEndings.removeValue(forKey: user.id)
        for message in messages.dropFirst(index + 1) {
            modelContext.delete(message)
        }
        let assistant = Message(role: .assistant, content: "", timestamp: Date(), conversation: conversation)
        modelContext.insert(assistant)
        conversation.updatedAt = assistant.timestamp
        isGenerating = true
        lastRunCancelled = false
        lastRunEndedAt = nil
        status = .running
        isWaitingForFirstToken = true
        generatingMessageID = assistant.id
        saveContext()
        do {
            try startGeneration(
                requestMessages: history.map(\.chatMessage),
                assistantID: assistant.id,
                provider: providerFactory()
            )
        } catch {
            show(error: error, in: assistant.id)
            finishGeneration(cancelled: false)
        }
    }

    func cancel() {
        guard isGenerating else { return }
        generationTask?.cancel()
        let calls = generatingMessageID.flatMap { persistentMessage(id: $0) }?.toolCalls ?? []
        for call in calls where call.status == .pending {
            resolveApproval(id: call.id, decision: .rejected)
        }
    }

    func waitUntilFinished() async {
        await generationTask?.value
    }

    func resolveApproval(id: UUID, decision: ConfirmationDecision, rememberForSession: Bool = false) {
        guard isGenerating, let toolCall = persistentToolCall(id: id),
              toolCall.message?.conversation?.id == conversationID,
              toolCall.message?.id == generatingMessageID,
              toolCall.status == .pending else { return }
        toolCall.status = decision == .approved ? .approved : .rejected
        saveContext()
        Task { [agentLoop] in
            await agentLoop.resolveConfirmation(
                requestID: id,
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
        saveContext()

        return (requestMessages, assistantMessage.id)
    }

    private func startGeneration(
        requestMessages: [ChatMessage],
        assistantID: UUID,
        provider: any LLMProvider
    ) {
        let enabled = toolsEnabled()
        let conversationID = conversation.id
        let token = UUID()
        generationToken = token
        let conversation = self.conversation
        let invocationContext: @MainActor @Sendable () -> ToolInvocationContext = {
            let project = conversation.project
            return ToolInvocationContext(conversationID: conversationID, project: project.map {
                ProjectSecuritySnapshot(id: $0.id, workingDirectoryPath: $0.workingDirectoryPath)
            })
        }
        generationTask = Task { [weak self, agentLoop, requestMessages, provider] in
            do {
                try await agentLoop.streamResponse(
                    to: requestMessages,
                    using: provider,
                    toolsEnabled: enabled,
                    invocationContext: invocationContext
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
                if !self.autoTitles.hasRequest(for: conversationID) {
                    let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationID })
                    if let conversation = try? self.modelContext.fetch(descriptor).first {
                        self.autoTitles.applyFallbackTitle(conversation)
                    }
                }
                self.finishGeneration(cancelled: Task.isCancelled)
            }
        }
    }

    private func consume(_ event: AgentLoopEvent, assistantID: UUID) {
        switch event {
        case .contextRequestStarted:
            conversation.lastContextTokens = nil
            saveContext()
        case let .usage(prompt, completion):
            conversation.lastContextTokens = prompt + completion
            saveContext()
        case let .toolExecutionStarted(toolName):
            status = .toolRunning(toolName: toolName)
        case .assistantResponseStarted:
            status = .running
            startAssistantResponse(after: assistantID)
        case let .contentDelta(delta):
            isWaitingForFirstToken = false
            updateMessage(id: generatingMessageID ?? assistantID) { message in
                message.content += delta
            }
        case let .confirmationRequested(request):
            status = .needsApproval(risk: request.riskLevel)
            onApproval?(conversation, request)
            isWaitingForFirstToken = false
            persistConfirmation(
                request,
                assistantID: generatingMessageID ?? assistantID
            )
        case let .toolCallsCompleted(executions):
            status = .running
            isWaitingForFirstToken = false
            persist(executions, assistantID: generatingMessageID ?? assistantID)
        case .done:
            guard !Task.isCancelled else { return }
            isWaitingForFirstToken = false
            updateMessage(id: generatingMessageID ?? assistantID) { message in
                message.timestamp = Date()
                if message.content.isEmpty {
                    message.content = "LLM-сервер завершил ответ без текста."
                }
            }
        }
    }

    private func show(error: Error, in assistantID: UUID) {
        status = .failed(message: error.localizedDescription)
        isWaitingForFirstToken = false
        updateMessage(id: generatingMessageID ?? assistantID) { message in
            if message.toolCalls.isEmpty {
                message.timestamp = Date()
            }
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
        saveContext()
    }
}

extension SessionRunner {
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
                    id: execution.persistentCallID ?? UUID(),
                    providerCallID: execution.toolCall.id,
                    toolName: execution.toolCall.function.name,
                    argumentsJSON: execution.toolCall.function.arguments,
                    timestamp: timestamp,
                    message: nil
                )
                modelContext.insert(toolCall)
                assistantMessage.toolCalls.append(toolCall)
            }

            snapshotRisk(for: toolCall, conversation: conversation)
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
        saveContext()
    }

    private func snapshotRisk(for toolCall: ToolCall, conversation: Conversation) {
        if toolCall.confirmationRiskRawValue == nil {
            let id = conversation.id
            let name = toolCall.toolName
            let arguments = AuditSanitizer.arguments(toolCall.argumentsJSON, toolName: name)
            let records = (try? modelContext.fetch(FetchDescriptor<AuditEntry>(
                predicate: #Predicate { $0.conversationID == id && $0.toolName == name },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            ))) ?? []
            if let record = records.first(where: { $0.argumentsJSON == arguments }) {
                toolCall.confirmationRiskRawValue = record.riskRaw
                toolCall.confirmationRiskReason = record.elevationReason
            }
        }
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
        toolCall.filePreview = request.filePreview
        modelContext.insert(toolCall)
        assistantMessage.toolCalls.append(toolCall)
        conversation.updatedAt = toolCall.timestamp
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
        saveContext()
    }

    private func removeEmptyMessage(id: UUID) {
        guard let message = persistentMessage(id: id), message.content.isEmpty, message.toolCalls.isEmpty else {
            return
        }

        modelContext.delete(message)
        saveContext()
    }

    private func finishGeneration(cancelled: Bool) {
        lastRunCancelled = cancelled
        lastRunEndedAt = Date()
        if let user = messages.last(where: { $0.role == .user }) {
            let failed = if case .failed = status {
                true
            } else {
                false
            }
            traceEndings[user.id] = TraceRunEnd(timestamp: Date(), cancelled: cancelled, failed: failed)
        }
        generationToken = nil
        isGenerating = false
        isWaitingForFirstToken = false
        generatingMessageID = nil
        generationTask = nil
        if cancelled {
            status = .idle
        } else if case .failed = status {} else {
            status = .idle
        }
        saveContext()
        onFinish?(self, cancelled)
    }

    func persistentMessage(id: UUID) -> Message? {
        conversation.messages.first { $0.id == id }
    }

    func persistentToolCall(id: UUID) -> ToolCall? {
        conversation.messages.flatMap(\.toolCalls).first { $0.id == id }
    }

    func saveContext() {
        do {
            try modelContext.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
