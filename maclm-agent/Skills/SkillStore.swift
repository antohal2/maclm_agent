import Darwin
import Foundation
import SwiftData

/// Initialized by ApplicationRuntime; its context is created on the actor's executor,
/// never on the main thread. Only Sendable snapshots cross the boundary to Settings.
actor SkillStore {
    let root: URL
    private let container: ModelContainer
    private var persistence: ModelContext?
    private var snapshots: [SkillSnapshot] = []

    init(root: URL, container: ModelContainer) {
        self.root = root
        self.container = container
    }

    private var context: ModelContext {
        if let persistence {
            return persistence
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        persistence = context
        return context
    }

    @discardableResult
    func rescan() throws -> [SkillSnapshot] {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scanned = try SkillScanner.scan(root: root)
            let records = try context.fetch(FetchDescriptor<SkillRecord>())
            var result: [SkillSnapshot] = []
            for var snapshot in scanned {
                let record = records.first { $0.skillID == snapshot.id } ?? SkillRecord(skillID: snapshot.id)
                if record.modelContext == nil {
                    context.insert(record)
                }
                try reconcile(&snapshot, record: record)
                result.append(snapshot)
            }
            for record in records where !scanned.contains(where: { $0.id == record.skillID }) {
                var missing = SkillSnapshot(id: record.skillID, state: .invalid, problem: .unavailable)
                try reconcile(&missing, record: record)
                result.append(missing)
            }
            try context.save()
            snapshots = result.sorted { $0.id < $1.id }
            return snapshots
        } catch {
            context.rollback()
            throw error
        }
    }

    func enable(_ id: String, expectedHash: String) throws -> [SkillSnapshot] {
        try approve(id, expectedHash: expectedHash, reconfirm: false)
    }

    func reconfirm(_ id: String, expectedHash: String) throws -> [SkillSnapshot] {
        try approve(id, expectedHash: expectedHash, reconfirm: true)
    }

    func disable(_ id: String) throws -> [SkillSnapshot] {
        _ = try rescan()
        guard let index = snapshots.firstIndex(where: { $0.id == id }), let record = try record(id) else {
            throw SkillValidationError.unavailable
        }
        do {
            try audit("skill.disable", record: record, hash: snapshots[index].hash ?? record.enabledHash)
            record.state = snapshots[index].problem == nil ? .disabled : .invalid
            record.enabledHash = nil
            record.enabledAt = nil
            try context.save()
            snapshots[index].state = record.state
            snapshots[index].enabledHash = nil
            return snapshots
        } catch { context.rollback(); throw error }
    }

    /// One folder pass: SKILL.md is read once by SkillFileIO; the returned text
    /// and manifest hash use those same bytes. No cached text crosses this gate.
    func verifiedAttachment(_ id: String, expectedHash: String? = nil) throws -> AttachedSkill {
        guard let record = try record(id), record.state == .enabled else {
            throw SkillValidationError.unavailable
        }
        guard SkillParser.validName(id) else {
            throw SkillValidationError.unavailable
        }
        var scanned = SkillScanner.scanSkill(at: root.appendingPathComponent(id))
        try reconcile(&scanned, record: record)
        try context.save()
        if let index = snapshots.firstIndex(where: { $0.id == id }) {
            snapshots[index] = scanned
        }
        guard scanned.state == .enabled, let hash = scanned.hash, hash == record.enabledHash else {
            throw SkillValidationError.reconfirmRequired
        }
        guard expectedHash == nil || expectedHash == hash else { throw SkillValidationError.changedSincePreview }
        return AttachedSkill(reference: .init(id: id, hash: hash, source: record.source), body: scanned.body)
    }

    func state(of id: String) throws -> SkillState? {
        try record(id)?.state
    }

    /// Metadata refresh between model turns; never re-reads instruction bytes.
    func catalogSnapshots() -> [SkillSnapshot] {
        snapshots
    }

    func noteUsed(_ id: String, expectedHash: String) throws {
        guard let record = try record(id), record.state == .enabled, record.enabledHash == expectedHash else {
            throw SkillValidationError.unavailable
        }
        record.lastUsedAt = Date()
        try context.save()
        if let index = snapshots.firstIndex(where: { $0.id == id }) {
            snapshots[index].lastUsedAt = record.lastUsedAt
        }
    }

    private func approve(_ id: String, expectedHash: String, reconfirm: Bool) throws -> [SkillSnapshot] {
        _ = try rescan()
        guard let index = snapshots.firstIndex(where: { $0.id == id }), let record = try record(id),
              snapshots[index].problem == nil, let hash = snapshots[index].hash
        else {
            throw SkillValidationError.unavailable
        }
        guard hash == expectedHash else { throw SkillValidationError.changedSincePreview }
        guard record.state != .needsReconfirm || reconfirm else { throw SkillValidationError.reconfirmRequired }
        if record.state == .enabled {
            return snapshots
        }
        do {
            record.state = .enabled
            record.enabledHash = hash
            record.enabledAt = Date()
            try audit("skill.enable", record: record, hash: hash)
            try context.save()
            snapshots[index].state = .enabled
            snapshots[index].enabledHash = hash
            return snapshots
        } catch { context.rollback(); throw error }
    }

    private func record(_ id: String) throws -> SkillRecord? {
        try context.fetch(FetchDescriptor<SkillRecord>(predicate: #Predicate { $0.skillID == id })).first
    }

    private func reconcile(_ snapshot: inout SkillSnapshot, record: SkillRecord) throws {
        if record.state == .enabled, snapshot.hash != record.enabledHash {
            try audit("skill.hashMismatch", record: record, hash: snapshot.hash, automatic: true)
            record.state = .needsReconfirm
        }
        if snapshot.problem != nil {
            record.state = .invalid
        } else if record.state == .invalid {
            // Recovering from an invalid scan never silently reinstates prior trust.
            record.state = record.enabledHash == nil ? .disabled : .needsReconfirm
        }
        snapshot.state = record.state
        snapshot.enabledHash = record.enabledHash
        snapshot.source = record.source
        snapshot.lastUsedAt = record.lastUsedAt
    }

    private func audit(_ event: String, record: SkillRecord, hash: String?, automatic: Bool = false) throws {
        let arguments: [String: Any] = [
            "skill": record.skillID, "source": record.source, "hash": hash as Any? ?? NSNull(),
            "enabledHash": record.enabledHash as Any? ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
        guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
        context.insert(AuditEntry(AuditRecord(
            toolName: event, argumentsJSON: json, riskLevel: .safe,
            decision: automatic ? .auto : .userInitiated, outcome: .success, resultSummary: event
        )))
    }
}

extension SkillStore {
    /// Authorization, IO and durable audit execute without actor suspension.
    /// This deliberately checks metadata only, not the folder hash (SPEC 15.13).
    func fileRequest(
        _ request: SkillFileRequest, attachment: SkillAttachment?, conversationID: UUID
    ) -> ToolExecutionResult {
        var source = attachment?.source ?? "unknown"
        var bytes = 0
        let result: ToolExecutionResult
        do {
            guard let id = request.skill, SkillParser.validName(id), attachment?.id == id else {
                throw SkillRequestRejection(reason: "not attached")
            }
            guard let current = try record(id) else {
                throw SkillRequestRejection(reason: "unavailable: unknown skill")
            }
            source = current.source
            guard current.state == .enabled, current.source == attachment?.source,
                  current.enabledHash == attachment?.hash
            else {
                throw SkillRequestRejection(reason: "unavailable: skill is \(current.state.rawValue) or trust changed")
            }
            if let error = request.argumentError {
                throw SkillRequestRejection(reason: error)
            }
            if let path = request.path {
                try SkillFileIO.validateModelPath(path)
            }
            let parent = try SkillFileIO.directory(root.path)
            defer { close(parent) }
            let folder = try SkillFileIO.childDirectory(id, parent: parent)
            defer { close(folder) }
            switch request.action {
            case .list:
                let files = try SkillFileAccess.list(root: folder)
                let output = files.map { SkillFileListing(path: $0.path, size: $0.size) }
                let data = try JSONEncoder.toolOutput.encode(output)
                guard let content = String(data: data, encoding: .utf8) else {
                    throw SkillValidationError.unreadable
                }
                bytes = files.reduce(0) { $0 + $1.size }
                result = .success(content: content)
            case .read:
                let text = try SkillFileAccess.read(request.path ?? "SKILL.md", root: folder)
                bytes = text.utf8.count
                result = .success(content: text)
            }
        } catch {
            result = .failure((error as? SkillRequestRejection)?.reason ?? SkillFileAccess.reason(error))
        }
        return auditFileRequest(request, result: result, source: source, bytes: bytes, conversationID: conversationID)
    }

    private func auditFileRequest(
        _ request: SkillFileRequest, result: ToolExecutionResult, source: String, bytes: Int, conversationID: UUID
    ) -> ToolExecutionResult {
        do {
            let arguments: [String: Any] = [
                "skill": request.skill ?? "", "source": source, "path": request.path ?? "",
                "byteCount": bytes, "conversationID": conversationID.uuidString,
                "reason": result.isError ? result.content : "success",
            ]
            let data = try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
            guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
            context.insert(AuditEntry(.init(
                toolName: request.event, argumentsJSON: json, riskLevel: .safe,
                decision: result.isError ? .blocked : .auto, outcome: result.isError ? .failure : .success,
                resultSummary: result.isError ? result.content : "\(request.event): \(bytes) bytes",
                errorDescription: result.isError ? result.content : nil, conversationID: conversationID
            )))
            try context.save()
            return result
        } catch {
            context.rollback()
            return .failure("unavailable: skill file audit persistence failed")
        }
    }
}

private struct SkillRequestRejection: Error {
    let reason: String
}

private struct SkillFileListing: Encodable {
    let path: String
    let size: Int
}
