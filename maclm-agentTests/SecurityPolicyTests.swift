import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class SecurityPolicyTests: XCTestCase {
    private func engine(_ rules: [SecurityRuleSnapshot]) -> SecurityPolicyEngine {
        SecurityPolicyEngine(rules: rules)
    }

    private func block(_ pattern: String, order: Int = 0) -> SecurityRuleSnapshot {
        .init(pattern: pattern, action: .block, order: order)
    }

    func testCanonicalizationBeforeMatching() {
        let policy = engine(DefaultSecurityRules.rules)
        let decision = policy.decision(for: "~/../../etc/passwd", dimension: .path)
        XCTAssertEqual(decision.disposition, .blocked)
        XCTAssertEqual(decision.rule?.pattern, "/private/**")
        XCTAssertTrue(PathCanonicalizer.canonicalize("~/../../etc/passwd").hasPrefix("/private/"))
        XCTAssertEqual(policy.decision(for: "~/.ssh/id_rsa", dimension: .path).rule?.pattern, "~/.ssh/**")
    }

    func testSymlinkAndMissingTargetCanonicalization() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("blocked"))
        let policy = engine([block(root.appendingPathComponent("blocked").path + "/**")])
        XCTAssertFalse(policy.decision(for: link.appendingPathComponent("missing/new.txt").path, dimension: .path)
            .isAllowed)
        XCTAssertFalse(policy.decision(for: link.path, dimension: .path).isAllowed)
        XCTAssertEqual(
            PathCanonicalizer.canonicalize(link.path + "/../visible.txt"),
            root.appendingPathComponent("visible.txt").path
        )
        let systemLink = root.appendingPathComponent("system")
        try FileManager.default.createSymbolicLink(at: systemLink, withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertFalse(engine(DefaultSecurityRules.rules).decision(for: systemLink.path + "/passwd", dimension: .path)
            .isAllowed)
    }

    func testCaseSensitivityMatchesVolume() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = engine([block(root.path + "/VISIBLE.TXT")])
        XCTAssertEqual(
            policy.decision(for: root.path + "/visible.txt", dimension: .path).isAllowed,
            PathCanonicalizer.isCaseSensitive(root.path)
        )
    }

    func testExecutionPreservesSymlinkAndChecksBothTraversalForms() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("blocked/nested/secret.txt")
        let link = root.appendingPathComponent("file-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let policy = engine([block(target.path)])
        for tool: any Tool in [WriteFileTool(), DeleteFileTool(), ReadFileTool()] {
            let args = ["path": link.path]
            let prepared = try XCTUnwrap(policy.executionArguments(for: tool, arguments: args)["path"] as? String)
            XCTAssertEqual(URL(fileURLWithPath: prepared).lastPathComponent, "file-link")
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: prepared)[.type] as? FileAttributeType,
                .typeSymbolicLink
            )
            XCTAssertFalse(policy.decision(for: tool, arguments: args).isAllowed)
        }
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(
            at: directoryLink,
            withDestinationURL: root.appendingPathComponent("blocked/nested")
        )
        let args = ["path": directoryLink.path + "/../visible.txt"]
        // Existing tools normalize '..' lexically to root/visible.txt, while
        // POSIX traversal resolves to root/blocked/visible.txt. Check both.
        XCTAssertFalse(engine([block(root.path + "/visible.txt")]).decision(for: ReadFileTool(), arguments: args)
            .isAllowed)
        XCTAssertFalse(engine([block(root.path + "/blocked/**")]).decision(for: ReadFileTool(), arguments: args)
            .isAllowed)
    }

    func testGlobSemantics() {
        XCTAssertTrue(PathGlob.matches("/a/b/c/file", pattern: "/a/**"))
        XCTAssertTrue(PathGlob.matches("/a", pattern: "/a/**"))
        XCTAssertTrue(PathGlob.matches("/a/file", pattern: "/a/*"))
        XCTAssertFalse(PathGlob.matches("/a/b/file", pattern: "/a/*"))
        XCTAssertTrue(PathGlob.matches("/a/f1", pattern: "/a/f?"))
        XCTAssertFalse(PathGlob.matches("/a/f/", pattern: "/a/f?"))
        XCTAssertTrue(PathGlob.matches("/.env", pattern: "**/.env"))
        XCTAssertTrue(PathGlob.matches("/a/b/.git/config", pattern: "**/.git/config"))
        XCTAssertFalse(PathGlob.matches("/a/file", pattern: "/a/(file|other)"))
    }

    func testBlockPriorityDisabledRulesAndDirectoryInheritance() {
        let policy = engine([
            .init(pattern: "/policy-root/**", action: .allow, order: 0),
            block("/policy-root/private", order: 10),
            block("/policy-root/private/**", order: 20),
            .init(pattern: "/policy-root/public/**", action: .block, isEnabled: false),
        ])
        let blocked = policy.decision(for: "/policy-root/private/child/file", dimension: .path)
        XCTAssertEqual(blocked.disposition, .blocked)
        XCTAssertEqual(blocked.rule?.order, 10)
        XCTAssertEqual(policy.decision(for: "/policy-root/public/file", dimension: .path).disposition, .allowed)
        XCTAssertEqual(policy.decision(for: "/other/file", dimension: .path), .noDecision)
    }

    func testOtherDimensionsHaveNoDecision() {
        for dimension in RuleDimension.allCases where dimension != .path {
            let policy = engine([.init(dimension: dimension, pattern: "**", action: .block)])
            XCTAssertEqual(policy.decision(for: "anything", dimension: dimension), .noDecision)
        }
    }

    func testMoveChecksBothPathsAndAllowNeverLowersRisk() {
        let policy = engine([block("/policy-root/blocked/**"), .init(pattern: "/policy-root/**", action: .allow)])
        for arguments in [
            ["from": "/policy-root/blocked/source", "to": "/policy-root/public/dest"],
            ["from": "/policy-root/public/source", "to": "/policy-root/blocked/dest"],
        ] {
            XCTAssertFalse(policy.decision(for: MoveFileTool(), arguments: arguments).isAllowed)
        }
        let arguments = ["path": "/policy-root/public/file"]
        XCTAssertEqual(policy.decision(for: WriteFileTool(), arguments: arguments).disposition, .allowed)
        XCTAssertEqual(
            ToolRiskEvaluator.evaluate(WriteFileTool(), arguments: arguments, context: .init()).level,
            .dangerous
        )
    }

    func testBuiltInSystemBoundariesAndSecrets() {
        let policy = engine(DefaultSecurityRules.rules)
        for path in [
            "/usr/bin/tool",
            "/bin/tool",
            "/tmp/test",
            "/var/test",
            "/etc/passwd",
            "~/.aws/new",
            "~/Library/Keychains/new",
            "/somewhere/.env",
            "/somewhere/.git/config",
        ] {
            XCTAssertFalse(policy.decision(for: path, dimension: .path).isAllowed, path)
        }
        XCTAssertEqual(policy.decision(for: "/usr/local/tool", dimension: .path), .noDecision)
        XCTAssertEqual(policy.decision(for: "/usr/local/share/new", dimension: .path), .noDecision)
    }

    func testDirectoryTraversalFiltersBlockedChildrenAndSymlinks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: root.appendingPathComponent("blocked")
        )
        let policy = engine([block(root.appendingPathComponent("blocked").path + "/**")])
        let listing = try await ListDirectoryTool().execute(arguments: ["path": root.path], policy: policy)
        XCTAssertFalse(listing.isError)
        XCTAssertFalse(listing.content.contains("blocked"))
        XCTAssertFalse(listing.content.contains("alias"))
        XCTAssertTrue(listing.content.contains("visible.txt"))
        let search = try await SearchFilesTool().execute(
            arguments: ["root": root.path, "pattern": ".txt"],
            policy: policy
        )
        XCTAssertFalse(search.isError)
        XCTAssertFalse(search.content.contains("secret"))
        XCTAssertFalse(search.content.contains("blocked"))
        XCTAssertFalse(search.content.contains("private-content"))
        XCTAssertTrue(search.content.contains("visible.txt"))
    }

    func testAllFileToolsBlockedBeforeConfirmationAndExecution() async throws {
        let registry = ToolRegistry.all
        for (name, arguments) in [
            ("read_file", ["path": "~/.ssh/id_rsa"]),
            ("write_file", ["path": "~/.ssh/new", "content": "never", "mode": "overwrite"]),
            ("delete_file", ["path": "~/.ssh/id_rsa"]),
            ("list_dir", ["path": "~/.ssh"]),
            ("search_files", ["root": "~/.ssh", "pattern": "id"]),
            ("move_file", ["from": "/a", "to": "~/.ssh/new"]),
            ("move_file", ["from": "~/.ssh/id_rsa", "to": "/a"]),
        ] {
            let recorder = PolicyEventRecorder()
            let loop = AgentLoop(toolRegistry: registry)
            // Test helper encodes JSON as UTF-8; preserve existing test semantics.
            // swiftlint:disable:next optional_data_string_conversion
            let json = try String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            try await loop.streamResponse(
                to: [.init(role: .user, content: "test")],
                using: PolicyCallingProvider(toolName: name, json: json)
            ) { event in
                await recorder.append(event)
                // Avoid hanging if confirmation regresses; then assert it was absent.
                if case let .confirmationRequested(request) = event {
                    await loop.resolveConfirmation(requestID: request.id, decision: .rejected)
                }
            }
            let events = await recorder.events
            XCTAssertFalse(events.contains {
                if case .confirmationRequested = $0 {
                    true
                } else {
                    false
                }
            }, name)
            let executions = events.flatMap { event -> [AgentToolCallExecution] in
                if case let .toolCallsCompleted(items) = event {
                    return items
                }
                return []
            }
            let result = try XCTUnwrap(executions.first?.result)
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.content.contains("~/.ssh/**"), name)
            XCTAssertTrue(result.content.contains("Запрещено правилом"), name)
        }
    }

    func testShellSkipsPathRulesButStillRequiresConfirmation() async throws {
        let arguments = ["command": "cat ~/.ssh/id_rsa"]
        let policy = engine(DefaultSecurityRules.rules)
        XCTAssertEqual(policy.decision(for: RunShellTool(), arguments: arguments), .noDecision)
        XCTAssertEqual(
            policy.executionArguments(for: RunShellTool(), arguments: arguments)["command"] as? String,
            arguments["command"]
        )
        XCTAssertEqual(
            ToolRiskEvaluator.evaluate(RunShellTool(), arguments: arguments, context: .init()).level,
            .dangerous
        )
        let recorder = PolicyEventRecorder()
        let loop = AgentLoop()
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: PolicyCallingProvider(toolName: "run_shell", json: "{\"command\":\"cat ~/.ssh/id_rsa\"}")
        ) { event in
            await recorder.append(event)
            if case let .confirmationRequested(request) = event {
                await loop.resolveConfirmation(requestID: request.id, decision: .rejected)
            }
        }
        let events = await recorder.events
        let requests = events.compactMap { event -> ConfirmationRequest? in
            if case let .confirmationRequested(request) = event {
                return request
            }
            return nil
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.riskLevel, .dangerous)
    }

    func testUnmatchedPathExecutesWithoutConfirmationAndReturnsContentToModel() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pattern = root.appendingPathComponent("blocked").path + "/**"
        let loop = AgentLoop(securityRules: { [.init(pattern: pattern, action: .block)] })
        let recorder = PolicyEventRecorder()
        // Test helper encodes JSON as UTF-8; preserve existing test semantics.
        // swiftlint:disable:next optional_data_string_conversion
        let json = try String(
            decoding: JSONSerialization.data(withJSONObject: ["path": root.path + "/./visible.txt"]),
            as: UTF8.self
        )
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: PolicyCallingProvider(toolName: "read_file", json: json)
        ) {
            await recorder.append($0)
        }
        let events = await recorder.events
        XCTAssertFalse(events.contains {
            if case .confirmationRequested = $0 {
                true
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains(.contentDelta("public")))
        XCTAssertTrue(events.contains { event in
            if case let .toolCallsCompleted(items) = event {
                return items.first?.result.isError == false
            }
            return false
        })
    }

    func testFailedRuleFetchFailsClosed() async throws {
        let loop = AgentLoop(securityRules: { throw CocoaError(.fileReadNoPermission) })
        let recorder = PolicyEventRecorder()
        try await loop.streamResponse(
            to: [.init(role: .user, content: "test")],
            using: PolicyCallingProvider(toolName: "read_file", json: "{\"path\":\"/a\"}")
        ) {
            await recorder.append($0)
        }
        let events = await recorder.events
        XCTAssertTrue(events.contains { event in
            if case let .toolCallsCompleted(items) = event {
                return items.first?.result.content.contains("Unable to load security rules") == true
            }
            return false
        })
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("blocked/nested"),
            withIntermediateDirectories: true
        )
        try Data("public".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("private-content".utf8).write(to: root.appendingPathComponent("blocked/nested/secret.txt"))
        return URL(fileURLWithPath: PathCanonicalizer.canonicalize(root.path))
    }
}

private actor PolicyEventRecorder {
    private(set) var events: [AgentLoopEvent] = []
    func append(_ event: AgentLoopEvent) {
        events.append(event)
    }
}

private struct PolicyCallingProvider: LLMProvider {
    let name = "Policy regression provider"
    let toolName: String
    let json: String
    func streamChat(messages: [ChatMessage], tools _: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if !messages.contains(where: { $0.role == .tool }) {
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "policy_call",
                    type: "function",
                    functionName: toolName,
                    argumentsDelta: json
                )))
            } else {
                // Verify that the model receives the actual failure, not a success.
                continuation.yield(.contentDelta(messages.last(where: { $0.role == .tool })?.content ?? ""))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
