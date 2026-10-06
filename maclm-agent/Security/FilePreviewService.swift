import Foundation

struct DiffLine: Codable, Equatable, Sendable {
    var kind: String
    var text: String
}

struct FilePreview: Codable, Equatable, Sendable {
    var kind: String
    var paths: [String]
    var lines: [DiffLine] = []
    var added = 0
    var removed = 0
    var beforeBytes: Int64 = 0
    var afterBytes: Int64 = 0
    var count = 0
    var modified: Date?
    var destinationExists = false
    var rollbackReason: String?
    var canRestore = false
    var objectType: String?
}

struct PreparedFileOperation: Equatable, Sendable {
    var preview: FilePreview
    var plan: CheckpointPlan
}

enum FilePreviewService {
    static let covered = Set(["write_file", "move_file", "delete_file"])

    // Keep the existing operation and error ordering unchanged.
    // swiftlint:disable:next function_body_length
    static func prepare(
        tool: String,
        arguments: [String: String],
        policy: SecurityPolicyEngine,
        checkpoints: CheckpointService
    ) async throws -> PreparedFileOperation {
        let paths = try CheckpointFileState.paths(tool: tool, arguments: arguments)
        let unavailable = PreparedFileOperation(
            preview: .init(kind: "unavailable", paths: paths, rollbackReason: CheckpointError.unavailable.rawValue),
            plan: .init(fingerprints: [], bytes: 0, reason: .unavailable)
        )
        return try await withCheckedThrowingContinuation { continuation in
            let delivery = PreviewDelivery(continuation, fallback: unavailable)
            let worker = Task.detached {
                do {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    var plan = try await checkpoints.plan(
                        paths: paths,
                        policy: policy,
                        requireZone: false,
                        deadline: deadline
                    )
                    if tool == "write_file", arguments["mode"] != "append", let path = paths.first,
                       (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType ==
                       .typeSymbolicLink
                    {
                        // The copy restores the link itself, while the diff reads its target.
                        // Track that additional read so target changes cannot invalidate the approved diff.
                        let target = PathCanonicalizer.canonicalize(path)
                        plan
                            .previewReads =
                            try [CheckpointFileState.inspect(target, policy: policy, deadline: deadline).fingerprint]
                    }
                    delivery.fallback(.init(
                        preview: .init(
                            kind: "unavailable",
                            paths: paths,
                            rollbackReason: plan.reason?.rawValue,
                            canRestore: plan.canRestore
                        ), plan: plan
                    ))
                    let preview = try render(
                        tool: tool,
                        arguments: arguments,
                        paths: paths,
                        plan: plan,
                        policy: policy,
                        deadline: deadline
                    )
                    delivery.finish(.success(.init(preview: preview, plan: plan)))
                } catch CheckpointError.unavailable {
                    delivery.finishFallback()
                } catch { delivery.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if delivery.finishFallback() {
                    worker.cancel()
                }
            }
        }
    }

    // Keep the existing operation and error ordering unchanged. Preserve the existing security operation signature.
    // swiftlint:disable:next function_body_length function_parameter_count
    static func render(
        tool: String,
        arguments: [String: String],
        paths: [String],
        plan: CheckpointPlan,
        policy: SecurityPolicyEngine,
        deadline: ContinuousClock.Instant
    ) throws -> FilePreview {
        var result = FilePreview(
            kind: tool,
            paths: paths,
            rollbackReason: plan.reason?.rawValue,
            canRestore: plan.canRestore
        )
        let path = paths[0]
        result.destinationExists = tool == "move_file" && plan.fingerprints.last?.exists == true
        if tool == "move_file" {
            return result
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let type = attributes?[.type] as? FileAttributeType
        result.objectType = type == .typeDirectory ? "Каталог"
            : type == .typeSymbolicLink ? "Символическая ссылка" : "Файл"
        result.modified = attributes?[.modificationDate] as? Date
        if plan.reason == .unreadable {
            result.kind = "size"
            result.beforeBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            result.afterBytes = Int64((arguments["content"] ?? "").utf8.count)
                + (arguments["mode"] == "append" ? result.beforeBytes : 0)
            return result
        }
        let info = try CheckpointFileState.inspect(path, policy: policy, requireZone: false, deadline: deadline)
        result.beforeBytes = info.bytes
        result.count = info.count
        result.modified = info.modified
        if tool == "delete_file", info.isDirectory {
            result.kind = "directory"; return result
        }
        let content = arguments["content"] ?? ""
        result.afterBytes = Int64(content.utf8.count) + (arguments["mode"] == "append" ? info.bytes : 0)
        if tool == "write_file", !info.fingerprint.exists {
            result.kind = "new"
            result.lines = textLines(content).prefix(40).map { .init(kind: "+", text: $0) }
            return result
        }
        guard
            !info.isDirectory, info.bytes <= 1024 * 1024,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.contains(0),
            let old = String(data: data, encoding: .utf8), textLines(old).count <= 20000
        else {
            result.kind = "size"
            return result
        }
        if tool == "delete_file" {
            result.lines = textLines(old).prefix(20).map { .init(kind: " ", text: $0) }
            return result
        }
        let new = arguments["mode"] == "append" ? old + content : content
        guard new.utf8.count <= 1024 * 1024, textLines(new).count <= 20000 else {
            result.kind = "size"
            return result
        }
        let diff = try unifiedDiff(old: old, new: new, deadline: deadline)
        result.kind = "diff"
        result.lines = diff.lines
        result.added = diff.added
        result.removed = diff.removed
        // Recheck the state used for the actual displayed diff.
        guard
            try CheckpointFileState.inspect(path, policy: policy, requireZone: false, deadline: deadline).fingerprint
            == plan.fingerprints[0] else { throw CheckpointError.changed }
        return result
    }

    static func textLines(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var lines = value.components(separatedBy: "\n")
        if value.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func terminatedLines(_ value: String) -> [String] {
        let lines = textLines(value)
        return lines.enumerated().map { index, line in
            line + (index < lines.count - 1 || value.hasSuffix("\n") ? "\n" : "")
        }
    }

    // Preserve existing security, rollback, operation and error ordering.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func unifiedDiff(
        old: String, new: String, deadline: ContinuousClock.Instant? = nil
    ) throws -> UnifiedDiff {
        let before = terminatedLines(old), after = terminatedLines(new)
        guard before.count <= 20000, after.count <= 20000 else { throw CheckpointError.limit }
        // CollectionDifference infers edits only, preserving exact CR and final-newline differences.
        let changes = after.difference(from: before)
        if let deadline, ContinuousClock.now >= deadline {
            throw CheckpointError.unavailable
        }
        var deletes: Set<Int> = [], inserts: Set<Int> = []
        for change in changes {
            switch change {
            case let .remove(offset, _, _): deletes.insert(offset)
            case let .insert(offset, _, _): inserts.insert(offset)
            }
        }
        var rows: [DiffRow] = []
        var oldIndex = 0, newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if deletes.contains(oldIndex), oldIndex < before.count {
                rows.append(.init(
                    line: .init(kind: "-", text: before[oldIndex]),
                    oldIndex: oldIndex,
                    newIndex: newIndex
                )); oldIndex += 1
            } else if inserts.contains(newIndex), newIndex < after.count {
                rows.append(.init(
                    line: .init(kind: "+", text: after[newIndex]),
                    oldIndex: oldIndex,
                    newIndex: newIndex
                )); newIndex += 1
            } else if oldIndex < before.count, newIndex < after.count {
                rows.append(.init(
                    line: .init(kind: " ", text: before[oldIndex]),
                    oldIndex: oldIndex,
                    newIndex: newIndex
                )); oldIndex += 1; newIndex += 1
            } else {
                break
            }
        }
        var ranges: [Range<Int>] = []
        for index in rows.indices where rows[index].line.kind != " " {
            let range = max(0, index - 3) ..< min(rows.count, index + 4)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var output: [DiffLine] = []
        var previous = 0
        for range in ranges {
            if range.lowerBound > previous {
                output.append(.init(kind: "…", text: ""))
            }
            let slice = rows[range]
            let oldCount = slice.filter { $0.line.kind != "+" }.count
            let newCount = slice.filter { $0.line.kind != "-" }.count
            let first = rows[range.lowerBound]
            output.append(.init(
                kind: "@",
                // Preserve the exact existing string or expression without changing its value.
                // swiftlint:disable:next line_length
                text: "@@ -\(first.oldIndex + (oldCount == 0 ? 0 : 1)),\(oldCount) +\(first.newIndex + (newCount == 0 ? 0 : 1)),\(newCount) @@"
            ))
            for row in slice {
                var line = row.line
                let terminated = line.text.hasSuffix("\n")
                if terminated {
                    line.text.removeLast()
                }
                output.append(line)
                if !terminated, line.kind != " " {
                    output.append(.init(kind: "\\", text: "No newline at end of file"))
                }
            }
            previous = range.upperBound
        }
        if previous < rows.count {
            output.append(.init(kind: "…", text: ""))
        }
        return .init(lines: output, added: inserts.count, removed: deletes.count)
    }
}

/// A timeout does not await a potentially expensive CollectionDifference worker.
private final class PreviewDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PreparedFileOperation, any Error>?
    private var unavailable: PreparedFileOperation
    init(_ continuation: CheckedContinuation<PreparedFileOperation, any Error>, fallback: PreparedFileOperation) {
        self.continuation = continuation
        unavailable = fallback
    }

    func fallback(_ value: PreparedFileOperation) {
        lock.lock()
        unavailable = value
        lock.unlock()
    }

    @discardableResult func finishFallback() -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        let value = unavailable
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }

    @discardableResult func finish(_ result: Result<PreparedFileOperation, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

struct UnifiedDiff: Equatable, Sendable {
    var lines: [DiffLine]
    var added: Int
    var removed: Int
}

private struct DiffRow {
    var line: DiffLine
    var oldIndex: Int
    var newIndex: Int
}
