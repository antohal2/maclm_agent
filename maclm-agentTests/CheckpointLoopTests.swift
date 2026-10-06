import Foundation
@testable import maclm_agent
import XCTest

@MainActor final class CheckpointLoopTests: XCTestCase {
    func testRememberedCallWithoutCheckpointRequiresApprovalAndRejectDoesNotWrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"), limits: .init(fileBytes: 2))
        let memory = SessionPermissions()
        memory.remember(conversationID: legacyConversationID, toolName: "write_file", riskLevel: .caution)
        let recorder = CheckpointLoopRecorder()
        let loop = AgentLoop(
            checkpoints: service,
            sessionPermissions: memory,
            riskContext: { .init(allowedDirectories: [root.path]) },
            auditSink: { record in recorder.audits.append(record) },
            securityRules: { [] }
        )
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: CheckpointCallingProvider(path: file.path)
        ) { event in
            await recorder.record(event)
            if case let .confirmationRequested(request) = event {
                XCTAssertEqual(request.filePreview?.rollbackReason, CheckpointError.limit.rawValue)
                XCTAssertEqual(request.riskLevel, .caution)
                XCTAssertEqual(try? Data(contentsOf: file), Data("old".utf8))
                await loop.resolveConfirmation(requestID: request.id, decision: .rejected)
            }
        }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
        XCTAssertEqual(recorder.audits.first?.toolCallID, recorder.requests.first?.id)
        XCTAssertEqual(recorder.audits.first?.decision, .rejected)
    }

    func testLimitWithExplicitApprovalWritesWithoutCheckpoint() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"), limits: .init(fileBytes: 2))
        let recorder = CheckpointLoopRecorder()
        let loop = AgentLoop(
            checkpoints: service,
            auditSink: { record in recorder.audits.append(record) },
            securityRules: { [] }
        )
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: CheckpointCallingProvider(path: file.path)
        ) { event in
            await recorder.record(event)
            if case let .confirmationRequested(request) = event {
                XCTAssertFalse(request.filePreview?.canRestore ?? true)
                await loop.resolveConfirmation(requestID: request.id, decision: .approved)
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        XCTAssertNil(recorder.audits.first?.checkpointID)
        let snapshots = try await service.snapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testPromisedCheckpointCopyFailureNeverExecutesAndRemovesFragments() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), cpRoot = root.appendingPathComponent("cp")
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: cpRoot, copyItem: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let recorder = CheckpointLoopRecorder()
        let loop = AgentLoop(
            checkpoints: service,
            auditSink: { record in recorder.audits.append(record) },
            securityRules: { [] }
        )
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: CheckpointCallingProvider(path: file.path)
        ) { event in
            await recorder.record(event)
            if case let .confirmationRequested(request) = event {
                XCTAssertTrue(request.filePreview?.canRestore ?? false)
                await loop.resolveConfirmation(requestID: request.id, decision: .approved)
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cpRoot.path).isEmpty)
        XCTAssertEqual(recorder.audits.first?.outcome, .failure)
        XCTAssertTrue(recorder.executions.first?.result.isError ?? false)
    }

    func testChangedAfterApprovalAndCancellationAtStartPreventExecution() async throws {
        for cancel in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("file")
            try Data("old".utf8).write(to: file)
            let service = CheckpointService(root: root.appendingPathComponent("cp"))
            let recorder = CheckpointLoopRecorder()
            let loop = AgentLoop(
                checkpoints: service,
                auditSink: { record in recorder.audits.append(record) },
                securityRules: { [] }
            )
            let task = Task {
                try await loop.streamResponse(
                    to: [.init(role: .user, content: "test")],
                    using: CheckpointCallingProvider(path: file.path)
                ) { event in
                    await recorder.record(event)
                    if case let .confirmationRequested(request) = event {
                        await loop.resolveConfirmation(requestID: request.id, decision: .approved)
                    }
                    if case .toolExecutionStarted = event {
                        if cancel {
                            withUnsafeCurrentTask { $0?.cancel() }
                        } else {
                            try? Data("external".utf8).write(to: file)
                        }
                    }
                }
            }
            do { try await task.value; XCTAssertFalse(cancel) } catch {
                XCTAssertTrue(cancel); XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(try Data(contentsOf: file), Data((cancel ? "old" : "external").utf8))
            let snapshots = try await service.snapshots()
            XCTAssertTrue(snapshots.isEmpty)
            if !cancel {
                XCTAssertTrue(recorder.executions.first?.result.content.contains("Файл изменился") ?? false)
            }
        }
    }

    func testSuccessfulCallPersistsCheckpointBeforeToolAndExactAuditID() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let service = CheckpointService(root: root.appendingPathComponent("cp"))
        let recorder = CheckpointLoopRecorder()
        let loop = AgentLoop(checkpoints: service, checkpointSink: { value in
            recorder.checkpoints.append(value)
            if value.postOperation == nil {
                XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
            }
        }, auditSink: { record in recorder.audits.append(record) }, securityRules: { [] })
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: CheckpointCallingProvider(path: file.path)
        ) { event in
            await recorder.record(event)
            if case let .confirmationRequested(request) = event {
                await loop.resolveConfirmation(requestID: request.id, decision: .approved)
            }
        }
        XCTAssertEqual(recorder.checkpoints.count, 2)
        XCTAssertEqual(recorder.audits.first?.checkpointID, recorder.checkpoints.first?.id)
        XCTAssertEqual(recorder.audits.first?.toolCallID, recorder.requests.first?.id)
        XCTAssertEqual(recorder.executions.first?.persistentCallID, recorder.requests.first?.id)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-loop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: PathCanonicalizer.canonicalize(path.path))
    }
}

@MainActor private final class CheckpointLoopRecorder {
    var requests: [ConfirmationRequest] = []
    var executions: [AgentToolCallExecution] = []
    var audits: [AuditRecord] = []
    var checkpoints: [CheckpointSnapshot] = []
    func record(_ event: AgentLoopEvent) {
        if case let .confirmationRequested(request) = event {
            requests.append(request)
        }
        if case let .toolCallsCompleted(values) = event {
            executions += values
        }
    }
}

private struct CheckpointCallingProvider: LLMProvider {
    let name = "Checkpoint fixture"
    let path: String
    func streamChat(messages: [ChatMessage], tools _: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if messages.contains(where: { $0.role == .tool }) {
                continuation.yield(.contentDelta("Finished"))
            } else {
                // Existing deterministic JSON test fixture; preserve test semantics.
                // swiftlint:disable:next force_try
                let data = try! JSONSerialization.data(withJSONObject: [
                    "path": path,
                    "mode": "overwrite",
                    "content": "new",
                ])
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "fixture",
                    type: "function",
                    functionName: "write_file",
                    // Test helper encodes JSON as UTF-8; preserve existing test semantics.
                    // swiftlint:disable:next optional_data_string_conversion
                    argumentsDelta: String(decoding: data, as: UTF8.self)
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
