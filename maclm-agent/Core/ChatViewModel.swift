import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var input = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false
    private(set) var isWaitingForFirstToken = false

    var canSend: Bool {
        !isGenerating && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let agentLoop: AgentLoop
    private var generationTask: Task<Void, Never>?

    init(agentLoop: AgentLoop = AgentLoop(provider: LMStudioProvider())) {
        self.agentLoop = agentLoop
    }

    func send() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isGenerating else {
            return
        }

        input = ""
        isGenerating = true
        isWaitingForFirstToken = true

        messages.append(ChatMessage(role: .user, content: content))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))

        generationTask = Task { [weak self, agentLoop] in
            do {
                try await agentLoop.send(content) { [weak self] event in
                    await self?.consume(event, assistantID: assistantID)
                }
            } catch is CancellationError {
                self?.removeEmptyMessage(id: assistantID)
            } catch {
                self?.show(error: error, in: assistantID)
            }

            self?.isGenerating = false
            self?.isWaitingForFirstToken = false
        }
    }

    private func consume(_ event: ChatStreamEvent, assistantID: UUID) {
        switch event {
        case let .contentDelta(delta):
            isWaitingForFirstToken = false
            updateMessage(id: assistantID) { message in
                message.content += delta
            }
        case .toolCallDelta:
            // Tool execution and presentation are intentionally deferred to step 1.5.
            break
        case .done:
            isWaitingForFirstToken = false
            updateMessage(id: assistantID) { message in
                if message.content.isEmpty {
                    message.content = "LM Studio завершил ответ без текста."
                }
            }
        }
    }

    private func show(error: Error, in assistantID: UUID) {
        isWaitingForFirstToken = false
        updateMessage(id: assistantID) { message in
            message.content = "Ошибка: \(error.localizedDescription)"
        }
    }

    private func updateMessage(
        id: UUID,
        update: (inout ChatMessage) -> Void
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&messages[index])
    }

    private func removeEmptyMessage(id: UUID) {
        messages.removeAll { $0.id == id && $0.content.isEmpty }
    }
}
