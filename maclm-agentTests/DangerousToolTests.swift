import Foundation
@testable import maclm_agent
import XCTest

final class DangerousToolTests: XCTestCase {
    func testAllRegistryContainsDangerousToolsMarkedForConfirmation() {
        let registry = ToolRegistry.all
        let dangerousToolNames = [
            "delete_file",
            "move_file",
            "run_shell",
            "write_file",
        ]

        XCTAssertEqual(
            registry.definitions
                .map(\.function.name)
                .filter(dangerousToolNames.contains),
            dangerousToolNames
        )
        XCTAssertTrue(dangerousToolNames.allSatisfy { name in
            registry.tool(named: name)?.riskLevel == .confirm
        })
    }

    func testWriteFileCreatesAndAppendsExactContent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "output.txt")
        let tool = WriteFileTool()

        let createResult = try await tool.execute(
            arguments: [
                "path": file.path,
                "content": " first \n",
                "mode": "create",
            ]
        )
        let appendResult = try await tool.execute(
            arguments: [
                "path": file.path,
                "content": "second",
                "mode": "append",
            ]
        )

        XCTAssertFalse(createResult.isError)
        XCTAssertFalse(appendResult.isError)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            " first \nsecond"
        )
    }

    func testWriteFileCreateReturnsErrorWhenTargetExists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "existing.txt")
        try Data("original".utf8).write(to: file)

        let result = try await WriteFileTool().execute(
            arguments: [
                "path": file.path,
                "content": "replacement",
                "mode": "create",
            ]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("File already exists"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testMoveFileMovesFileToDestination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.txt")
        let destination = directory.appending(path: "destination.txt")
        try Data("move me".utf8).write(to: source)

        let result = try await MoveFileTool().execute(
            arguments: [
                "from": source.path,
                "to": destination.path,
            ]
        )

        XCTAssertFalse(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "move me"
        )
    }

    func testMoveFileReturnsErrorForMissingSource() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "missing.txt")

        let result = try await MoveFileTool().execute(
            arguments: [
                "from": source.path,
                "to": directory.appending(path: "destination.txt").path,
            ]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Source not found"))
    }

    func testDeleteFileMovesFileToTrash() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "trash-\(UUID().uuidString).txt")
        try Data("recoverable".utf8).write(to: file)

        let result = try await DeleteFileTool().execute(
            arguments: ["path": file.path]
        )
        let trashedURL = trashURL(from: result.content)
        defer {
            if let trashedURL {
                try? FileManager.default.removeItem(at: trashedURL)
            }
        }

        XCTAssertFalse(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(trashedURL)
        XCTAssertTrue(
            trashedURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        )
    }

    func testDeleteFileReturnsErrorForMissingPath() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .path

        let result = try await DeleteFileTool().execute(
            arguments: ["path": missingPath]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("not found"))
    }

    func testRunShellCapturesOutputAndExitCode() async throws {
        let result = try await RunShellTool().execute(
            arguments: [
                "command": "printf 'out'; printf 'err' >&2",
                "timeoutSeconds": 5,
            ]
        )
        let output = try shellOutput(from: result.content)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(output["stdout"] as? String, "out")
        XCTAssertEqual(output["stderr"] as? String, "err")
        XCTAssertEqual((output["exitCode"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(output["timedOut"] as? Bool, false)
    }

    func testRunShellReturnsErrorForNonzeroExit() async throws {
        let result = try await RunShellTool().execute(
            arguments: [
                "command": "printf 'failed' >&2; exit 7",
                "timeoutSeconds": 5,
            ]
        )
        let output = try shellOutput(from: result.content)

        XCTAssertTrue(result.isError)
        XCTAssertEqual(output["stderr"] as? String, "failed")
        XCTAssertEqual((output["exitCode"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(output["timedOut"] as? Bool, false)
    }

    func testRunShellHonorsTimeout() async throws {
        let start = ContinuousClock.now

        let result = try await RunShellTool().execute(
            arguments: [
                "command": "sleep 5",
                "timeoutSeconds": 1,
            ]
        )
        let elapsed = start.duration(to: .now)
        let output = try shellOutput(from: result.content)

        XCTAssertTrue(result.isError)
        XCTAssertEqual(output["timedOut"] as? Bool, true)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testAgentLoopPausesDangerousToolUntilApproved() async throws {
        let context = try makeConfirmationContext(
            filename: "approved.txt",
            content: "approved content"
        )
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let request = await context.requestTask.value
        XCTAssertEqual(request.toolCall.function.name, "write_file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.file.path))

        await context.loop.resolveConfirmation(
            requestID: request.id,
            decision: .approved
        )
        try await context.generationTask.value

        XCTAssertEqual(
            try String(contentsOf: context.file, encoding: .utf8),
            "approved content"
        )
        let recordedExecution = await context.recorder.firstExecution
        let execution = try XCTUnwrap(recordedExecution)
        XCTAssertEqual(execution.confirmationDecision, .approved)
        XCTAssertFalse(execution.result.isError)
    }

    func testAgentLoopRejectsDangerousToolWithoutExecutingAndContinues() async throws {
        let context = try makeConfirmationContext(
            filename: "rejected.txt",
            content: "must not be written"
        )
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let request = await context.requestTask.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.file.path))

        await context.loop.resolveConfirmation(
            requestID: request.id,
            decision: .rejected
        )
        try await context.generationTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.file.path))
        let recordedExecution = await context.recorder.firstExecution
        let execution = try XCTUnwrap(recordedExecution)
        XCTAssertEqual(execution.confirmationDecision, .rejected)
        XCTAssertTrue(execution.result.isError)
        XCTAssertTrue(execution.result.content.contains("User rejected"))
        let recordedEvents = await context.recorder.events
        XCTAssertTrue(recordedEvents.contains(.contentDelta("Final after rejection")))
    }

    private func makeConfirmationContext(
        filename: String,
        content: String
    ) throws -> ConfirmationTestContext {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: filename)
        let recorder = ConfirmationEventRecorder()
        let loop = AgentLoop(
            toolRegistry: ToolRegistry(tools: [WriteFileTool()]),
            maximumIterations: 3
        )
        let provider = DangerousToolCallingTestProvider(
            path: file.path,
            content: content
        )
        let requestTask = Task {
            await recorder.nextConfirmationRequest()
        }
        let generationTask = Task {
            try await loop.streamResponse(
                to: [ChatMessage(role: .user, content: "Create the file")],
                using: provider
            ) { event in
                await recorder.append(event)
            }
        }
        return ConfirmationTestContext(
            directory: directory,
            file: file,
            recorder: recorder,
            loop: loop,
            requestTask: requestTask,
            generationTask: generationTask
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "maclm-agent-tests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func trashURL(from content: String) -> URL? {
        let prefix = " to Trash at "
        guard let range = content.range(of: prefix) else {
            return nil
        }
        let path = content[range.upperBound...].dropLast()
        return URL(fileURLWithPath: String(path))
    }

    private func shellOutput(from content: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
    }
}

private struct ConfirmationTestContext {
    let directory: URL
    let file: URL
    let recorder: ConfirmationEventRecorder
    let loop: AgentLoop
    let requestTask: Task<ConfirmationRequest, Never>
    let generationTask: Task<Void, any Error>
}

private actor ConfirmationEventRecorder {
    private(set) var events: [AgentLoopEvent] = []
    private var confirmationContinuation: CheckedContinuation<
        ConfirmationRequest,
        Never
    >?

    func append(_ event: AgentLoopEvent) {
        events.append(event)
        guard case let .confirmationRequested(request) = event else {
            return
        }
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            continuation.resume(returning: request)
        }
    }

    func nextConfirmationRequest() async -> ConfirmationRequest {
        if let request = events.compactMap({ event -> ConfirmationRequest? in
            guard case let .confirmationRequested(request) = event else {
                return nil
            }
            return request
        }).first {
            return request
        }

        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    var firstExecution: AgentToolCallExecution? {
        events.compactMap { event -> AgentToolCallExecution? in
            guard case let .toolCallsCompleted(executions) = event else {
                return nil
            }
            return executions.first
        }
        .first
    }
}

private struct DangerousToolCallingTestProvider: LLMProvider {
    let name = "Dangerous tool-calling test provider"
    let path: String
    let content: String

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard tools.map(\.function.name) == ["write_file"] else {
                continuation.finish(throwing: DangerousToolTestError.missingDefinitions)
                return
            }

            if let toolMessage = messages.last(where: { $0.role == .tool }) {
                let response = toolMessage.content.contains("User rejected")
                    ? "Final after rejection"
                    : "Final after approval"
                continuation.yield(.contentDelta(response))
            } else {
                yieldToolCall(to: continuation)
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }

    private func yieldToolCall(
        to continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) {
        let arguments: [String: Any] = [
            "path": path,
            "content": content,
            "mode": "create",
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: arguments),
            let argumentsJSON = String(data: data, encoding: .utf8)
        else {
            continuation.finish(throwing: DangerousToolTestError.invalidArguments)
            return
        }
        continuation.yield(
            .toolCallDelta(
                ToolCallDelta(
                    index: 0,
                    id: "dangerous_call",
                    type: "function",
                    functionName: "write_file",
                    argumentsDelta: argumentsJSON
                )
            )
        )
    }
}

private enum DangerousToolTestError: Error {
    case missingDefinitions
    case invalidArguments
}
