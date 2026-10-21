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

    func persistPrompt(
        _ content: String,
        in conversation: Conversation
    ) -> (requestMessages: [ChatMessage], assistantID: UUID) {
        let previousMessages = conversation.orderedMessages
        let lastTimestamp = previousMessages.last?.timestamp ?? .distantPast
        let userTimestamp = max(Date(), lastTimestamp.addingTimeInterval(0.000_001))
        let userMessage = Message(
            role: .user,
            content: content,
            timestamp: userTimestamp,
            conversation: conversation
        )
        modelContext.insert(userMessage)

        let prompt = SystemPromptBuilder.build(
            projectName: conversation.project?.name,
            instructions: conversation.project?.instructions ?? ""
        )
        let systemMessages = prompt.isEmpty ? [] : [ChatMessage(role: .system, content: prompt)]
        let requestMessages = systemMessages + previousMessages.map(\.chatMessage) + [userMessage.chatMessage]
        let assistantMessage = Message(
            role: .assistant,
            content: "",
            timestamp: userTimestamp.addingTimeInterval(0.000_001),
            conversation: conversation
        )
        modelContext.insert(assistantMessage)

        conversation.updatedAt = assistantMessage.timestamp
        saveContext()

        return (requestMessages, assistantMessage.id)
    }

    func suggestSkill(_ name: String, reason: String) async -> String {
        guard let skills else { return "unavailable: no skill session" }
        do { return try await skills.suggest(name: name, reason: reason) } catch {
            skills.notices.append(error.localizedDescription)
            return "unavailable: skill verification or persistence failed"
        }
    }

    static func toolInvocation(for conversation: Conversation) -> ToolInvocationContext {
        ToolInvocationContext(conversationID: conversation.id, project: conversation.project.map {
            ProjectSecuritySnapshot(id: $0.id, workingDirectoryPath: $0.workingDirectoryPath)
        })
    }
}
