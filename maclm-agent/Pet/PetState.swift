import Foundation

enum PetState: String, Codable, CaseIterable, Sendable {
    case idle, running, toolRunning, needsApproval, ready, failed, drag, sleep

    var accessibilityTitle: String {
        switch self {
        case .idle: String(localized: "Питомец: ожидание")
        case .running: String(localized: "Питомец: генерация ответа")
        case .toolRunning: String(localized: "Питомец: выполняется инструмент")
        case .needsApproval: String(localized: "Питомец: нужно подтверждение")
        case .ready: String(localized: "Питомец: результат готов")
        case .failed: String(localized: "Питомец: ошибка")
        case .drag: String(localized: "Питомец: перетаскивание")
        case .sleep: String(localized: "Питомец: сон")
        }
    }

    static func mapped(_ kind: AggregateStatus.Kind) -> Self {
        switch kind {
        case .needsApproval: .needsApproval
        case .failed: .failed
        case .toolRunning: .toolRunning
        case .running: .running
        case .ready: .ready
        case .idle: .idle
        }
    }

    static func conversationID(for aggregate: AggregateStatus) -> UUID? {
        switch aggregate.kind {
        case .needsApproval: aggregate.needsApproval.first
        case .failed: aggregate.failed.first
        case .toolRunning: aggregate.toolRunning.first
        case .running: aggregate.running.first
        case .ready: aggregate.ready.first
        case .idle: nil
        }
    }
}

/// Monotonic clock; dragging overrides presentation without interrupting continuous idle.
struct PetStateMachine {
    private let now: () -> TimeInterval
    private(set) var idleSince: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    mutating func update(kind: AggregateStatus.Kind, dragging: Bool) -> PetState {
        let time = now()
        if kind == .idle {
            if idleSince == nil {
                idleSince = time
            }
        } else {
            idleSince = nil
        }
        if dragging {
            return .drag
        }
        if let idleSince, time - idleSince >= 300 {
            return .sleep
        }
        return PetState.mapped(kind)
    }

    var sleepDelay: TimeInterval? {
        idleSince.map { max(0, 300 - (now() - $0)) }
    }

    static func available(_ state: PetState, in states: Set<PetState>) -> PetState {
        states.contains(state) ? state : .idle
    }
}

enum PetCommand {
    static func matches(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == "/pet"
    }
}
