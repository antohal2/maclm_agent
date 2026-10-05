import Foundation

struct ToolConfirmation {
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

struct AssistantTurn {
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
    case toolExecutionStarted(toolName: String)
    case toolCallsCompleted([AgentToolCallExecution])
    case done
}

struct AgentToolCallExecution: Equatable, Sendable {
    var persistentCallID: UUID?
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

struct ToolCallAccumulator {
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
