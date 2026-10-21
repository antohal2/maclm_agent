import Foundation

extension AgentLoop {
    func receiveTurn(
        history: [ChatMessage], provider: any LLMProvider, toolsEnabled: Bool,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AssistantTurn {
        var content = ""
        var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]
        await onEvent(.contextRequestStarted)
        for try await event in provider.streamChat(
            messages: history,
            tools: toolsEnabled ? toolRegistry.definitions : []
        ) {
            switch event {
            case let .contentDelta(delta):
                content += delta
                await onEvent(.contentDelta(delta))
            case let .toolCallDelta(delta):
                toolCallAccumulators[delta.index, default: ToolCallAccumulator()]
                    .append(delta)
            case let .usage(prompt, completion):
                await onEvent(.usage(promptTokens: prompt, completionTokens: completion))
            case .done:
                break
            }
        }
        return AssistantTurn(
            content: content,
            toolCalls: (toolsEnabled ? toolCallAccumulators : [:])
                .sorted { $0.key < $1.key }
                .map(\.value.chatToolCall)
        )
    }
}
