import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class SecurityRuleEditorTests: XCTestCase {
    @MainActor
    private func fixture() throws -> SecurityRuleStore {
        let container = try ModelContainer(
            for: SecurityRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        try SecurityRuleSeeder.seedIfNeeded(context: context)
        return SecurityRuleStore(context: context)
    }

    @MainActor
    func testBuiltInsRejectDeletionAndEveryEditExceptEnabled() throws {
        let store = try fixture()
        let rule = try XCTUnwrap(store.rules().first)
        XCTAssertThrowsError(try store.delete(rule))
        for field in 0 ..< 4 {
            var draft = SecurityRuleDraft(rule)
            switch field {
            case 0: draft.pattern = "/changed/**"
            case 1: draft.dimension = .command
            case 2: draft.action = .allow
            default: draft.ruleDescription = "changed"
            }
            XCTAssertThrowsError(try store.save(draft, rule: rule))
        }
        var draft = SecurityRuleDraft(rule)
        draft.isEnabled = false
        try store.save(draft, rule: rule)
        XCTAssertFalse(rule.isEnabled)
    }

    @MainActor
    func testResetRestoresDefaultsAndPreservesCustomRules() throws {
        let store = try fixture()
        var draft = SecurityRuleDraft()
        draft.pattern = "/editor-tests/**"
        draft.isEnabled = false
        let custom = try store.save(draft)
        let before = custom.snapshot
        let originals = try store.rules().filter(\.isBuiltIn)
        try store.setEnabled(originals[0], false)
        try store.move(dimension: .path, from: IndexSet(integer: 0), to: originals.count)
        store.context.delete(originals[1]) // Simulate missing legacy data.
        try store.context.save()
        try store.resetBuiltIns()
        XCTAssertEqual(custom.snapshot, before)
        let restored = try store.rules().filter(\.isBuiltIn)
        XCTAssertEqual(restored.count, DefaultSecurityRules.rules.count)
        for (rule, expected) in zip(restored, DefaultSecurityRules.rules) {
            XCTAssertEqual(rule.pattern, expected.pattern)
            XCTAssertEqual(rule.order, expected.order)
            XCTAssertEqual(rule.action, expected.action)
            XCTAssertEqual(rule.ruleDescription, expected.ruleDescription)
            XCTAssertTrue(rule.isEnabled)
        }
    }

    @MainActor
    func testOrderChangesWinningRuleAndPersists() throws {
        let store = try fixture()
        var draft = SecurityRuleDraft()
        draft.pattern = "/editor-tests/**"
        let first = try store.save(draft)
        draft.pattern = "/editor-tests/file"
        let second = try store.save(draft)
        func decision() throws -> PolicyDecision {
            try SecurityPolicyEngine(rules: SecurityRuleSeeder.snapshots(context: store.context))
                .decision(for: "/editor-tests/file", dimension: .path)
        }
        XCTAssertEqual(try decision().rule?.pattern, first.pattern)
        let group = try store.rules().filter { $0.dimension == .path }
        let index = try XCTUnwrap(group.firstIndex { $0 === second })
        try store.move(dimension: .path, from: IndexSet(integer: index), to: index - 1)
        XCTAssertEqual(try decision().rule?.pattern, second.pattern)
        let other = ModelContext(store.context.container)
        XCTAssertEqual(
            try other.fetch(FetchDescriptor<SecurityRule>()).first { $0.pattern == second.pattern }?.order,
            second.order
        )
    }

    @MainActor
    func testInvalidPatternsNeverSave() throws {
        let store = try fixture()
        for (dimension, pattern) in [
            (RuleDimension.command, "["),
            (.path, "/a/[abc]"),
            (.application, "app"),
            (.host, "https://example.com"),
            (.host, "a..com"),
        ] {
            var draft = SecurityRuleDraft()
            draft.dimension = dimension
            draft.pattern = pattern
            XCTAssertThrowsError(try store.save(draft))
        }
        XCTAssertTrue(SecurityPattern.error("[", dimension: .command)?
            .contains("UTF-16") == true)
        for dimension in RuleDimension.allCases {
            XCTAssertNotNil(SecurityPattern.error("  ", dimension: dimension))
        }
        for (dimension, pattern) in [
            (RuleDimension.command, "^git\\s+"),
            (.path, "~/.ssh/**"),
            (.application, "com.apple.finder"),
            (.host, "*.example.com"),
        ] {
            XCTAssertNil(SecurityPattern.error(pattern, dimension: dimension))
        }
    }

    @MainActor
    func testPreviewUsesWholeEngineAndToolPathSemantics() throws {
        let store = try fixture()
        var draft = SecurityRuleDraft()
        draft.pattern = "~/**"
        draft.action = .allow
        let custom = try store.save(draft)
        let rules = try SecurityRuleSeeder.snapshots(context: store.context)
        for path in ["~/.ssh/id_rsa", "~/Documents/new", "~/../file"] {
            XCTAssertEqual(
                SecurityPattern.preview(path, draft: draft, replacing: custom.snapshot, rules: rules),
                SecurityPolicyEngine(rules: rules).decision(for: ReadFileTool(), arguments: ["path": path])
            )
        }
        XCTAssertEqual(
            SecurityPattern.preview("~/.ssh/id_rsa", draft: draft, replacing: custom.snapshot, rules: rules)
                .disposition,
            .blocked
        )
        for dimension in RuleDimension.allCases where dimension != .path {
            draft.dimension = dimension
            draft.pattern = dimension == .command ? ".*" : "com.example.app"
            XCTAssertEqual(
                SecurityPattern.preview("com.example.app", draft: draft, replacing: nil, rules: rules),
                .noDecision
            )
        }
    }

    @MainActor
    func testSeparatePolicyContextSeesEditorUpdates() throws {
        let store = try fixture()
        let policyContext = ModelContext(store.context.container)
        _ = try policyContext.fetch(FetchDescriptor<SecurityRule>())
        var draft = SecurityRuleDraft()
        draft.pattern = "/editor-tests/cross-context"
        let rule = try store.save(draft)
        func decision() throws -> PolicyDisposition {
            try SecurityPolicyEngine(rules: SecurityRuleSeeder.snapshots(context: policyContext))
                .decision(for: draft.pattern, dimension: .path).disposition
        }
        XCTAssertEqual(try decision(), .blocked)
        try store.setEnabled(rule, false)
        XCTAssertEqual(try decision(), .noDecision)
        try store.setEnabled(rule, true)
        XCTAssertEqual(try decision(), .blocked)
        try store.delete(rule)
        XCTAssertEqual(try decision(), .noDecision)
    }

    @MainActor
    func testNextAgentCallSeesCreateDisableAndDeleteWithoutRestart() async throws {
        let store = try fixture()
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("maclm-editor-test-" + UUID().uuidString)
        try Data("visible".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loop = AgentLoop(securityRules: { try SecurityRuleSeeder.snapshots(context: store.context) })
        let provider = EditorCallingProvider(path: file.path)
        let recorder = EditorRecorder()
        func call() async throws -> Bool {
            await recorder.clear()
            try await loop.streamResponse(to: [.init(role: .user, content: "test")], using: provider) {
                await recorder.append($0)
            }
            return await recorder.failed
        }
        let result1 = try await call()
        XCTAssertFalse(result1)
        var draft = SecurityRuleDraft()
        draft.pattern = file.path
        let custom = try store.save(draft)
        let result4 = try await call()
        XCTAssertTrue(result4)
        try store.setEnabled(custom, false)
        let result2 = try await call()
        XCTAssertFalse(result2)
        try store.delete(custom)
        let result3 = try await call()
        XCTAssertFalse(result3)
    }
}

private actor EditorRecorder {
    var failed = false
    func clear() {
        failed = false
    }

    func append(_ event: AgentLoopEvent) {
        if case let .toolCallsCompleted(items) = event {
            failed = items.first?.result.isError == true
        }
    }
}

private struct EditorCallingProvider: LLMProvider {
    let name = "Editor test"
    let path: String
    func streamChat(messages: [ChatMessage], tools _: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if !messages.contains(where: { $0.role == .tool }) {
                guard let data = try? JSONSerialization.data(withJSONObject: ["path": path]),
                      let json = String(bytes: data, encoding: .utf8)
                else {
                    continuation.finish(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "editor",
                    type: "function",
                    functionName: "read_file",
                    argumentsDelta: json
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
