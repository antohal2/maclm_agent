import Foundation

struct CheckpointLimits: Sendable {
    var fileBytes: Int64 = 50 * 1024 * 1024
    var directoryBytes: Int64 = 200 * 1024 * 1024
    var reserveBytes: Int64 = 64 * 1024 * 1024
    var totalBytes: Int64 = 2 * 1024 * 1024 * 1024
    var days: Int = 30
}

struct CheckpointPlan: Equatable, Sendable {
    var fingerprints: [FileFingerprint]
    var bytes: Int64
    var previewReads: [FileFingerprint] = []
    var reason: CheckpointError?
    var canRestore: Bool {
        reason == nil
    }
}

actor CheckpointService {
    let root: URL
    private var limits: CheckpointLimits
    private var active: Set<UUID> = []
    private var restoring = false
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private let freeSpace: @Sendable (URL) throws -> Int64

    init(
        root: URL,
        limits: CheckpointLimits = .init(),
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        freeSpace: @escaping @Sendable (URL) throws -> Int64 = { url in
            var existing = url
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            return try (FileManager.default
                .attributesOfFileSystem(forPath: existing.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
    ) {
        self.root = root
        self.limits = limits
        self.copyItem = copyItem
        self.freeSpace = freeSpace
    }

    func configure(totalBytes: Int64, days: Int) {
        limits.totalBytes = max(0, totalBytes); limits.days = max(0, days)
    }

    func plan(
        paths: [String],
        policy: SecurityPolicyEngine,
        requireZone: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> CheckpointPlan {
        var fingerprints: [FileFingerprint] = []
        var bytes: Int64 = 0
        var reason: CheckpointError?
        for path in paths {
            do {
                let info = try CheckpointFileState.inspect(
                    path,
                    policy: policy,
                    requireZone: requireZone,
                    deadline: deadline
                )
                fingerprints.append(info.fingerprint)
                bytes += info.bytes
                if info.bytes > (info.isDirectory ? limits.directoryBytes : limits.fileBytes) {
                    reason = .limit
                }
            } catch CheckpointError.unreadable {
                reason = .unreadable
                // An unreadable object is allowed only under explicit approval, without a rollback promise.
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                try fingerprints.append(.init(
                    path: path,
                    exists: true,
                    digest: nil,
                    metadata: CheckpointFileState.metadata(path)
                ))
            }
        }
        if bytes > limits.totalBytes {
            reason = .limit
        }
        if try freeSpace(root) < bytes + limits.reserveBytes {
            reason = .space
        }
        return .init(fingerprints: fingerprints, bytes: bytes, reason: reason)
    }

    func create(
        tool: String,
        conversationID: UUID?,
        expected: CheckpointPlan,
        policy: SecurityPolicyEngine
    ) throws -> CheckpointSnapshot {
        try validateRoot()
        guard expected.canRestore else { throw expected.reason ?? CheckpointError.copy }
        let paths = expected.fingerprints.map(\.path)
        let actual = try plan(paths: paths, policy: policy)
        guard actual.fingerprints == expected.fingerprints else { throw CheckpointError.changed }
        guard actual.canRestore else { throw actual.reason ?? CheckpointError.copy }
        var snapshot = CheckpointSnapshot(
            conversationID: conversationID,
            toolName: tool,
            items: [],
            totalBytes: actual.bytes
        )
        let directory = root.appendingPathComponent(snapshot.id.uuidString)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for (index, fingerprint) in expected.fingerprints.enumerated() {
                let info = try CheckpointFileState.inspect(fingerprint.path, policy: policy)
                guard info.fingerprint == fingerprint else { throw CheckpointError.changed }
                let relative = fingerprint.exists ? "item-\(index)" : nil
                var digest: String?
                if let relative {
                    let original = URL(fileURLWithPath: fingerprint.path)
                    let saved = directory.appendingPathComponent(relative)
                    try copyItem(original, saved)
                    digest = try CheckpointFileState.contentHash(saved)
                    guard
                        try digest == (CheckpointFileState.contentHash(original)),
                        try CheckpointFileState.inspect(fingerprint.path, policy: policy).fingerprint == fingerprint
                    else { throw CheckpointError.changed }
                }
                snapshot.items.append(.init(
                    originalPath: fingerprint.path,
                    existedBefore: fingerprint.exists,
                    isDirectory: info.isDirectory,
                    storedRelativePath: relative,
                    sha256: digest
                ))
            }
            // Verify every object again, including an absent destination, after the final copy.
            try verify(expected, policy: policy)
            try save(snapshot)
            active.insert(snapshot.id)
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let error = error as? CheckpointError {
                throw error
            }
            throw CheckpointError.copy
        }
    }

    func verify(_ expected: CheckpointPlan, policy: SecurityPolicyEngine) throws {
        for fingerprint in expected.fingerprints + expected.previewReads {
            try CheckpointFileState.authorize(fingerprint.path, policy: policy, requireZone: false)
            if fingerprint.digest == nil, fingerprint.exists {
                guard try fingerprint.metadata == (CheckpointFileState.metadata(fingerprint.path))
                else { throw CheckpointError.changed }
                continue
            }
            guard try CheckpointFileState.inspect(fingerprint.path, policy: policy).fingerprint == fingerprint
            else { throw CheckpointError.changed }
        }
    }

    func complete(_ snapshot: CheckpointSnapshot) throws -> CheckpointSnapshot {
        defer { active.remove(snapshot.id) }
        var value = snapshot
        value.postOperation = try? snapshot.items.map { try CheckpointFileState.inspect($0.originalPath).fingerprint }
        try save(value)
        return value
    }

    func discard(_ id: UUID) throws {
        active.remove(id)
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }

    private func save(_ value: CheckpointSnapshot) throws {
        try validateRoot()
        let data = try JSONEncoder().encode(value)
        try data.write(
            to: root.appendingPathComponent(value.id.uuidString).appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func validateRoot() throws {
        guard PathCanonicalizer.canonicalize(root.path) == root.path else { throw CheckpointError.corrupt }
    }

    func snapshots() throws -> [CheckpointSnapshot] {
        try validateRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { directory in
                guard
                    let id = UUID(uuidString: directory.lastPathComponent),
                    let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                    let value = try? JSONDecoder().decode(CheckpointSnapshot.self, from: data), value.id == id
                else { return nil }
                return value
            }
    }

    func usage() throws -> Int64 {
        try snapshots().reduce(0) { $0 + $1.totalBytes }
    }

    @discardableResult func prune(now: Date = Date(), all: Bool = false) throws -> [UUID] {
        let values = try snapshots().sorted { $0.createdAt < $1.createdAt }
        var bytes = values.reduce(Int64(0)) { $0 + $1.totalBytes }
        var removed: [UUID] = []
        let cutoff = now.addingTimeInterval(-Double(limits.days) * 86400)
        for value in values where !active.contains(value.id) {
            if all || value.createdAt < cutoff || bytes > limits.totalBytes {
                try FileManager.default.removeItem(at: root.appendingPathComponent(value.id.uuidString))
                bytes -= value.totalBytes
                removed.append(value.id)
            }
        }
        return removed
    }

    func validate(_ value: CheckpointSnapshot, policy: SecurityPolicyEngine) throws {
        let directory = root.appendingPathComponent(value.id.uuidString)
        guard PathCanonicalizer.canonicalize(directory.path) == directory.path else { throw CheckpointError.corrupt }
        var seen: Set<String> = []
        for item in value.items {
            guard !seen
                .contains(where: { $0.hasPrefix(item.originalPath + "/") || item.originalPath.hasPrefix($0 + "/") })
            else { throw CheckpointError.corrupt }
            guard
                item.originalPath.hasPrefix("/"),
                CheckpointFileState.operationPath(item.originalPath) == item.originalPath,
                seen.insert(item.originalPath).inserted else { throw CheckpointError.corrupt }
            try CheckpointFileState.authorize(item.originalPath, policy: policy, requireZone: false)
            if item.existedBefore {
                guard
                    let relative = item.storedRelativePath, !relative.hasPrefix("/"),
                    !relative.split(separator: "/").contains(".."), !relative.isEmpty,
                    let digest = item.sha256 else { throw CheckpointError.corrupt }
                let saved = directory.appendingPathComponent(relative)
                // Parent symlinks cannot redirect a saved item out of its checkpoint.
                guard
                    CheckpointFileState.operationPath(saved.path).hasPrefix(directory.path + "/"),
                    try CheckpointFileState.contentHash(saved) == digest else { throw CheckpointError.corrupt }
                try validateDescendants(saved, target: URL(fileURLWithPath: item.originalPath), policy: policy)
            } else if item.storedRelativePath != nil || item.sha256 != nil {
                throw CheckpointError.corrupt
            }
            // Current directory contents will be removed; apply blocks to descendants too.
            _ = try CheckpointFileState.inspect(item.originalPath, policy: policy)
        }
    }

    private func validateDescendants(_ saved: URL, target: URL, policy: SecurityPolicyEngine) throws {
        try CheckpointFileState.authorize(target.path, policy: policy, requireZone: false)
        let type = try FileManager.default.attributesOfItem(atPath: saved.path)[.type] as? FileAttributeType
        if type == .typeDirectory {
            for name in try FileManager.default.contentsOfDirectory(atPath: saved.path) {
                try validateDescendants(
                    saved.appendingPathComponent(name),
                    target: target.appendingPathComponent(name),
                    policy: policy
                )
            }
        } else if type == .typeSymbolicLink {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: saved.path)
            let resolved = link.hasPrefix("/") ? link : target.deletingLastPathComponent().appendingPathComponent(link)
                .path
            try CheckpointFileState.authorize(resolved, policy: policy, requireZone: false)
        }
    }

    func restorePlan(_ value: CheckpointSnapshot, policy: SecurityPolicyEngine) throws -> RestorePreview {
        try validate(value, policy: policy)
        let plan = try plan(paths: value.items.map(\.originalPath), policy: policy)
        guard plan.canRestore else { throw plan.reason ?? CheckpointError.copy }
        return .init(
            checkpoint: value,
            current: plan,
            changed: value.postOperation == nil || value.postOperation != plan.fingerprints
        )
    }

    func restore(
        _ preview: RestorePreview,
        policy: SecurityPolicyEngine,
        persist: @escaping @MainActor @Sendable (CheckpointSnapshot) async throws -> Void
    ) async throws -> CheckpointSnapshot {
        guard !restoring else { throw CheckpointError.busy }
        restoring = true
        active.insert(preview.checkpoint.id)
        defer { restoring = false; active.remove(preview.checkpoint.id) }
        try validate(preview.checkpoint, policy: policy)
        let undo = try create(
            tool: "restore_checkpoint",
            conversationID: preview.checkpoint.conversationID,
            expected: preview.current,
            policy: policy
        )
        do { try await persist(undo) }
        catch { try? discard(undo.id); throw error }
        do {
            try Task.checkCancellation()
            try verify(preview.current, policy: policy)
            try validate(preview.checkpoint, policy: policy)
            try apply(preview.checkpoint)
        } catch {
            // Best-effort recovery from a partial restore. Keep the undo snapshot even if recovery fails.
            if (try? validate(undo, policy: policy)) != nil {
                try? apply(undo)
            }
            _ = try? complete(undo)
            throw error
        }
        let finishedUndo = try complete(undo)
        try await persist(finishedUndo)
        var restored = preview.checkpoint
        restored.isRestored = true
        try save(restored)
        return restored
    }

    private func apply(_ value: CheckpointSnapshot) throws {
        for item in value.items {
            guard CheckpointFileState.operationPath(item.originalPath) == item.originalPath
            else { throw CheckpointError.changed }
            let target = URL(fileURLWithPath: item.originalPath)
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                try FileManager.default.removeItem(at: target)
            }
            if let relative = item.storedRelativePath {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(value.id.uuidString).appendingPathComponent(relative),
                    to: target
                )
            }
        }
    }
}

struct RestorePreview: Equatable, Sendable {
    var checkpoint: CheckpointSnapshot
    var current: CheckpointPlan
    var changed: Bool
}
