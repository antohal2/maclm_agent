import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ChatViewModel {
    var input = ""
    var expandedTraceIDs: Set<UUID> = []
    private(set) var selectedConversation: Conversation?
    var messages: [Message] {
        selectedConversation?.orderedMessages ?? []
    }

    var isGenerating: Bool {
        currentRunner?.isGenerating ?? false
    }

    var isWaitingForFirstToken: Bool {
        currentRunner?.isWaitingForFirstToken ?? false
    }

    var generatingMessageID: UUID? {
        currentRunner?.generatingMessageID
    }

    let providerCoordinator: ProviderCoordinator

    var selectedConversationID: UUID? {
        selectedConversation?.id
    }

    var canSend: Bool {
        selectedConversation != nil
            && !isGenerating
            && providerCoordinator.hasActiveProvider
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let modelContext: ModelContext
    let autoTitles: AutoTitleService
    private var removedConversationIDs: Set<UUID> = []
    private var removedProjectIDs: Set<UUID> = []
    var savedProjectDirectories: [UUID: String] = [:]
    let sessionPermissions: SessionPermissions
    let registry: SessionRunnerRegistry
    var currentRunner: SessionRunner? {
        selectedConversationID.flatMap { registry.runners[$0] }
    }

    var generatingConversationID: UUID? {
        isGenerating ? selectedConversationID : nil
    }

    init(
        modelContext: ModelContext,
        providerCoordinator: ProviderCoordinator = ProviderCoordinator(),
        agentLoop: AgentLoop = AgentLoop(),
        providerFactory: (() throws -> any LLMProvider)? = nil,
        titleTimeout: Duration = .seconds(20)
    ) {
        self.modelContext = modelContext
        sessionPermissions = agentLoop.sessionPermissions
        self.providerCoordinator = providerCoordinator
        autoTitles = AutoTitleService(context: modelContext, timeout: titleTimeout)
        registry = SessionRunnerRegistry(
            modelContext: modelContext,
            agentLoop: agentLoop,
            autoTitles: autoTitles,
            providerFactory: { try providerFactory?() ?? providerCoordinator.makeProvider() }
        )
        for project in (try? modelContext.fetch(FetchDescriptor<Project>())) ?? [] {
            savedProjectDirectories[project.id] = project.workingDirectoryPath ?? ""
        }
        restoreSelection()
    }

    func discoverProvidersIfNeeded() async {
        await providerCoordinator.discoverIfNeeded()
    }

    @discardableResult
    func createConversation(project: Project? = nil) -> Conversation {
        let conversation = Conversation()
        conversation.project = project
        modelContext.insert(conversation)
        saveContext()
        selectConversation(conversation)
        return conversation
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        registry.selectedConversationID = conversation.id
        conversation.hasUnreadResult = false
        saveContext()
    }

    func toggleArchive(_ conversation: Conversation) {
        let id = conversation.id
        registry.afterStopping(conversation) { [weak self] in
            guard let self, !self.removedConversationIDs.contains(id) else { return }
            conversation.isArchived.toggle()
            self.saveContext()
        }
    }

    func deleteProject(_ project: Project, includingConversations: Bool = false) {
        if includingConversations {
            let projectID = project.id
            let sessions = project.conversations
            let sessionIDs = sessions.map(\.id)
            registry.afterStopping(sessions) { [weak self] in
                guard let self else { return }
                guard !self.removedProjectIDs.contains(projectID) else { return }
                for (conversation, id) in zip(sessions, sessionIDs) {
                    guard !self.removedConversationIDs.contains(id) else { continue }
                    self.autoTitles.cancelTitle(for: conversation)
                    self.registry.remove(id)
                    self.removeConversation(conversation, id: id)
                }
                self.removedProjectIDs.insert(projectID)
                self.modelContext.delete(project)
                self.saveContext()
            }
        } else {
            for conversation in project.conversations {
                sessionPermissions.reset(conversationID: conversation.id)
                conversation.project = nil
            }
            modelContext.delete(project)
            saveContext()
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        let id = conversation.id
        autoTitles.cancelTitle(for: conversation)
        registry.afterStopping(conversation) { [weak self] in
            guard let self else { return }
            self.registry.remove(id)
            self.removeConversation(conversation, id: id)
        }
    }

    private func removeConversation(_ conversation: Conversation, id: UUID) {
        guard removedConversationIDs.insert(id).inserted else { return }
        if selectedConversationID == id {
            selectedConversation = nil
            registry.selectedConversationID = nil
        }
        sessionPermissions.reset(conversationID: id)
        modelContext.delete(conversation)
        saveContext()
        ensureConversationSelected()
    }

    func send() {
        guard let conversation = selectedConversation, ComposerRules.canSubmit(input), !isGenerating else { return }
        let content = input
        input = ""
        registry.runner(for: conversation).send(content)
    }

    func stopGeneration() {
        currentRunner?.cancel()
    }

    func resolveConfirmation(toolCallID: UUID, decision: ConfirmationDecision, rememberForSession: Bool = false) {
        currentRunner?.resolveApproval(id: toolCallID, decision: decision, rememberForSession: rememberForSession)
    }
}
