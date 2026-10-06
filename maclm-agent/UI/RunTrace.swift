import Foundation

struct TraceRunEnd {
    let timestamp: Date
    let cancelled: Bool
    let failed: Bool
}

struct TraceTurn: Identifiable {
    var id: UUID {
        user.id
    }

    let user: Message
    var steps: [Message]
    var final: Message?
    var liveResponse: Message?
    var end: TraceRunEnd?
    var pendingCalls: [ToolCall] {
        steps.flatMap(\.toolCalls).filter { $0.status == .pending }
    }

    var calls: [ToolCall] {
        steps.flatMap(\.toolCalls)
    }

    func expandedSteps(isExpanded: Bool) -> [Message] {
        isExpanded ? steps : []
    }

    var stepCount: Int {
        calls.count
    }
}

enum RunTraceGrouping {
    /// Input is already chronological. A response carrying calls is never final,
    /// even when it also contains prose. Only the last call-free response is final.
    static func group(
        _ messages: [Message],
        active: Bool = false,
        failed: Bool = false,
        cancelled: Bool = false,
        endings: [UUID: TraceRunEnd] = [:]
    ) -> [TraceTurn] {
        var turns: [TraceTurn] = []
        for message in messages {
            if message.role == .user {
                turns.append(TraceTurn(user: message, steps: [], final: nil))
            } else if message.role == .assistant, !turns.isEmpty {
                turns[turns.count - 1].steps.append(message)
            }
        }
        for index in turns.indices {
            turns[index].end = endings[turns[index].id]
            let unfinished = (index == turns.count - 1 && (active || failed || cancelled))
                || turns[index].end?.cancelled == true || turns[index].end?.failed == true
            if index == turns.count - 1, active, let last = turns[index].steps.last, last.toolCalls.isEmpty {
                turns[index].liveResponse = turns[index].steps.removeLast()
            }
            if
                !unfinished, let last = turns[index].steps.last, last.toolCalls.isEmpty,
                !last.content.hasPrefix("Ошибка:") || turns[index].end?.failed == false
            {
                turns[index].final = turns[index].steps.removeLast()
            }
        }
        return turns
    }
}

struct TraceIncidents: Equatable {
    var rejected = 0
    var blocked = 0
    var dangerous = 0
    var errors = 0

    static func count(calls: [ToolCall], audits: [AuditEntry]) -> Self {
        // Prefer stable ToolCall ids; retain the legacy heuristic for old audit entries.
        var remaining = audits.sorted { $0.timestamp < $1.timestamp }
        var result = Self()
        for call in calls.sorted(by: { $0.timestamp < $1.timestamp }) {
            let arguments = AuditSanitizer.arguments(call.argumentsJSON, toolName: call.toolName)
            let exact = remaining.firstIndex { $0.toolCallID == call.id }
            let index = exact ?? remaining
                .firstIndex { $0.toolCallID == nil && $0.toolName == call.toolName && $0.argumentsJSON == arguments
                    && $0.timestamp >= (call.message?.timestamp ?? .distantPast)
                }
            let audit = index.map { remaining.remove(at: $0) }
            if audit?.decision == .blocked {
                result.blocked += 1
            } else if
                audit?
                .decision == .rejected || (call.status == .rejected && call.resultJSON != "Cancelled by user")
            {
                result.rejected += 1
            }
            if audit?.decision == .approved, audit?.riskLevel == .dangerous {
                result.dangerous += 1
            }
            if call.status == .failed, audit?.decision != .blocked {
                result.errors += 1
            }
        }
        return result
    }
}

/// Value snapshots retain String storage rather than concatenate full transcripts
/// on each SwiftUI update (especially expensive for large tool results).
struct TraceCallRevision: Equatable {
    let id: UUID
    let status: ToolCallStatus
    let result: String?
    let risk: Int?
    init(_ call: ToolCall) {
        id = call.id
        status = call.status
        result = call.resultJSON
        risk = call.confirmationRiskRawValue
    }
}

struct TraceMessageRevision: Equatable {
    let id: UUID
    let content: String
    let calls: [TraceCallRevision]
    init(_ message: Message) {
        id = message.id
        content = message.content
        calls = message.toolCalls.map(TraceCallRevision.init)
    }
}

struct TraceRevision: Equatable {
    let conversationID: UUID?
    let active: Bool
    let cancelled: Bool
    let status: String
    let messages: [TraceMessageRevision]
}
