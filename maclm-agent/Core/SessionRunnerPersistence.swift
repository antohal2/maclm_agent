import Foundation
import SwiftData

extension SessionRunner {
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
