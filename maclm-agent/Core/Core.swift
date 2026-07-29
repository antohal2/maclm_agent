import Foundation

actor AgentLoop {
    private let provider: any LLMProvider
    private var messages: [ChatMessage]
    private var isGenerating = false

    init(
        provider: any LLMProvider,
        initialMessages: [ChatMessage] = []
    ) {
        self.provider = provider
        messages = initialMessages
    }

    func send(
        _ content: String,
        onEvent: @escaping @Sendable (ChatStreamEvent) async -> Void
    ) async throws {
        guard !isGenerating else {
            throw AgentLoopError.alreadyGenerating
        }

        isGenerating = true
        defer { isGenerating = false }

        let userMessage = ChatMessage(role: .user, content: content)
        messages.append(userMessage)

        var assistantContent = ""
        for try await event in provider.streamChat(messages: messages, tools: []) {
            if case let .contentDelta(delta) = event {
                assistantContent += delta
            }
            await onEvent(event)
        }

        messages.append(ChatMessage(role: .assistant, content: assistantContent))
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
