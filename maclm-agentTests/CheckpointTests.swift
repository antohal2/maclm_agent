import Darwin
import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class CheckpointTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: PathCanonicalizer.canonicalize(url.path))
    }

    private func policy(_ rules: [SecurityRuleSnapshot] = []) -> SecurityPolicyEngine {
        .init(rules: rules, invocation: .init(conversationID: UUID()))
    }

    private func prepared(
        _ tool: String,
        _ arguments: [String: String],
        _ service: CheckpointService,
        _ policy: SecurityPolicyEngine
    ) async throws -> PreparedFileOperation {
        try await FilePreviewService.prepare(tool: tool, arguments: arguments, policy: policy, checkpoints: service)
    }

    func testDiffEditsEmptyFinalNewlineAndCRLF() throws {
        for (old, new, added, removed) in [
            ("a\nb", "a\nc", 1, 1),
            ("a", "a\nb", 2, 1),
            ("a\nb", "a", 1, 2),
            ("", "x", 1, 0),
            ("", "", 0, 0),
            ("a", "a\n", 1, 1),
            ("a\r\nb", "a\nb", 1, 1),
        ] {
            let diff = try FilePreviewService.unifiedDiff(old: old, new: new)
            XCTAssertEqual(diff.added, added)
            XCTAssertEqual(diff.removed, removed)
        }
        let large = Array(repeating: "x", count: 20001).joined(separator: "\n")
        XCTAssertThrowsError(try FilePreviewService.unifiedDiff(old: large, new: "x"))
        let gap = Array(repeating: "same", count: 20).joined(separator: "\n")
        let diff = try FilePreviewService.unifiedDiff(old: "old\n" + gap + "\nold", new: "new\n" + gap + "\nnew")
        XCTAssertEqual(diff.lines.filter { $0.kind == "@" }.count, 2)
        XCTAssertTrue(diff.lines.contains { $0.kind == "…" })
    }

    func testPreviewClassificationAndAppend() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let security = policy()
        let file = root.appendingPathComponent("file")
        let args = ["path": file.path, "mode": "overwrite", "content": "new"]
        var result = try await prepared("write_file", args, service, security)
        XCTAssertEqual(result.preview.kind, "new")
        try Data("old".utf8).write(to: file)
        result = try await prepared("write_file", args, service, security)
        XCTAssertEqual(result.preview.kind, "diff")
        let append = try await prepared(
            "write_file",
            ["path": file.path, "mode": "append", "content": "\nline"],
            service,
            security
        )
        XCTAssertEqual(append.preview.afterBytes, 8)
        XCTAssertEqual(append.preview.added, 2)
        for data in [
            Data([0, 1, 255]),
            Data(repeating: 65, count: 1024 * 1024 + 1),
            Data(Array(repeating: "x", count: 20001).joined(separator: "\n").utf8),
        ] {
            try data.write(to: file)
            result = try await prepared("write_file", args, service, security)
            XCTAssertEqual(result.preview.kind, "size")
        }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("child"))
        let directory = try await prepared("delete_file", ["path": folder.path], service, security)
        XCTAssertEqual(directory.preview.kind, "directory")
        XCTAssertEqual(directory.preview.count, 1)
        XCTAssertEqual(directory.preview.beforeBytes, 3)
    }

    func testWriteRestoreAndRestoreOfRestore() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let security = policy(), file = root.appendingPathComponent("file")
        let bytes = Data([0, 1, 255, 10])
        try bytes.write(to: file)
        let plan = try await service.plan(paths: [file.path], policy: security)
        let cp = try await service.create(tool: "write_file", conversationID: nil, expected: plan, policy: security)
        try Data("replacement".utf8).write(to: file)
        let completed = try await service.complete(cp)
        let preview = try await service.restorePlan(completed, policy: security)
        XCTAssertFalse(preview.changed)
        let restored = try await service.restore(preview, policy: security, persist: { _ in })
        XCTAssertTrue(restored.isRestored)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let values = try await service.snapshots()
        let undo = try XCTUnwrap(values.first { $0.toolName == "restore_checkpoint" })
        let undoPreview = try await service.restorePlan(undo, policy: security)
        _ = try await service.restore(undoPreview, policy: security, persist: { _ in })
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testNewFileAndMoveWithOverwriteRestore() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let security = policy(), source = root.appendingPathComponent("source"),
            destination = root.appendingPathComponent("destination")
        let newPlan = try await service.plan(paths: [source.path], policy: security)
        let newCP = try await service.create(
            tool: "write_file",
            conversationID: nil,
            expected: newPlan,
            policy: security
        )
        let write = try await WriteFileTool().execute(
            arguments: ["path": source.path, "mode": "create", "content": "new"],
            invocation: security.invocation
        )
        XCTAssertFalse(write.isError)
        let finishedNew = try await service.complete(newCP)
        let restoreNew = try await service.restorePlan(finishedNew, policy: security)
        _ = try await service.restore(restoreNew, policy: security, persist: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try Data([0, 255, 2]).write(to: source)
        try Data([4, 5, 6]).write(to: destination)
        let prepared = try await prepared("move_file", ["from": source.path, "to": destination.path], service, security)
        XCTAssertTrue(prepared.preview.destinationExists)
        let cp = try await service.create(
            tool: "move_file",
            conversationID: nil,
            expected: prepared.plan,
            policy: security
        )
        let move = try await MoveFileTool().execute(
            arguments: ["from": source.path, "to": destination.path],
            invocation: security.invocation
        )
        XCTAssertFalse(move.isError)
        let finished = try await service.complete(cp)
        let restore = try await service.restorePlan(finished, policy: security)
        _ = try await service.restore(restore, policy: security, persist: { _ in })
        XCTAssertEqual(try Data(contentsOf: source), Data([0, 255, 2]))
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 5, 6]))
    }

    func testDeleteDirectoryAndSymlinkRestore() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let security = policy(), folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 0, 255]).write(to: folder.appendingPathComponent("child"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("link").path,
            withDestinationPath: "child"
        )
        let plan = try await service.plan(paths: [folder.path], policy: security)
        let cp = try await service.create(tool: "delete_file", conversationID: nil, expected: plan, policy: security)
        let deletion = try await DeleteFileTool().execute(
            arguments: ["path": folder.path],
            invocation: security.invocation
        )
        XCTAssertFalse(deletion.isError)
        if let range = deletion.content.range(of: " to Trash at ") {
            let trash = URL(fileURLWithPath: String(deletion.content[range.upperBound...].dropLast()))
            defer { try? FileManager.default.removeItem(at: trash) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        }
        let completed = try await service.complete(cp)
        let preview = try await service.restorePlan(completed, policy: security)
        _ = try await service.restore(preview, policy: security, persist: { _ in })
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("child")), Data([1, 0, 255]))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path),
            "child"
        )
    }

    func testChangesLimitsCopyFailureAndCleanupProtection() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), security = policy()
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"), limits: .init(fileBytes: 2))
        let limited = try await service.plan(paths: [file.path], policy: security)
        XCTAssertEqual(limited.reason, .limit)
        let working = CheckpointService(root: root.appendingPathComponent("working"))
        let expected = try await working.plan(paths: [file.path], policy: security)
        try Data("changed".utf8).write(to: file)
        do { _ = try await working.create(
            tool: "write_file",
            conversationID: nil,
            expected: expected,
            policy: security
        ); XCTFail("Expected fail-closed rejection") } catch { XCTAssertEqual(error as? CheckpointError, .changed) }
        let failureRoot = root.appendingPathComponent("failure")
        let broken = CheckpointService(root: failureRoot, copyItem: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let brokenPlan = try await broken.plan(paths: [file.path], policy: security)
        do { _ = try await broken.create(
            tool: "write_file",
            conversationID: nil,
            expected: brokenPlan,
            policy: security
        ); XCTFail("Expected fail-closed rejection") } catch { XCTAssertEqual(error as? CheckpointError, .copy) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: failureRoot.path).isEmpty)
        let fresh = try await working.plan(paths: [file.path], policy: security)
        let cp = try await working.create(tool: "write_file", conversationID: nil, expected: fresh, policy: security)
        let protected = try await working.prune(all: true)
        XCTAssertTrue(protected.isEmpty)
        _ = try await working.complete(cp)
        let removed = try await working.prune(now: Date().addingTimeInterval(31 * 86400))
        XCTAssertEqual(removed, [cp.id])
        let noSpace = CheckpointService(root: root.appendingPathComponent("space"), freeSpace: { _ in 0 })
        let low = try await noSpace.plan(paths: [file.path], policy: security)
        XCTAssertEqual(low.reason, .space)
    }

    func testBlockedPreviewRestoreAndCorruption() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), security = policy()
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let blocked = policy([.init(pattern: file.path, action: .block)])
        do { _ = try await prepared(
            "write_file",
            ["path": file.path, "mode": "overwrite", "content": "new"],
            service,
            blocked
        ); XCTFail("Expected fail-closed rejection") } catch { XCTAssertEqual(error as? CheckpointError, .blocked) }
        let plan = try await service.plan(paths: [file.path], policy: security)
        let cp = try await service.create(tool: "write_file", conversationID: nil, expected: plan, policy: security)
        _ = try await service.complete(cp)
        do { _ = try await service.restorePlan(cp, policy: blocked); XCTFail("Expected fail-closed rejection") }
        catch { XCTAssertEqual(error as? CheckpointError, .blocked) }
        var corrupt = cp
        corrupt.items[0].storedRelativePath = "../outside"
        do { _ = try await service.restorePlan(corrupt, policy: security); XCTFail("Expected fail-closed rejection") }
        catch { XCTAssertEqual(error as? CheckpointError, .corrupt) }
        corrupt = cp; corrupt.items[0].sha256 = "wrong"
        do { _ = try await service.restorePlan(corrupt, policy: security); XCTFail("Expected fail-closed rejection") }
        catch { XCTAssertEqual(error as? CheckpointError, .corrupt) }
        corrupt = cp; corrupt.items[0].originalPath = root.path + "/../bad"
        do { _ = try await service.restorePlan(corrupt, policy: security); XCTFail("Expected fail-closed rejection") }
        catch { XCTAssertEqual(error as? CheckpointError, .corrupt) }
    }
}

@MainActor extension CheckpointTests {
    func testCleanupByVolumeAndDuringRestoreKeepsActiveSnapshots() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), security = policy()
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let plan = try await service.plan(paths: [file.path], policy: security)
        let first = try await service.create(tool: "write_file", conversationID: nil, expected: plan, policy: security)
        try Data("new".utf8).write(to: file)
        let completed = try await service.complete(first)
        let restore = try await service.restorePlan(completed, policy: security)
        _ = try await service.restore(restore, policy: security) { value in
            if value.postOperation == nil {
                let removed = try await service.prune(all: true)
                XCTAssertTrue(removed.isEmpty)
                let snapshots = try await service.snapshots()
                XCTAssertEqual(snapshots.count, 2)
            }
        }
        await service.configure(totalBytes: 3, days: 30)
        let removed = try await service.prune()
        XCTAssertEqual(removed, [first.id])
        let retained = try await service.usage()
        XCTAssertEqual(retained, 3)
    }

    func testFinalSymlinkOverwriteAndAppendPathsRemainDistinct() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data("target".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "file")
        let overwrite = try CheckpointFileState.paths(
            tool: "write_file",
            arguments: ["path": link.path, "mode": "overwrite"]
        )
        let append = try CheckpointFileState.paths(tool: "write_file", arguments: ["path": link.path, "mode": "append"])
        XCTAssertEqual(overwrite, [link.path])
        XCTAssertEqual(append, [file.path])
        let service = CheckpointService(root: root.appendingPathComponent("cp")), security = policy()
        let plan = try await service.plan(paths: overwrite, policy: security)
        let snapshot = try await service.create(
            tool: "write_file",
            conversationID: nil,
            expected: plan,
            policy: security
        )
        let result = try await WriteFileTool().execute(
            arguments: ["path": link.path, "mode": "overwrite", "content": "new"],
            invocation: security.invocation
        )
        XCTAssertFalse(result.isError)
        let done = try await service.complete(snapshot)
        let preview = try await service.restorePlan(done, policy: security)
        _ = try await service.restore(preview, policy: security, persist: { _ in })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "file")
        XCTAssertEqual(try Data(contentsOf: file), Data("target".utf8))
    }

    func testPreviewTimeoutReturnsWithinTwoSeconds() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"), freeSpace: { _ in
            Thread.sleep(forTimeInterval: 3)
            return Int64.max
        })
        let start = ContinuousClock.now
        let value = try await prepared(
            "write_file",
            ["path": file.path, "mode": "overwrite", "content": "new"],
            service,
            policy()
        )
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(2600))
        XCTAssertEqual(value.preview.kind, "unavailable")
        let snapshots = try await service.snapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testReadDeniedPredictsNoRestoreWithoutReadingAndDetectsMetadataChanges() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let service = CheckpointService(root: root.appendingPathComponent("cp")), security = policy()
        let value = try await prepared(
            "write_file",
            ["path": file.path, "mode": "overwrite", "content": "new"],
            service,
            security
        )
        XCTAssertEqual(value.plan.reason, .unreadable)
        XCTAssertFalse(value.preview.canRestore)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do { try await service.verify(value.plan, policy: security); XCTFail("Changed metadata must fail") }
        catch { XCTAssertEqual(error as? CheckpointError, .changed) }
    }

    func testCheckpointStoreKeepsRecordsAfterConversationDeletion() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            Checkpoint.self,
            SecurityRule.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaultsName = "checkpoint-store-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let store = CheckpointStore(service: service, context: container.mainContext, defaults: defaults)
        let conversation = Conversation()
        container.mainContext.insert(conversation)
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let plan = try await service.plan(paths: [file.path], policy: policy())
        let value = try await service.create(
            tool: "write_file",
            conversationID: conversation.id,
            expected: plan,
            policy: policy()
        )
        try store.persist(value)
        _ = try await service.complete(value)
        container.mainContext.delete(conversation)
        try container.mainContext.save()
        try await store.maintain()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Checkpoint>()), 1)
        XCTAssertEqual(store.usage, 3)
    }

    func testSymlinkTargetChangeInvalidatesWriteDiff() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try Data("old".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target")
        let service = CheckpointService(root: root.appendingPathComponent("cp")), security = policy()
        let preview = try await prepared(
            "write_file",
            ["path": link.path, "mode": "overwrite", "content": "new"],
            service,
            security
        )
        XCTAssertEqual(preview.preview.kind, "diff")
        XCTAssertEqual(preview.plan.previewReads.count, 1)
        try Data("external".utf8).write(to: file)
        do { try await service.verify(preview.plan, policy: security); XCTFail("Changed symlink target must fail") }
        catch { XCTAssertEqual(error as? CheckpointError, .changed) }
    }

    func testTypicalOfflineSessionCheckpointVolume() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text"),
            service = CheckpointService(root: root.appendingPathComponent("cp"))
        let security = policy()
        try Data(repeating: 65, count: 128 * 1024).write(to: file)
        for index in 0 ..< 3 {
            let plan = try await service.plan(paths: [file.path], policy: security)
            let checkpoint = try await service.create(
                tool: "write_file",
                conversationID: nil,
                expected: plan,
                policy: security
            )
            try Data(repeating: UInt8(66 + index), count: 128 * 1024).write(to: file)
            _ = try await service.complete(checkpoint)
        }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        for url in [source, destination] {
            try Data(repeating: 65, count: 256 * 1024).write(to: url)
        }
        let movePlan = try await service.plan(paths: [source.path, destination.path], policy: security)
        let moveCP = try await service.create(
            tool: "move_file",
            conversationID: nil,
            expected: movePlan,
            policy: security
        )
        _ = try await MoveFileTool().execute(
            arguments: ["from": source.path, "to": destination.path],
            invocation: security.invocation
        )
        _ = try await service.complete(moveCP)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..<
            3 {
            try Data(repeating: 65, count: 128 * 1024).write(to: folder.appendingPathComponent("item-\(index)"))
        }
        let deletePlan = try await service.plan(paths: [folder.path], policy: security)
        let deleteCP = try await service.create(
            tool: "delete_file",
            conversationID: nil,
            expected: deletePlan,
            policy: security
        )
        // Simulate Trash removal here; the real Trash path is covered by the separate tool+restore test.
        try FileManager.default.removeItem(at: folder)
        _ = try await service.complete(deleteCP)
        let usage = try await service.usage(), snapshots = try await service.snapshots()
        XCTAssertEqual(usage, 1_310_720)
        XCTAssertEqual(snapshots.count, 5)
        print("Offline representative session: 5 checkpoints, payload \(usage) bytes (1.25 MiB)")
    }

    func testCopyRestoresPermissionsAndExtendedAttributes() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), security = policy()
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let bytes = Data([1, 2, 3, 4])
        let status = bytes.withUnsafeBytes { pointer in
            setxattr(file.path, "local.maclm-agent.checkpoint-test", pointer.baseAddress, pointer.count, 0, 0)
        }
        XCTAssertEqual(status, 0)
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let plan = try await service.plan(paths: [file.path], policy: security)
        let checkpoint = try await service.create(
            tool: "write_file",
            conversationID: nil,
            expected: plan,
            policy: security
        )
        try Data("new".utf8).write(to: file, options: .atomic)
        let completed = try await service.complete(checkpoint)
        let preview = try await service.restorePlan(completed, policy: security)
        _ = try await service.restore(preview, policy: security, persist: { _ in })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        var restored = [UInt8](repeating: 0, count: 4)
        let read = getxattr(file.path, "local.maclm-agent.checkpoint-test", &restored, restored.count, 0, 0)
        XCTAssertEqual(read, 4)
        XCTAssertEqual(Data(restored), bytes)
    }

    func testTracePrefersExactIDsOverOrderAndArguments() {
        let first = ToolCall(toolName: "write_file", argumentsJSON: "{}", status: .failed)
        let second = ToolCall(toolName: "write_file", argumentsJSON: "{}", status: .completed)
        let blocked = AuditEntry(AuditRecord(
            toolName: "write_file",
            argumentsJSON: "different",
            decision: .blocked,
            toolCallID: first.id
        ))
        let allowed = AuditEntry(AuditRecord(
            toolName: "write_file",
            argumentsJSON: "{}",
            riskLevel: .dangerous,
            decision: .approved,
            toolCallID: second.id
        ))
        XCTAssertEqual(
            TraceIncidents.count(calls: [first, second], audits: [allowed, blocked]),
            TraceIncidents(rejected: 0, blocked: 1, dangerous: 1, errors: 0)
        )
    }
}
