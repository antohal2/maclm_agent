import Foundation
import SwiftData

extension ChatViewModel {
    func togglePin(_ conversation: Conversation) {
        conversation.isPinned.toggle()
        saveContext()
    }

    func moveConversation(_ conversation: Conversation, to project: Project?) {
        conversation.project = project
        saveContext()
    }

    func saveProject(_ project: Project) {
        modelContext.insert(project)
        saveContext()
    }

    func persistentMessage(id: UUID) -> Message? {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.id == id
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func persistentToolCall(id: UUID) -> ToolCall? {
        let descriptor = FetchDescriptor<ToolCall>(
            predicate: #Predicate { toolCall in
                toolCall.id == id
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func restoreSelection() {
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let conversation = try? modelContext.fetch(descriptor).first {
            selectConversation(conversation)
        } else {
            createConversation()
        }
    }

    func saveContext() {
        do {
            try modelContext.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error.localizedDescription)")
        }
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        autoTitles.cancelTitle(for: conversation)
        conversation.titleIsManual = true
        conversation.title = trimmedTitle
        conversation.updatedAt = Date()
        saveContext()
    }

    func ensureConversationSelected() {
        guard selectedConversation == nil else {
            return
        }
        restoreSelection()
    }
}
