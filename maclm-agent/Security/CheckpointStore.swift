import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor @Observable final class CheckpointStore {
    let service: CheckpointService
    private let context: ModelContext
    private let defaults: UserDefaults
    private(set) var usage: Int64 = 0
    var volumeGB: Int {
        get { defaults.object(forKey: "checkpoints.volumeGB") as? Int ?? 2 }
        set { defaults.set(max(1, newValue), forKey: "checkpoints.volumeGB") }
    }

    var retentionDays: Int {
        get { defaults.object(forKey: "checkpoints.retentionDays") as? Int ?? 30 }
        set { defaults.set(max(1, newValue), forKey: "checkpoints.retentionDays") }
    }

    init(service: CheckpointService, context: ModelContext, defaults: UserDefaults = .standard) {
        self.service = service
        self.context = context
        self.defaults = defaults
    }

    func persist(_ value: CheckpointSnapshot) throws {
        let id = value.id
        if let existing = try context.fetch(FetchDescriptor<Checkpoint>(predicate: #Predicate { $0.id == id })).first {
            existing.update(value)
        } else {
            context.insert(Checkpoint(value))
        }
        try context.save()
    }

    func maintain(clear: Bool = false) async throws {
        await service.configure(totalBytes: Int64(volumeGB) * 1024 * 1024 * 1024, days: retentionDays)
        try await service.prune(all: clear)
        let snapshots = try await service.snapshots()
        let ids = Set(snapshots.map(\.id))
        for record in try context.fetch(FetchDescriptor<Checkpoint>()) where !ids.contains(record.id) {
            context.delete(record)
        }
        for snapshot in snapshots {
            try persist(snapshot)
        }
        try context.save()
        usage = try await service.usage()
    }

    func policy(_ conversation: Conversation) throws -> SecurityPolicyEngine {
        try SecurityPolicyEngine(rules: SecurityRuleSeeder.snapshots(context: context), invocation: .init(
            conversationID: conversation.id, project: conversation.project.map {
                .init(id: $0.id, workingDirectoryPath: $0.workingDirectoryPath)
            }
        ))
    }

    func previewRestore(_ value: CheckpointSnapshot, conversation: Conversation) async throws -> RestorePreview {
        try await service.restorePlan(value, policy: policy(conversation))
    }

    func restore(_ preview: RestorePreview, conversation: Conversation) async throws {
        var record = AuditRecord(
            toolName: "restore_checkpoint",
            argumentsJSON: "{}",
            decision: .userInitiated,
            conversationID: conversation.id,
            checkpointID: preview.checkpoint.id
        )
        do {
            let restored = try await service
                .restore(preview, policy: policy(conversation)) { [self] value in try persist(value) }
            try persist(restored)
            record.outcome = .success
            record.resultSummary = "Restored checkpoint \(restored.id.uuidString)"
        } catch {
            record.outcome = .failure
            record.errorDescription = error.localizedDescription
            context.insert(AuditEntry(record))
            try context.save()
            throw error
        }
        context.insert(AuditEntry(record))
        try context.save()
        try await maintain()
    }
}

extension EnvironmentValues {
    @Entry var checkpointStore: CheckpointStore?
}
