import Foundation

actor AgentLoop {
    private var isGenerating = false

    func streamResponse(
        to messages: [ChatMessage],
        using provider: any LLMProvider,
        onEvent: @escaping @Sendable (ChatStreamEvent) async -> Void
    ) async throws {
        guard !isGenerating else {
            throw AgentLoopError.alreadyGenerating
        }

        isGenerating = true
        defer { isGenerating = false }

        for try await event in provider.streamChat(messages: messages, tools: []) {
            await onEvent(event)
        }
    }
}

enum AgentLoopError: Error, LocalizedError, Sendable {
    case alreadyGenerating

    var errorDescription: String? {
        switch self {
        case .alreadyGenerating:
            "Предыдущий ответ ещё генерируется."
        }
    }
}
