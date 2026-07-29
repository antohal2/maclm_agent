import Foundation

actor AgentLoop {
    private let toolRegistry: ToolRegistry
    private let maximumIterations: Int
    private var isGenerating = false

    init(
        toolRegistry: ToolRegistry = .readOnly,
        maximumIterations: Int = 8
    ) {
        self.toolRegistry = toolRegistry
        self.maximumIterations = max(1, maximumIterations)
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
                let result = try await execute(toolCall)
                executions.append(
                    AgentToolCallExecution(
                        toolCall: toolCall,
                        result: result
                    )
                )
                history.append(
                    ChatMessage(
                        role: .tool,
                        content: result.content,
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

    private func execute(_ toolCall: ChatToolCall) async throws -> ToolExecutionResult {
        guard let tool = toolRegistry.tool(named: toolCall.function.name) else {
            return .failure("Unknown tool: \(toolCall.function.name)")
        }
        guard tool.riskLevel == .safe else {
            return .failure("Tool is not allowed without confirmation: \(tool.name)")
        }
        guard
            let data = toolCall.function.arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let arguments = object as? [String: Any]
        else {
            return .failure(
                "Invalid JSON arguments for \(tool.name): \(toolCall.function.arguments)"
            )
        }

        do {
            return try await tool.execute(arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("Tool \(tool.name) failed: \(error.localizedDescription)")
        }
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
    case toolCallsCompleted([AgentToolCallExecution])
    case done
}

struct AgentToolCallExecution: Equatable, Sendable {
    let toolCall: ChatToolCall
    let result: ToolExecutionResult
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
