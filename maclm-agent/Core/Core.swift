import Foundation

actor AgentLoop {
    private let provider: any LLMProvider
    private var isGenerating = false

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    func streamResponse(
        to messages: [ChatMessage],
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
