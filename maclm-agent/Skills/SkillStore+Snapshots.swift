import Darwin
import Foundation
import SwiftData

extension SkillStore {
    func captureSnapshot(_ snapshot: SkillSnapshot, record: SkillRecord) throws {
        guard let hash = snapshot.hash, snapshot.problem == nil else { throw SkillValidationError.unavailable }
        try SkillSnapshotIO.withRoot(snapshotRoot) { root in
            try SkillSnapshotIO.withFolder(snapshot.id, hash: hash, root: root, create: true) { folder in
                try SkillSnapshotIO.write(Data(snapshot.text.utf8), folder: folder)
            }
        }
        var manifests = try manifests(record)
        manifests[hash] = snapshot.files
        record.manifestsData = try JSONEncoder().encode(manifests)
    }

    /// Pinning rescans with the shared reader, and snapshots those same verified bytes.
    func snapshotForPin(_ reference: SkillAttachment) throws {
        let entries = try rescan()
        guard let snapshot = entries.first(where: { $0.id == reference.id }), snapshot.state == .enabled,
              snapshot.hash == reference.hash, let record = try record(reference.id)
        else {
            throw SkillValidationError.changedSincePreview
        }
        do {
            try captureSnapshot(snapshot, record: record)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func review(_ id: String, referenceHash: String? = nil) throws -> SkillReview {
        let entries = try rescan()
        guard let current = entries.first(where: { $0.id == id }), let record = try record(id) else {
            throw SkillValidationError.unavailable
        }
        let reference = referenceHash ?? record.enabledHash
        let files = try reference.flatMap { try manifests(record)[$0] }
        var oldText: String?
        if let reference, let instruction = files?.first(where: { $0.path == "SKILL.md" }) {
            oldText = try? SkillSnapshotIO.withRoot(snapshotRoot) { root in
                try SkillSnapshotIO.withFolder(id, hash: reference, root: root, create: false) { folder in
                    let data = try SkillFileIO.readFile(instruction, root: folder)
                    guard SkillHasher.digest(data) == instruction.digest,
                          let text = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
                    return text
                }
            }
        }
        return try .make(current: current, referenceHash: reference, files: oldText == nil ? nil : files, text: oldText)
    }

    /// Reference counts are derived from durable rows, including pins in other projects.
    /// A fresh context sees project changes saved by the main-context UI.
    func cleanupSnapshots() throws {
        let reader = ModelContext(container)
        let projects = container.schema.entities.contains { $0.name == "Project" }
            ? try reader.fetch(FetchDescriptor<Project>()) : []
        let records = try context.fetch(FetchDescriptor<SkillRecord>())
        var references: [String: Set<String>] = [:]
        for record in records {
            if let hash = record.enabledHash {
                references[record.skillID, default: []].insert(hash)
            }
        }
        for pin in projects.flatMap(\.pinnedSkills) {
            references[pin.id, default: []].insert(pin.hash)
        }
        for record in records {
            let retained = try manifests(record).filter { references[record.skillID, default: []].contains($0.key) }
            record.manifestsData = retained.isEmpty ? nil : try JSONEncoder().encode(retained)
        }
        try context.save()
        try SkillSnapshotIO.withRoot(snapshotRoot) { root in
            for id in try SkillFileIO.names(root) {
                guard let hashes = references[id], !hashes.isEmpty else {
                    try SkillSnapshotIO.remove(id, parent: root); continue
                }
                let folder = try SkillFileIO.childDirectory(id, parent: root)
                defer { close(folder) }
                for hash in try SkillFileIO.names(folder) where !hashes.contains(hash) {
                    try SkillSnapshotIO.remove(hash, parent: folder)
                }
            }
        }
    }

    func remove(_ id: String) throws -> [SkillSnapshot] {
        guard SkillParser.validName(id), let record = try record(id), record.source == "appFolder" else {
            throw SkillValidationError.unavailable
        }
        let folder = root.appendingPathComponent(id)
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        do {
            if container.schema.entities.contains(where: { $0.name == "Project" }) {
                for project in try context.fetch(FetchDescriptor<Project>()) {
                    project.pinnedSkillsData = try JSONEncoder().encode(project.pinnedSkills.filter { $0.id != id })
                }
            }
            context.insert(AuditEntry(.init(
                toolName: "skill.removed",
                argumentsJSON: "{\"skill\":\"\(id)\"}",
                riskLevel: .safe,
                decision: .userInitiated,
                outcome: .success
            )))
            context.delete(record)
            try context.save()
            try cleanupSnapshots()
            return try rescan()
        } catch { context.rollback(); throw error }
    }

    func auditReconfirm(id: String, oldHash: String?, newHash: String, projectID: UUID? = nil) throws {
        var arguments = try [
            "skill": id, "oldHash": oldHash ?? "", "newHash": newHash,
            "source": record(id)?.source ?? "appFolder", "hash": newHash,
        ]
        if let projectID {
            arguments["projectID"] = projectID.uuidString
        }
        let data = try JSONEncoder().encode(arguments)
        guard let json = String(data: data, encoding: .utf8) else { throw SkillValidationError.unreadable }
        context.insert(AuditEntry(.init(
            toolName: "skill.reconfirm",
            argumentsJSON: json,
            riskLevel: .safe,
            decision: .userInitiated,
            outcome: .success
        )))
    }

    private func manifests(_ record: SkillRecord) throws -> [String: [SkillFile]] {
        try JSONDecoder().decode([String: [SkillFile]].self, from: record.manifestsData ?? Data("{}".utf8))
    }
}
