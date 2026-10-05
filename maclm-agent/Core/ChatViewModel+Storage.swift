import Foundation
import SwiftData

extension ChatViewModel {
    func togglePin(_ conversation: Conversation) {
        conversation.isPinned.toggle()
        saveContext()
    }

    func moveConversation(_ conversation: Conversation, to project: Project?) {
        if conversation.project?.id != project?.id {
            sessionPermissions.reset(conversationID: conversation.id)
        }
        conversation.project = project
        saveContext()
    }

    func resetProjectPermissions(_ project: Project) {
        for conversation in project.conversations {
            sessionPermissions.reset(conversationID: conversation.id)
        }
    }

    func saveProject(_ project: Project) {
        let path = project.workingDirectoryPath ?? ""
        if let previous = savedProjectDirectories[project.id], previous != path {
            resetProjectPermissions(project)
        }
        savedProjectDirectories[project.id] = path
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

extension ChatViewModel {
    var canRetryMessage: Bool {
        !isGenerating && !messages.flatMap(\.toolCalls).contains { $0.status == .pending || $0.status == .approved }
    }

    func retryMessage(_ message: Message) {
        guard canRetryMessage, let conversation = selectedConversation,
              message.conversation?.id == conversation.id else { return }
        registry.runner(for: conversation).retry(after: message)
    }

    @discardableResult
    func fork(at response: Message) -> Conversation? {
        guard let source = selectedConversation,
              let index = messages.firstIndex(where: { $0.id == response.id }),
              response.role == .assistant, response.toolCalls.isEmpty,
              RunTraceGrouping.group(messages, active: isGenerating, endings: currentRunner?.traceEndings ?? [:])
              .contains(where: { $0.final?.id == response.id })
        else { return nil }
        let branch = Conversation(title: source.title + String(localized: " — ветка"))
        branch.project = source.project
        branch.titleIsManual = true
        modelContext.insert(branch)
        for original in messages.prefix(index + 1) {
            let copy = Message(
                role: original.role,
                content: original.content,
                toolCallID: original.toolCallID,
                timestamp: original.timestamp,
                conversation: branch
            )
            modelContext.insert(copy)
            for call in original.toolCalls {
                let cloned = ToolCall(
                    providerCallID: call.providerCallID,
                    toolName: call.toolName,
                    argumentsJSON: call.argumentsJSON,
                    resultJSON: call.resultJSON,
                    status: call.status,
                    timestamp: call.timestamp,
                    message: copy
                )
                cloned.confirmationRiskRawValue = call.confirmationRiskRawValue
                cloned.confirmationRiskReason = call.confirmationRiskReason
                modelContext.insert(cloned)
            }
        }
        saveContext()
        selectConversation(branch)
        return branch
    }
}
