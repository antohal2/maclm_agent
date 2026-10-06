import Foundation
import Observation
import SwiftData

struct PetBubbleRow: Identifiable {
    let id: UUID
    let title: String
    let state: PetState
    let tool: String?
    let request: ConfirmationRequest?

    static func orderedIDs(_ aggregate: AggregateStatus) -> [UUID] {
        var seen: Set<UUID> = []
        return (aggregate.needsApproval + aggregate.failed + aggregate.toolRunning
            + aggregate.running + aggregate.ready).filter { seen.insert($0).inserted }
    }
}

@MainActor @Observable
final class PetBubbleModel {
    let viewModel: ChatViewModel
    let settings: AppSettings
    var rows: [PetBubbleRow] = []
    var maxListHeight: CGFloat = 640
    var listHeight: CGFloat {
        let visible = rows.prefix(8)
        let height = visible.map(rowHeight).reduce(0, +) + CGFloat(max(0, visible.count - 1) * 8)
        return min(maxListHeight, height)
    }

    func rowHeight(_ row: PetBubbleRow) -> CGFloat {
        if let request = row.request {
            return PetApprovalPolicy.allows(
                risk: request.riskLevel, source: .pet, hidden: settings.petHideContent
            ) ? 100 : settings.petHideContent ? 60 : 80
        }
        return settings.petHideContent || row.tool == nil ? 32 : 52
    }

    var input = ""
    var newChat = false
    @ObservationIgnored var onOpen: ((UUID?) -> Void)?
    @ObservationIgnored var onSent: (() -> Void)?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored var onResize: (() -> Void)?

    init(viewModel: ChatViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
    }

    var forcesNewChat: Bool {
        viewModel.quickChatRequiresNew || viewModel.selectedConversation == nil
    }

    var canSend: Bool {
        viewModel.canQuickSend(input, newChat: newChat || forcesNewChat)
    }

    func start() {
        let id = UUID()
        observationID = id
        observe(id)
    }

    func stop() {
        observationID = nil
        rows = []
    }

    private func observe(_ id: UUID) {
        guard observationID == id else { return }
        withObservationTracking {
            let aggregate = viewModel.registry.aggregate
            let conversations = (try? viewModel.modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
            let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            rows = PetBubbleRow.orderedIDs(aggregate).compactMap { uuid in
                guard let conversation = byID[uuid] else { return nil }
                let runner = viewModel.registry.runners[uuid]
                let state: PetState = if aggregate.needsApproval.contains(uuid) {
                    .needsApproval
                } else if aggregate.failed.contains(uuid) {
                    .failed
                } else if aggregate.toolRunning.contains(uuid) {
                    .toolRunning
                } else if aggregate.running.contains(uuid) {
                    .running
                } else {
                    .ready
                }
                let tool: String? = if case let .toolRunning(name) = runner?.status {
                    name
                } else {
                    runner?.pendingApproval?.toolCall.function.name
                }
                return PetBubbleRow(
                    id: uuid, title: conversation.interfaceTitle, state: state,
                    tool: tool, request: runner?.pendingApproval
                )
            }
            _ = settings.petHideContent
            _ = viewModel.selectedConversationID
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(id) }
        }
        onResize?()
    }

    func resolve(_ row: PetBubbleRow, decision: ConfirmationDecision) {
        guard let request = row.request, let runner = viewModel.registry.runners[row.id] else { return }
        runner.petContentHidden = { [weak settings] in settings?.petHideContent ?? true }
        runner.resolveApproval(id: request.id, decision: decision, source: .pet)
    }

    @discardableResult
    func send() -> Bool {
        guard viewModel.quickSend(input, newChat: newChat || forcesNewChat) else { return false }
        input = ""
        onSent?()
        return true
    }
}
