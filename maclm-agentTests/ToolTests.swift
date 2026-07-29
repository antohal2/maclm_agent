import Foundation
@testable import maclm_agent
import XCTest

final class ToolTests: XCTestCase {
    func testToolRegistryRegistersAndFindsTool() {
        var registry = ToolRegistry()

        registry.register(ReadFileTool())

        XCTAssertEqual(registry.tool(named: "read_file")?.name, "read_file")
        XCTAssertNil(registry.tool(named: "missing_tool"))
        XCTAssertEqual(registry.definitions.map(\.function.name), ["read_file"])
    }

    func testReadOnlyRegistryContainsAllSafeTools() {
        let registry = ToolRegistry.readOnly

        XCTAssertEqual(
            registry.definitions.map(\.function.name),
            ["list_dir", "read_file", "search_files"]
        )
        XCTAssertTrue(registry.definitions.allSatisfy { definition in
            registry.tool(named: definition.function.name)?.riskLevel == .safe
        })
    }

    func testToolDefinitionSerializesAsOpenAIJSONSchema() throws {
        let definition = try XCTUnwrap(
            ToolRegistry.readOnly.definitions.first {
                $0.function.name == "read_file"
            }
        )

        let data = try JSONEncoder().encode(definition)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["type"] as? String, "function")

        let function = try XCTUnwrap(root["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "read_file")

        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], ["path"])

        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let path = try XCTUnwrap(properties["path"] as? [String: Any])
        XCTAssertEqual(path["type"] as? String, "string")
        XCTAssertNotNil(path["description"] as? String)
    }

    func testReadFileReturnsContents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "note.txt")
        try Data("локальный текст".utf8).write(to: file)

        let result = try await ReadFileTool().execute(
            arguments: ["path": file.path]
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "локальный текст")
    }

    func testReadFileReturnsErrorForMissingFile() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .path

        let result = try await ReadFileTool().execute(
            arguments: ["path": missingPath]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("File not found"))
    }

    func testListDirectoryReturnsSortedEntries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appending(path: "zeta.txt"))
        try Data().write(to: directory.appending(path: "alpha.txt"))
        try FileManager.default.createDirectory(
            at: directory.appending(path: "nested"),
            withIntermediateDirectories: false
        )

        let result = try await ListDirectoryTool().execute(
            arguments: ["path": directory.path]
        )
        let entries = try JSONDecoder().decode(
            [String].self,
            from: Data(result.content.utf8)
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(entries, ["alpha.txt", "nested/", "zeta.txt"])
    }

    func testListDirectoryReturnsErrorForMissingDirectory() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .path

        let result = try await ListDirectoryTool().execute(
            arguments: ["path": missingPath]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Directory not found"))
    }

    func testSearchFilesMatchesFilenameSubstringRecursively() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "nested")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )
        let matchingFile = nested.appending(path: "Incident-REPORT.md")
        try Data().write(to: matchingFile)
        try Data().write(to: directory.appending(path: "notes.txt"))

        let result = try await SearchFilesTool().execute(
            arguments: [
                "root": directory.path,
                "pattern": "report",
            ]
        )
        let matches = try JSONDecoder().decode(
            [String].self,
            from: Data(result.content.utf8)
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(matches, [matchingFile.path])
    }

    func testSearchFilesReturnsErrorForMissingRoot() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .path

        let result = try await SearchFilesTool().execute(
            arguments: [
                "root": missingPath,
                "pattern": "swift",
            ]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Search root not found"))
    }

    func testAgentLoopExecutesToolAndContinuesToFinalResponse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "context.txt")
        try Data("tool result".utf8).write(to: file)
        let recorder = AgentEventRecorder()
        let loop = AgentLoop(toolRegistry: .readOnly, maximumIterations: 3)

        try await loop.streamResponse(
            to: [ChatMessage(role: .user, content: "Read the file")],
            using: ToolCallingTestProvider(path: file.path)
        ) { event in
            await recorder.append(event)
        }

        let events = await recorder.events
        let execution = try XCTUnwrap(
            events.compactMap { event -> AgentToolCallExecution? in
                guard case let .toolCallsCompleted(executions) = event else {
                    return nil
                }
                return executions.first
            }
            .first
        )
        XCTAssertEqual(execution.toolCall.id, "call_test")
        XCTAssertEqual(execution.result.content, "tool result")
        XCTAssertTrue(events.contains(.assistantResponseStarted))
        XCTAssertTrue(events.contains(.contentDelta("Final: tool result")))
        XCTAssertEqual(events.last, .done)
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
}

private actor AgentEventRecorder {
    private(set) var events: [AgentLoopEvent] = []

    func append(_ event: AgentLoopEvent) {
        events.append(event)
    }
}

private struct ToolCallingTestProvider: LLMProvider {
    let name = "Tool-calling test provider"
    let path: String

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !tools.isEmpty else {
                continuation.finish(throwing: ToolCallingTestError.missingDefinitions)
                return
            }

            if let toolMessage = messages.last(where: { $0.role == .tool }) {
                continuation.yield(.contentDelta("Final: \(toolMessage.content)"))
            } else {
                continuation.yield(
                    .toolCallDelta(
                        ToolCallDelta(
                            index: 0,
                            id: "call_test",
                            type: "function",
                            functionName: "read_file",
                            argumentsDelta: #"{"path":"#
                        )
                    )
                )
                continuation.yield(
                    .toolCallDelta(
                        ToolCallDelta(
                            index: 0,
                            id: nil,
                            type: nil,
                            functionName: nil,
                            argumentsDelta: "\"\(path)\"}"
                        )
                    )
                )
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private enum ToolCallingTestError: Error {
    case missingDefinitions
}
