import Foundation
import Observation
import SwiftData

enum SessionStatus: Equatable {
    case idle
    case running
    case toolRunning(toolName: String)
    case needsApproval(risk: RiskLevel)
    case failed(message: String)

    var title: String {
        switch self {
        case .idle: String(localized: "Ожидание")
        case .running: String(localized: "Генерация ответа")
        case let .toolRunning(name): String(localized: "Выполняется инструмент: \(name)")
        case .needsApproval: String(localized: "Нужно подтверждение")
        case .failed: String(localized: "Ошибка сессии")
        }
    }
}

struct AggregateStatus: Equatable {
    enum Kind: Equatable { case needsApproval, failed, toolRunning, running, ready, idle }
    let kind: Kind
    let needsApproval: [UUID]
    let failed: [UUID]
    let toolRunning: [UUID]
    let running: [UUID]
    let ready: [UUID]
    let idle: [UUID]

    init(statuses: [UUID: SessionStatus], unread: Set<UUID>) {
        func ids(_ predicate: (SessionStatus) -> Bool) -> [UUID] {
            statuses.filter { predicate($0.value) }.keys.sorted { $0.uuidString < $1.uuidString }
        }
        needsApproval = ids {
            if case .needsApproval = $0 {
                true
            } else {
                false
            }
        }
        failed = ids {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        toolRunning = ids {
            if case .toolRunning = $0 {
                true
            } else {
                false
            }
        }
        running = ids { $0 == .running }
        ready = unread.sorted { $0.uuidString < $1.uuidString }
        idle = ids { $0 == .idle }
        kind = !needsApproval.isEmpty ? .needsApproval : !failed.isEmpty ? .failed
            : !toolRunning.isEmpty ? .toolRunning : !running.isEmpty ? .running
            : !ready.isEmpty ? .ready : .idle
    }
}

@MainActor @Observable
final class SessionRunnerRegistry {
    private(set) var runners: [UUID: SessionRunner] = [:]
    var selectedConversationID: UUID?
    var onCompletion: ((Conversation, SessionStatus) -> Void)?
    var onApproval: ((Conversation, ConfirmationRequest) -> Void)?
    private let modelContext: ModelContext
    private let agentLoop: AgentLoop
    private let autoTitles: AutoTitleService
    private let providerFactory: () throws -> any LLMProvider
    private var stopping: [UUID: Int] = [:]
    private(set) var isShuttingDown = false

    init(
        modelContext: ModelContext,
        agentLoop: AgentLoop,
        autoTitles: AutoTitleService,
        providerFactory: @escaping () throws -> any LLMProvider
    ) {
        self.modelContext = modelContext
        self.agentLoop = agentLoop
        self.autoTitles = autoTitles
        self.providerFactory = providerFactory
    }

    var aggregate: AggregateStatus {
        let conversations = (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return AggregateStatus(
            statuses: runners.mapValues(\.status),
            unread: Set(conversations.filter(\.hasUnreadResult).map(\.id))
        )
    }

    func runner(for conversation: Conversation) -> SessionRunner {
        if let runner = runners[conversation.id] {
            return runner
        }
        let runner = SessionRunner(
            conversation: conversation,
            modelContext: modelContext,
            agentLoop: agentLoop.independentRun(),
            autoTitles: autoTitles,
            providerFactory: providerFactory
        )
        let id = conversation.id
        runner.canStart = { [weak self] in
            guard let self else { return false }
            return !self.isShuttingDown && self.stopping[id] == nil && self.runners[id] != nil
        }
        runner.onFinish = { [weak self] runner, cancelled in
            guard let self, !cancelled else { return }
            if self.selectedConversationID != runner.conversationID {
                runner.conversation.hasUnreadResult = true
                runner.saveContext()
            }
            self.onCompletion?(runner.conversation, runner.status)
        }
        runner.onApproval = { [weak self] conversation, request in self?.onApproval?(conversation, request) }
        runners[conversation.id] = runner
        return runner
    }

    func remove(_ id: UUID) {
        runners.removeValue(forKey: id)
    }

    func afterStopping(_ conversation: Conversation, action: @escaping () -> Void) {
        afterStopping([conversation], action: action)
    }

    func afterStopping(_ conversations: [Conversation], action: @escaping () -> Void) {
        let ids = Set(conversations.map(\.id))
        let active = ids.compactMap { runners[$0] }.filter(\.isGenerating)
        guard !active.isEmpty else { action(); return }
        for id in ids {
            stopping[id, default: 0] += 1
        }
        for runner in active {
            runner.cancel()
        }
        Task {
            for runner in active {
                await runner.waitUntilFinished()
            }
            action()
            for id in ids {
                if stopping[id] == 1 {
                    stopping.removeValue(forKey: id)
                } else {
                    stopping[id, default: 1] -= 1
                }
            }
        }
    }

    func cancelAllAndWait() async {
        isShuttingDown = true
        let all = Array(runners.values)
        for runner in all {
            runner.cancel()
            autoTitles.cancelTitle(for: runner.conversation)
        }
        for runner in all {
            await runner.waitUntilFinished()
        }
    }
}
