import Foundation
@testable import maclm_agent
import XCTest

final class RiskLevelTests: XCTestCase {
    private func assess(_ tool: any Tool, _ arguments: [String: Any] = [:], dirs: [String] = []) -> RiskAssessment {
        ToolRiskEvaluator.evaluate(tool, arguments: arguments, context: .init(allowedDirectories: dirs))
    }

    func testRiskSemanticsAndCoding() throws {
        for level in RiskLevel.allCases {
            XCTAssertEqual(level.requiresConfirmation, level != .safe)
            XCTAssertEqual(level.canBeRemembered, level == .caution)
            XCTAssertEqual(try JSONDecoder().decode(RiskLevel.self, from: JSONEncoder().encode(level)), level)
        }
        XCTAssertLessThan(RiskLevel.safe, .caution)
        XCTAssertLessThan(RiskLevel.caution, .dangerous)
    }

    func testCannotLowerBaseRisk() {
        XCTAssertEqual(assess(LoweringTool()).level, .caution)
    }

    func testUniversalAndUndeclaredToolsFailClosed() {
        for tool: any Tool in [UniversalTool(), UndeclaredTool()] {
            let result = assess(tool)
            XCTAssertEqual(result.level, .dangerous)
            XCTAssertFalse(result.level.canBeRemembered)
            XCTAssertEqual(result.reason, "аргумент — произвольный код, политика неприменима")
        }
    }

    func testWriteAndMoveElevation() {
        let dirs = ["/tmp/maclm-allowed"]
        XCTAssertEqual(assess(WriteFileTool(), ["path": dirs[0] + "/file"], dirs: dirs).level, .caution)
        for path in ["/tmp/outside", "/tmp/maclm-allowed-other/file", dirs[0] + "/../outside"] {
            XCTAssertEqual(assess(WriteFileTool(), ["path": path], dirs: dirs).level, .dangerous)
            for args in [["from": path, "to": dirs[0] + "/file"], ["from": dirs[0] + "/file", "to": path]] {
                XCTAssertEqual(assess(MoveFileTool(), args, dirs: dirs).level, .dangerous)
            }
        }
        XCTAssertEqual(assess(MoveFileTool(), ["from": dirs[0] + "/a", "to": dirs[0] + "/b"], dirs: dirs).level, .caution)
        XCTAssertEqual(assess(WriteFileTool(), ["path": "/tmp/file"]).level, .dangerous)
    }

    @MainActor
    func testMoveOverwriteRiskAndSessionMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let file = root.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path + "/missing")
        let memory = SessionPermissions()
        let id = UUID()
        memory.remember(conversationID: id, toolName: "move_file", riskLevel: .caution)
        for destination in [file, directory, link] {
            for dirs in [[root.path], []] {
                let risk = assess(MoveFileTool(), ["from": source.path, "to": destination.path], dirs: dirs)
                XCTAssertEqual(risk.level, .dangerous)
                XCTAssertEqual(risk.reason, "Назначение существует: файл будет перезаписан")
                XCTAssertFalse(memory.allows(conversationID: id, toolName: "move_file", riskLevel: risk.level))
                XCTAssertFalse(risk.level.canBeRemembered)
            }
        }
        XCTAssertEqual(assess(MoveFileTool(), ["from": source.path, "to": root.path + "/new"], dirs: [root.path]).level, .caution)
        XCTAssertEqual(assess(MoveFileTool(), ["from": source.path, "to": "  " + file.path + "\n"], dirs: [root.path]).level, .dangerous)
        let alias = root.appendingPathComponent("SOURCE.TXT")
        guard FileManager.default.fileExists(atPath: alias.path) else {
            throw XCTSkip("Requires case-insensitive filesystem")
        }
        XCTAssertEqual(assess(MoveFileTool(), ["from": source.path, "to": alias.path], dirs: [root.path]).level, .caution)
        let moved = try await MoveFileTool().execute(arguments: ["from": source.path, "to": alias.path])
        XCTAssertFalse(moved.isError)
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "source")
        // A link to the source is a distinct leaf object and must still elevate.
        let liveLink = root.appendingPathComponent("live-link")
        try FileManager.default.createSymbolicLink(at: liveLink, withDestinationURL: source)
        XCTAssertEqual(assess(MoveFileTool(), ["from": source.path, "to": liveLink.path], dirs: [root.path]).level, .dangerous)
    }

    func testSafeToolsNeverElevate() {
        for tool: any Tool in [ReadFileTool(), ListDirectoryTool(), SearchFilesTool()] {
            for args: [String: Any] in [[:], ["path": "/etc/passwd"], ["path": "../../*"], ["path": 42], ["query": "*"]] {
                XCTAssertEqual(assess(tool, args).level, .safe)
            }
        }
    }

    func testRealRegistryClasses() throws {
        let registry = ToolRegistry.all
        for definition in registry.definitions {
            let tool = try XCTUnwrap(registry.tool(named: definition.function.name))
            // v0.2.5 already includes shell, which is intentionally universal.
            if tool is RunShellTool {
                XCTAssertFalse(type(of: tool).isPolicyEnforceable)
                XCTAssertEqual(assess(tool).level, .dangerous)
            } else {
                XCTAssertTrue(type(of: tool).isPolicyEnforceable, tool.name)
            }
        }
    }

    func testDeleteReasonsAndSymlinkBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(assess(DeleteFileTool(), ["path": root.path]).reason, "путь указывает на директорию")
        XCTAssertEqual(assess(DeleteFileTool(), ["path": root.path + "/*"]).reason, "путь содержит wildcard")
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(assess(WriteFileTool(), ["path": link.appendingPathComponent("outside").path], dirs: [root.path]).level, .dangerous)
    }

    func testAgentLoopConfirmationBoundaryForEveryRealTool() async throws {
        let registry = ToolRegistry.all
        for definition in registry.definitions {
            let tool = try XCTUnwrap(registry.tool(named: definition.function.name))
            let loop = AgentLoop(toolRegistry: registry)
            let recorder = RiskEventRecorder()
            try await loop.streamResponse(
                to: [ChatMessage(role: .user, content: "test")],
                using: RiskCallingProvider(toolName: tool.name)
            ) { event in
                await recorder.append(event)
                if case let .confirmationRequested(request) = event {
                    await loop.resolveConfirmation(requestID: request.id, decision: .rejected)
                }
            }
            let events = await recorder.events
            let confirmations = events.compactMap { event -> ConfirmationRequest? in
                if case let .confirmationRequested(request) = event { return request }
                return nil
            }
            XCTAssertEqual(confirmations.count, type(of: tool).baseRiskLevel.requiresConfirmation ? 1 : 0, tool.name)
            XCTAssertTrue(events.contains(.done), tool.name)
        }
    }

    @MainActor
    func testAllowedDirectoriesPersist() throws {
        let name = "RiskLevelTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.allowedDirectories, [])
        settings.allowedDirectories = ["/tmp/allowed"]
        XCTAssertEqual(AppSettings(defaults: defaults).allowedDirectories, ["/tmp/allowed"])
    }
}

private struct LoweringTool: Tool {
    static let baseRiskLevel = RiskLevel.caution
    static let isPolicyEnforceable = true
    let name = "lowering_test"
    let description = "Test only"
    var parametersSchema: JSONSchema { .object(properties: [:], required: []) }
    func computeRisk(arguments: [String: Any], context: ToolRiskContext) -> RiskAssessment {
        .init(level: .safe)
    }
    func execute(
        arguments: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult { .success(content: "test") }
}

private struct UniversalTool: Tool {
    static let baseRiskLevel = RiskLevel.safe
    static let isPolicyEnforceable = false
    let name = "universal_test"
    let description = "Test only"
    var parametersSchema: JSONSchema { .object(properties: [:], required: []) }
    func computeRisk(arguments: [String: Any], context: ToolRiskContext) -> RiskAssessment { .init(level: .safe) }
    func execute(
        arguments: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult { .success(content: "test") }
}

private struct UndeclaredTool: Tool {
    static let baseRiskLevel = RiskLevel.safe
    let name = "undeclared_test"
    let description = "Test only"
    var parametersSchema: JSONSchema { .object(properties: [:], required: []) }
    func execute(
        arguments: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult { .success(content: "test") }
}

private actor RiskEventRecorder {
    private(set) var events: [AgentLoopEvent] = []
    func append(_ event: AgentLoopEvent) { events.append(event) }
}

private struct RiskCallingProvider: LLMProvider {
    let name = "Risk regression provider"
    let toolName: String
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if !messages.contains(where: { $0.role == .tool }) {
                continuation.yield(.toolCallDelta(ToolCallDelta(
                    index: 0, id: "risk_call", type: "function", functionName: toolName, argumentsDelta: "{}"
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
