import Foundation
import SwiftData

enum AuditDecision: String, Codable, CaseIterable, Sendable { case approved, rejected, auto, blocked, userInitiated }
enum AuditOutcome: String, Codable, Sendable { case success, failure, cancelled, notExecuted }

@Model final class AuditEntry {
    var id: UUID = UUID()
    var timestamp: Date
    var toolName: String
    var argumentsJSON: String
    var riskRaw: Int
    var riskLevel: RiskLevel {
        get { RiskLevel(rawValue: riskRaw) ?? .dangerous }
        set { riskRaw = newValue.rawValue }
    }

    var elevationReason: String?
    var decisionRaw: String
    var decision: AuditDecision {
        get { AuditDecision(rawValue: decisionRaw) ?? .auto }
        set { decisionRaw = newValue.rawValue }
    }

    var matchedRuleDescription: String?
    var outcome: AuditOutcome
    var resultSummary: String
    var errorDescription: String?
    var durationMilliseconds: Int?
    var conversationID: UUID?
    var checkpointID: UUID? = nil
    var toolCallID: UUID? = nil

    init(_ record: AuditRecord) {
        id = record.id
        timestamp = record.timestamp
        toolName = record.toolName
        argumentsJSON = record.argumentsJSON
        riskRaw = record.riskLevel.rawValue
        elevationReason = record.elevationReason
        decisionRaw = record.decision.rawValue
        matchedRuleDescription = record.matchedRuleDescription
        outcome = record.outcome
        resultSummary = record.resultSummary
        errorDescription = record.errorDescription
        durationMilliseconds = record.durationMilliseconds
        conversationID = record.conversationID
        checkpointID = record.checkpointID
        toolCallID = record.toolCallID
    }

    var record: AuditRecord {
        AuditRecord(
            id: id,
            timestamp: timestamp,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            riskLevel: riskLevel,
            elevationReason: elevationReason,
            decision: decision,
            matchedRuleDescription: matchedRuleDescription,
            outcome: outcome,
            resultSummary: resultSummary,
            errorDescription: errorDescription,
            durationMilliseconds: durationMilliseconds,
            conversationID: conversationID,
            checkpointID: checkpointID,
            toolCallID: toolCallID
        )
    }
}

struct AuditRecord: Codable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var toolName: String
    var argumentsJSON: String
    var riskLevel: RiskLevel = .dangerous
    var elevationReason: String?
    var decision: AuditDecision = .auto
    var matchedRuleDescription: String?
    var outcome: AuditOutcome = .notExecuted
    var resultSummary = ""
    var errorDescription: String?
    var durationMilliseconds: Int?
    var conversationID: UUID?
    var checkpointID: UUID? = nil
    var toolCallID: UUID? = nil
}

enum AuditSanitizer {
    static let limit = 2000
    static let commandLimit = 10000

    static func truncate(_ value: String, limit: Int = limit) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n[truncated; original length: \(value.count) characters]"
    }

    static func arguments(_ raw: String, toolName: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return truncate(raw)
        }
        func sanitize(_ object: Any, key: String? = nil) -> Any {
            if let string = object as? String {
                return truncate(string, limit: toolName == "run_shell" && key == "command" ? commandLimit : limit)
            }
            if let dict = object as? [String: Any] {
                return dict.reduce(into: [String: Any]()) { $0[$1.key] = sanitize($1.value, key: $1.key) }
            }
            if let array = object as? [Any] {
                return array.map { sanitize($0) }
            }
            return object
        }
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: sanitize(object),
            options: [.sortedKeys, .fragmentsAllowed]
        ),
            let value = String(data: encoded, encoding: .utf8) else { return truncate(raw) }
        return value
    }

    static func summary(
        _ result: ToolExecutionResult,
        toolName: String,
        arguments: [String: Any]
    ) -> (String, String?) {
        if toolName == "read_file", !result.isError {
            return ("Read file: \(arguments["path"] as? String ?? "")\nSize: \(result.content.utf8.count) bytes", nil)
        }
        if toolName == "run_shell", let data = result.content.data(using: .utf8),
           let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = output["exitCode"] as? Int, let timedOut = output["timedOut"] as? Bool {
            var summary = "exitCode: \(code)\ntimedOut: \(timedOut)"
                + "\nstdout:\n\(truncate(output["stdout"] as? String ?? ""))"
                + "\nstderr:\n\(truncate(output["stderr"] as? String ?? ""))"
            if let note = output["lifecycleNote"] as? String {
                summary += "\n" + truncate(note)
            }
            return (
                summary,
                output["outputLimitExceeded"] as? Bool == true
                    ? "Shell command output limit exceeded"
                    : (timedOut ? "Shell command timeout" : (code != 0 ? "Shell exit code: \(code)" : nil))
            )
        }
        let summary = truncate(result.displayContent ?? result.content)
        return (summary, result.isError ? summary : nil)
    }
}

struct AuditFilter: Equatable, Sendable {
    var conversationID: UUID?
    var checkpointID: UUID? = nil
    var toolCallID: UUID? = nil
    var start: Date?
    var end: Date?
    var tool = ""
    var risk: RiskLevel?
    var decision: AuditDecision?
    var search = ""

    var predicate: Predicate<AuditEntry> {
        let start = start ?? .distantPast
        let end = end ?? .distantFuture
        let tool = tool
        let risk = risk?.rawValue ?? -1
        let decision = decision?.rawValue ?? ""
        let search = search
        let conversationID = conversationID
        let conversation = #Predicate<AuditEntry> { conversationID == nil || $0.conversationID == conversationID }
        let dates = #Predicate<AuditEntry> { $0.timestamp >= start && $0.timestamp <= end }
        let name = #Predicate<AuditEntry> { tool.isEmpty || $0.toolName == tool }
        let level = #Predicate<AuditEntry> { risk == -1 || $0.riskRaw == risk }
        let choice = #Predicate<AuditEntry> { decision.isEmpty || $0.decisionRaw == decision }
        let found = #Predicate<AuditEntry> {
            search.isEmpty || $0.toolName.localizedStandardContains(search)
                || $0.argumentsJSON.localizedStandardContains(search)
        }
        return #Predicate<AuditEntry> {
            dates.evaluate($0) && name.evaluate($0) && level.evaluate($0)
                && choice.evaluate($0) && found.evaluate($0) && conversation.evaluate($0)
        }
    }

    func page(context: ModelContext, offset: Int, limit: Int = 200) throws -> [AuditEntry] {
        var descriptor = FetchDescriptor<AuditEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try context.fetch(descriptor)
    }
}

@ModelActor actor AuditMaintenance {
    /// Construct the context off the main actor: SwiftData chooses its queue
    /// at initialization, not when a model-actor method is later awaited.
    static func background(container: ModelContainer) async -> AuditMaintenance {
        await Task.detached { AuditMaintenance(modelContainer: container) }.value
    }

    func prune(days: Int, now: Date = Date()) throws {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        try modelContext.delete(model: AuditEntry.self, where: #Predicate { $0.timestamp < cutoff })
        try modelContext.save()
    }

    func clear() throws {
        try modelContext.delete(model: AuditEntry.self)
        try modelContext.save()
    }

    func export(filter: AuditFilter, to url: URL) throws -> Int {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".audit-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var count = 0
        while true {
            let pageContext = ModelContext(modelContainer)
            let entries = try filter.page(context: pageContext, offset: count)
            guard !entries.isEmpty else { break }
            for entry in entries {
                try handle.write(contentsOf: encoder.encode(entry.record))
                try handle.write(contentsOf: Data([10]))
            }
            count += entries.count
            // Release fetched models between batches.
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        return count
    }
}
