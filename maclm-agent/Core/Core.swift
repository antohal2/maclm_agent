import Foundation

actor AgentLoop {
    private let toolRegistry: ToolRegistry
    private let confirmationCoordinator: ConfirmationCoordinator
    private let sessionPermissions: SessionPermissions
    private var pendingConfirmations: [UUID: ConfirmationRequest] = [:]
    private let riskContext: @MainActor @Sendable () -> ToolRiskContext
    private let securityRules: @MainActor @Sendable () throws -> [SecurityRuleSnapshot]
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
        securityRules: @escaping @MainActor @Sendable () throws -> [SecurityRuleSnapshot] = {
            DefaultSecurityRules.rules
        }
    ) {
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
           let request = pendingConfirmations[requestID] {
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
            for toolCall in turn.toolCalls {
                try Task.checkCancellation()
                let execution = try await execute(
                    toolCall,
                    onEvent: onEvent
                )
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
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        guard let tool = toolRegistry.tool(named: toolCall.function.name) else {
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
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(
                    "Invalid JSON arguments for \(tool.name): \(toolCall.function.arguments)"
                )
            )
        }

        let policy: SecurityPolicyEngine
        do {
            policy = try await SecurityPolicyEngine(rules: securityRules())
        } catch {
            // A failed store read must never silently disable policy enforcement.
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure("Unable to load security rules: \(error.localizedDescription)")
            )
        }
        let policyDecision = policy.decision(for: tool, arguments: arguments)
        guard policyDecision.isAllowed else {
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: .failure(policyDecision.explanation ?? "Вызов запрещён правилом безопасности.")
            )
        }
        let executionArguments = policy.executionArguments(for: tool, arguments: arguments)
        let context = await riskContext()
        let assessment = ToolRiskEvaluator.evaluate(tool, arguments: executionArguments, context: context)
        let confirmation = try await confirmIfNeeded(
            toolCall: toolCall,
            assessment: assessment,
            onEvent: onEvent
        )
        if let rejection = confirmation.rejection {
            return rejection
        }

        do {
            let result = try await tool.execute(arguments: executionArguments, policy: policy)
            return AgentToolCallExecution(
                toolCall: toolCall,
                result: result,
                confirmationDecision: confirmation.decision,
                confirmationRequestID: confirmation.requestID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
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
