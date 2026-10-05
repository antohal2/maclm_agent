import Foundation
@testable import maclm_agent
import XCTest

@MainActor
final class SessionPermissionsTests: XCTestCase {
    func testOnlyCautionCanBeRememberedAndResetClearsEverything() {
        let memory = SessionPermissions()
        memory.remember(toolName: "write_file", riskLevel: .caution)
        memory.remember(toolName: "write_file", riskLevel: .dangerous)
        memory.remember(toolName: "run_shell", riskLevel: .dangerous)
        memory.remember(toolName: "read_file", riskLevel: .safe)
        XCTAssertTrue(memory.allows(toolName: "write_file", riskLevel: .caution))
        XCTAssertFalse(memory.allows(toolName: "write_file", riskLevel: .dangerous))
        XCTAssertFalse(memory.allows(toolName: "move_file", riskLevel: .caution))
        XCTAssertFalse(memory.allows(toolName: "run_shell", riskLevel: .dangerous))
        XCTAssertEqual(memory.sortedPermissions, [.init(toolName: "write_file", riskLevel: .caution)])
        memory.reset()
        XCTAssertTrue(memory.permissions.isEmpty)
        XCTAssertFalse(memory.allows(toolName: "write_file", riskLevel: .caution))
        XCTAssertTrue(SessionPermissions().permissions.isEmpty)
    }

    func testDirectoryAdditionCanonicalizesDeduplicatesAndPersists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let name = "AllowedDirectories-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.allowedDirectories.isEmpty)
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.allowed)
        XCTAssertTrue(settings.addAllowedDirectory(link.path + "/."))
        XCTAssertEqual(settings.allowedDirectories, [PathCanonicalizer.canonicalize(fixture.allowed.path)])
        XCTAssertFalse(settings.addAllowedDirectory(fixture.allowed.path))
        XCTAssertFalse(settings.addAllowedDirectory(fixture.allowed.path + "/missing"))
        XCTAssertEqual(AppSettings(defaults: defaults).allowedDirectories, settings.allowedDirectories)
        settings.removeAllowedDirectory(at: 0)
        XCTAssertTrue(AppSettings(defaults: defaults).allowedDirectories.isEmpty)
        XCTAssertTrue(AppSettings.isBroadDirectory("/"))
        XCTAssertTrue(AppSettings.isBroadDirectory("~"))
        XCTAssertFalse(AppSettings.isBroadDirectory(fixture.allowed.path))
    }

    func testAddedDirectoryControlsRiskImmediatelyAndEmptyMeansDangerous() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let name = "AllowedRisk-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        func risk(_ path: String) -> RiskLevel {
            ToolRiskEvaluator.evaluate(WriteFileTool(), arguments: ["path": path],
                                      context: .init(allowedDirectories: settings.allowedDirectories)).level
        }
        let inside = fixture.allowed.appendingPathComponent("file").path
        let outside = fixture.root.appendingPathComponent("outside").path
        XCTAssertEqual(risk(inside), .dangerous)
        XCTAssertTrue(settings.addAllowedDirectory(fixture.allowed.path))
        XCTAssertEqual(risk(inside), .caution)
        XCTAssertEqual(risk(outside), .dangerous)
        settings.removeAllowedDirectory(at: 0)
        XCTAssertEqual(risk(inside), .dangerous)
    }

    func testRememberedCautionDoesNotLeakToElevatedCallsOrShell() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inside = fixture.allowed.appendingPathComponent("inside.txt").path
        let outside = fixture.root.appendingPathComponent("outside.txt").path
        let calls = [
            try call("write_file", ["path": inside, "content": "first", "mode": "overwrite"]),
            try call("write_file", ["path": inside, "content": "second", "mode": "overwrite"]),
            try call("write_file", ["path": outside, "content": "outside", "mode": "overwrite"]),
            try call("write_file", ["path": outside, "content": "outside", "mode": "overwrite"]),
            try call("run_shell", ["command": "printf session-test"]),
            try call("run_shell", ["command": "printf session-test"]),
            try call("read_file", ["path": inside]),
        ]
        let memory = SessionPermissions()
        let context = ToolRiskContext(allowedDirectories: [fixture.allowed.path])
        let loop = AgentLoop(maximumIterations: 12, sessionPermissions: memory,
                             riskContext: { context }, securityRules: { [] })
        let recorder = SessionEventRecorder()
        try await loop.streamResponse(to: [.init(role: .user, content: "test")],
                                      using: SessionCallingProvider(calls: calls)) { event in
            await recorder.append(event)
            if case let .confirmationRequested(request) = event {
                await loop.resolveConfirmation(requestID: request.id, decision: .approved, rememberForSession: true)
            }
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.filter { $0.toolCall.function.name == "write_file" }.map(\.riskLevel), [.caution, .dangerous, .dangerous])
        XCTAssertEqual(requests.filter { $0.toolCall.function.name == "run_shell" }.map(\.riskLevel), [.dangerous, .dangerous])
        XCTAssertFalse(requests.contains { $0.toolCall.function.name == "read_file" })
        XCTAssertEqual(memory.sortedPermissions, [.init(toolName: "write_file", riskLevel: .caution)])
        XCTAssertEqual(try String(contentsOfFile: inside, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "outside")
    }

    func testResetRestoresConfirmationAndRejectDoesNotRememberOrExecute() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.allowed.appendingPathComponent("rejected.txt").path
        let memory = SessionPermissions()
        memory.remember(toolName: "write_file", riskLevel: .caution)
        memory.reset()
        let context = ToolRiskContext(allowedDirectories: [fixture.allowed.path])
        let loop = AgentLoop(sessionPermissions: memory, riskContext: { context }, securityRules: { [] })
        let recorder = SessionEventRecorder()
        let calls = [try call("write_file", ["path": file, "content": "never", "mode": "overwrite"])]
        try await loop.streamResponse(to: [.init(role: .user, content: "test")],
                                      using: SessionCallingProvider(calls: calls)) { event in
            await recorder.append(event)
            if case let .confirmationRequested(request) = event {
                await loop.resolveConfirmation(requestID: request.id, decision: .rejected, rememberForSession: true)
            }
        }
        let requests = await recorder.requests
        let results = await recorder.results
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(memory.permissions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertEqual(results.first?.isError, true)
        XCTAssertTrue(results.first?.content.contains("User rejected execution") == true)
    }

    func testBlockStillWinsOverRememberedCaution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let memory = SessionPermissions()
        memory.remember(toolName: "write_file", riskLevel: .caution)
        let pattern = fixture.allowed.path + "/**"
        let context = ToolRiskContext(allowedDirectories: [fixture.allowed.path])
        let loop = AgentLoop(sessionPermissions: memory, riskContext: { context },
                             securityRules: { [.init(pattern: pattern, action: .block)] })
        let recorder = SessionEventRecorder()
        let file = fixture.allowed.appendingPathComponent("blocked.txt").path
        try await loop.streamResponse(to: [.init(role: .user, content: "test")],
                                      using: SessionCallingProvider(calls: [try call("write_file", ["path": file, "content": "never", "mode": "overwrite"])])) {
            await recorder.append($0)
        }
        let requests = await recorder.requests
        let results = await recorder.results
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(results.first?.isError, true)
        XCTAssertTrue(results.first?.content.contains("Запрещено правилом") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    private func call(_ name: String, _ arguments: [String: String]) throws -> SessionTestCall {
        .init(name: name, json: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))
    }

    private func makeFixture() throws -> (root: URL, allowed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-" + UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        return (root, allowed)
    }
}

private struct SessionTestCall: Sendable { let name: String; let json: String }
private actor SessionEventRecorder {
    private var events: [AgentLoopEvent] = []
    var requests: [ConfirmationRequest] {
        events.compactMap { if case let .confirmationRequested(request) = $0 { request } else { nil } }
    }
    var results: [ToolExecutionResult] {
        events.flatMap { event -> [ToolExecutionResult] in
            if case let .toolCallsCompleted(items) = event { return items.map(\.result) }
            return []
        }
    }
    func append(_ event: AgentLoopEvent) { events.append(event) }
}
private struct SessionCallingProvider: LLMProvider {
    let name = "Session memory regression provider"
    let calls: [SessionTestCall]
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let index = messages.filter { $0.role == .tool }.count
            if index < calls.count {
                let call = calls[index]
                continuation.yield(.toolCallDelta(.init(index: 0, id: "session-\(index)", type: "function", functionName: call.name, argumentsDelta: call.json)))
            } else {
                continuation.yield(.contentDelta(messages.last(where: { $0.role == .tool })?.content ?? "done"))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
