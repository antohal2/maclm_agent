import Foundation

actor AgentLoop {
    private let toolRegistry: ToolRegistry
    private let confirmationCoordinator: ConfirmationCoordinator
    private let sessionPermissions: SessionPermissions
    private var pendingConfirmations: [UUID: ConfirmationRequest] = [:]
    private let riskContext: @MainActor @Sendable () -> ToolRiskContext
    private let securityRules: @MainActor @Sendable () throws -> [SecurityRuleSnapshot]
    private let auditSink: @MainActor @Sendable (AuditRecord) throws -> Void
    private let maximumIterations: Int
    private var isGenerating = false

    init(
        toolRegistry: ToolRegistry = .all,
        confirmationCoordinator: ConfirmationCoordinator = ConfirmationCoordinator(),
        maximumIterations: Int = 8,
        sessionPermissions: SessionPermissions = SessionPermissions(),
        riskContext: @escaping @MainActor @Sendable () -> ToolRiskContext = {
            ToolRiskContext(allowedDirectories: AppSettings().allowedDirectories)
        },
        auditSink: @escaping @MainActor @Sendable (AuditRecord) throws -> Void = { _ in },
        securityRules: @escaping @MainActor @Sendable () throws -> [SecurityRuleSnapshot] = {
            DefaultSecurityRules.rules
        }
    ) {
        self.auditSink = auditSink
        self.sessionPermissions = sessionPermissions
        self.riskContext = riskContext
        self.securityRules = securityRules
        self.toolRegistry = toolRegistry
        self.confirmationCoordinator = confirmationCoordinator
        self.maximumIterations = max(1, maximumIterations)
    }

    func resolveConfirmation(
        requestID: UUID,
        decision: ConfirmationDecision,
        rememberForSession: Bool = false
    ) async {
        if decision == .approved, rememberForSession,
           let request = pendingConfirmations[requestID]
        {
            await sessionPermissions.remember(
                toolName: request.toolCall.function.name, riskLevel: request.riskLevel
            )
        }
        await confirmationCoordinator.resolve(
            requestID: requestID,
            decision: decision
        )
    }

    func streamResponse(
        to messages: [ChatMessage],
        using provider: any LLMProvider,
        conversationID: UUID? = nil,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws {
        guard !isGenerating else {
            throw AgentLoopError.alreadyGenerating
        }

        isGenerating = true
        defer { isGenerating = false }

        var history = messages

        for iteration in 0 ..< maximumIterations {
            if iteration > 0 {
                await onEvent(.assistantResponseStarted)
            }

            let turn = try await receiveTurn(
                history: history,
                provider: provider,
                onEvent: onEvent
            )
            guard !turn.toolCalls.isEmpty else {
                await onEvent(.done)
                return
            }

            history.append(
                ChatMessage(
                    role: .assistant,
                    content: turn.content,
                    toolCalls: turn.toolCalls
                )
            )

            var executions: [AgentToolCallExecution] = []
            for (index, toolCall) in turn.toolCalls.enumerated() {
                let execution: AgentToolCallExecution
                do {
                    execution = try await execute(toolCall, conversationID: conversationID, onEvent: onEvent)
                } catch is CancellationError {
                    // The model may request several calls in one turn. Record the remaining
                    // calls too; cancellation prevents them from reaching any tool.
                    for pending in turn.toolCalls.dropFirst(index + 1) {
                        do {
                            _ = try await execute(pending, conversationID: conversationID, onEvent: onEvent)
                        } catch is CancellationError {
                            continue
                        }
                    }
                    throw CancellationError()
                }
                executions.append(execution)
                history.append(
                    ChatMessage(
                        role: .tool,
                        content: execution.result.content,
                        toolCallID: toolCall.id
                    )
                )
            }
            await onEvent(.toolCallsCompleted(executions))

            if iteration == maximumIterations - 1 {
                await onEvent(.assistantResponseStarted)
                throw AgentLoopError.maximumIterationsReached(maximumIterations)
            }
        }
    }

    private func receiveTurn(
        history: [ChatMessage],
        provider: any LLMProvider,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AssistantTurn {
        var content = ""
        var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]

        for try await event in provider.streamChat(
            messages: history,
            tools: toolRegistry.definitions
        ) {
            switch event {
            case let .contentDelta(delta):
                content += delta
                await onEvent(.contentDelta(delta))
            case let .toolCallDelta(delta):
                toolCallAccumulators[delta.index, default: ToolCallAccumulator()]
                    .append(delta)
            case .done:
                break
            }
        }

        return AssistantTurn(
            content: content,
            toolCalls: toolCallAccumulators
                .sorted { $0.key < $1.key }
                .map(\.value.chatToolCall)
        )
    }

    private func execute(
        _ toolCall: ChatToolCall,
        conversationID: UUID?,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        var audit = AuditRecord(
            toolName: toolCall.function.name,
            argumentsJSON: AuditSanitizer.arguments(toolCall.function.arguments, toolName: toolCall.function.name),
            conversationID: conversationID
        )
        let execution: Result<AgentToolCallExecution, Error>
        do {
            execution = try await .success(executeAudited(toolCall, audit: &audit, onEvent: onEvent))
        } catch {
            if error is CancellationError {
                audit.outcome = .cancelled
                audit.errorDescription = "Cancelled by user"
            } else {
                audit.outcome = .failure
                audit.errorDescription = AuditSanitizer.truncate(error.localizedDescription)
            }
            execution = .failure(error)
        }
        try await auditSink(audit)
        return try execution.get()
    }

    private func executeAudited(
        _ toolCall: ChatToolCall,
        audit: inout AuditRecord,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        audit.outcome = .failure
        guard let tool = toolRegistry.tool(named: toolCall.function.name) else {
            audit.errorDescription = "Unknown tool: \(toolCall.function.name)"
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Unknown tool: \(toolCall.function.name)")
            )
        }
        guard
            let data = toolCall.function.arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let arguments = object as? [String: Any]
        else {
            audit.errorDescription = "Invalid JSON arguments"
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(
                    "Invalid JSON arguments for \(tool.name): \(toolCall.function.arguments)"
                )
            )
        }

        let context = await riskContext()
        var assessment = ToolRiskEvaluator.evaluate(tool, arguments: arguments, context: context)
        audit.riskLevel = assessment.level
        audit.elevationReason = assessment.reason
        let policy: SecurityPolicyEngine
        do {
            policy = try await SecurityPolicyEngine(rules: securityRules())
        } catch {
            audit.errorDescription = "Unable to load security rules: \(error.localizedDescription)"
            // A failed store read must never silently disable policy enforcement.
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Unable to load security rules: \(error.localizedDescription)")
            )
        }
        let executionArguments = policy.executionArguments(for: tool, arguments: arguments)
        assessment = ToolRiskEvaluator.evaluate(tool, arguments: executionArguments, context: context)
        audit.riskLevel = assessment.level
        audit.elevationReason = assessment.reason
        try Task.checkCancellation()
        let policyDecision = policy.decision(for: tool, arguments: arguments)
        audit.matchedRuleDescription = policyDecision.explanation.map { AuditSanitizer.truncate($0) }
        guard policyDecision.isAllowed else {
            audit.decision = .blocked
            audit.outcome = .notExecuted
            audit.resultSummary = AuditSanitizer.truncate(policyDecision.explanation ?? "Blocked")
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(policyDecision.explanation ?? "Вызов запрещён правилом безопасности.")
            )
        }
        let confirmation = try await confirmIfNeeded(
            toolCall: toolCall,
            assessment: assessment,
            onEvent: onEvent
        )
        audit.decision = confirmation
            .requestID == nil ? .auto : (confirmation.decision == .approved ? .approved : .rejected)
        if let rejection = confirmation.rejection {
            audit.outcome = .notExecuted
            audit.resultSummary = "User rejected execution"
            return rejection
        }

        let started = ContinuousClock.now
        defer {
            let elapsed = started.duration(to: .now).components
            audit.durationMilliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let result = try await tool.execute(arguments: executionArguments, policy: policy)
            audit.outcome = result.isError ? .failure : .success
            let summary = AuditSanitizer.summary(result, toolName: tool.name, arguments: executionArguments)
            audit.resultSummary = summary.0
            audit.errorDescription = summary.1
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: result,
                confirmationDecision: confirmation.decision,
                confirmationRequestID: confirmation.requestID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            audit.outcome = .failure
            audit.errorDescription = AuditSanitizer.truncate(error.localizedDescription)
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Tool \(tool.name) failed: \(error.localizedDescription)"),
                confirmationDecision: confirmation.decision,
                confirmationRequestID: confirmation.requestID
            )
        }
    }

    private func confirmIfNeeded(
        toolCall: ChatToolCall,
        assessment: RiskAssessment,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> ToolConfirmation {
        guard assessment.level.requiresConfirmation else {
            return ToolConfirmation()
        }

        if await sessionPermissions.allows(toolName: toolCall.function.name, riskLevel: assessment.level) {
            return ToolConfirmation(decision: .approved)
        }

        let request = ConfirmationRequest(
            toolCall: toolCall,
            riskLevel: assessment.level,
            riskReason: assessment.reason
        )
        pendingConfirmations[request.id] = request
        defer { pendingConfirmations.removeValue(forKey: request.id) }
        await onEvent(.confirmationRequested(request))
        let decision = try await confirmationCoordinator.waitForDecision(
            requestID: request.id
        )
        try Task.checkCancellation()
        guard decision == .approved else {
            return ToolConfirmation(
                decision: decision,
                requestID: request.id,
                rejection: AgentToolCallExecution(
                    toolCall: toolCall,
                    result: .failure(
                        "User rejected execution of tool '\(toolCall.function.name)'. "
                            + "Do not retry it without a new explicit request."
                    ),
                    confirmationDecision: decision,
                    confirmationRequestID: request.id
                )
            )
        }
        return ToolConfirmation(decision: decision, requestID: request.id)
    }
}

private struct ToolConfirmation {
    let decision: ConfirmationDecision?
    let requestID: UUID?
    let rejection: AgentToolCallExecution?

    init(
        decision: ConfirmationDecision? = nil,
        requestID: UUID? = nil,
        rejection: AgentToolCallExecution? = nil
    ) {
        self.decision = decision
        self.requestID = requestID
        self.rejection = rejection
    }
}

private struct AssistantTurn {
    let content: String
    let toolCalls: [ChatToolCall]
}

enum AgentLoopError: Error, LocalizedError, Sendable {
    case alreadyGenerating
    case maximumIterationsReached(Int)

    var errorDescription: String? {
        switch self {
        case .alreadyGenerating:
            "Предыдущий ответ ещё генерируется."
        case let .maximumIterationsReached(limit):
            "Агент остановлен после \(limit) итераций вызова инструментов."
        }
    }
}

enum AgentLoopEvent: Equatable, Sendable {
    case assistantResponseStarted
    case contentDelta(String)
    case confirmationRequested(ConfirmationRequest)
    case toolCallsCompleted([AgentToolCallExecution])
    case done
}

struct AgentToolCallExecution: Equatable, Sendable {
    let toolCall: ChatToolCall
    let result: ToolExecutionResult
    let confirmationDecision: ConfirmationDecision?
    let confirmationRequestID: UUID?

    init(
        toolCall: ChatToolCall,
        result: ToolExecutionResult,
        confirmationDecision: ConfirmationDecision? = nil,
        confirmationRequestID: UUID? = nil
    ) {
        self.toolCall = toolCall
        self.result = result
        self.confirmationDecision = confirmationDecision
        self.confirmationRequestID = confirmationRequestID
    }
}

private struct ToolCallAccumulator {
    private var id: String?
    private var type: String?
    private var functionName = ""
    private var arguments = ""

    mutating func append(_ delta: ToolCallDelta) {
        if id == nil {
            id = delta.id
        }
        if type == nil {
            type = delta.type
        }
        if let name = delta.functionName {
            if functionName.isEmpty {
                functionName = name
            } else if name != functionName {
                functionName += name
            }
        }
        if let argumentsDelta = delta.argumentsDelta {
            arguments += argumentsDelta
        }
    }

    var chatToolCall: ChatToolCall {
        ChatToolCall(
            id: id ?? "call_\(UUID().uuidString)",
            type: type ?? "function",
            function: ChatToolFunction(
                name: functionName,
                arguments: arguments.isEmpty ? "{}" : arguments
            )
        )
    }
}
