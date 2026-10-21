import Darwin
import Foundation
import SwiftData

extension SkillStore {
    nonisolated var stagingRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent(
            root.lastPathComponent == "skills" ? "skill-staging" : root.lastPathComponent + "-staging"
        )
    }

    func cleanupStaging() throws {
        try SkillDraftIO.cleanup(stagingRoot)
    }

    func checkDraftName(_ name: String) throws {
        guard try !draftNameExists(name) else {
            var suggestions: [String] = []
            for index in 2 ... 1000 {
                let suffix = "-\(index)"
                let base = String(name.prefix(64 - suffix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let candidate = base + suffix
                if try !draftNameExists(candidate) {
                    suggestions.append(candidate)
                }
                if suggestions.count == 3 {
                    break
                }
            }
            throw SkillDraftError(reason: "skill name already exists; free alternatives: " + suggestions
                .joined(separator: ", "))
        }
    }

    private func draftNameExists(_ name: String) throws -> Bool {
        let records = try context.fetch(FetchDescriptor<SkillRecord>())
        if records.contains(where: { $0.skillID.lowercased() == name.lowercased() }) {
            return true
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        let parent = try SkillFileIO.directory(root.path)
        defer { close(parent) }
        return try SkillFileIO.names(parent).contains { $0.lowercased() == name.lowercased() }
    }

    func saveDraft(_ draft: SkillDraft, conversationID: UUID) throws -> ToolExecutionResult {
        try Task.checkCancellation()
        try checkDraftName(draft.name)
        // This actor never suspends between the final name check, rename, metadata and scan.
        do { try SkillDraftIO.write(draft, root: root, staging: stagingRoot) } catch {
            // A racing creator gets the same free-name guidance as an initial collision.
            try checkDraftName(draft.name)
            throw error
        }
        do {
            let record = SkillRecord(skillID: draft.name)
            record.origin = "model-drafted"
            record.state = .disabled
            context.insert(record)
            try context.insert(AuditEntry(Self.draftAudit(
                "skill.draftApproved", name: draft.name, hash: draft.hash,
                warningCount: draft.warningCount, conversationID: conversationID
            )))
            _ = try rescan()
            return .success(content: "created: \(draft.name); disabled; enable manually in Settings > Skills")
        } catch {
            context.rollback()
            let parent = try SkillFileIO.directory(root.path)
            defer { close(parent) }
            try SkillSnapshotIO.remove(draft.name, parent: parent)
            throw error
        }
    }

    func auditDraft(_ event: String, draft: SkillDraft, conversationID: UUID) throws {
        try persistDraftAudit(Self.draftAudit(
            event, name: draft.name, hash: draft.hash, warningCount: draft.warningCount, conversationID: conversationID
        ))
    }

    static func draftAudit(
        _ event: String, name: String = "", hash: String, warningCount: Int = 0, conversationID: UUID
    ) throws -> AuditRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": name, "hash": hash, "conversationID": conversationID.uuidString, "warningCount": warningCount,
        ], options: .sortedKeys)
        guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
        return AuditRecord(
            toolName: event, argumentsJSON: json, riskLevel: .caution,
            decision: event == "skill.draftApproved" ? .approved : event == "skill.draftRejected" ? .rejected : .auto,
            outcome: event == "skill.draftUnrequested" ? .notExecuted : .success,
            resultSummary: event, conversationID: conversationID
        )
    }

    func persistDraftAudit(_ audit: AuditRecord) throws {
        do { context.insert(AuditEntry(audit)); try context.save() } catch { context.rollback(); throw error }
    }
}
