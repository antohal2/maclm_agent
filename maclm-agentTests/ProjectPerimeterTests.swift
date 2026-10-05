import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class ProjectPerimeterTests: XCTestCase {
    private let projectA = UUID(), projectB = UUID()
    private func invocation(_ id: UUID, directory: String?) -> ToolInvocationContext {
        .init(conversationID: id, project: .init(id: id, workingDirectoryPath: directory))
    }

    func testScopedAllowGlobalBlockAndLegacyFallback() {
        let rules: [SecurityRuleSnapshot] = [
            .init(pattern: "/tmp/other/**", action: .allow),
            .init(pattern: "/tmp/wsA/secret/**", action: .block),
            .init(pattern: "/tmp/extra/**", action: .allow, projectID: projectA),
            .init(pattern: "/tmp/wsB/private/**", action: .block, projectID: projectB),
        ]
        let context = invocation(projectA, directory: "/tmp/wsA")
        let policy = SecurityPolicyEngine(rules: rules, invocation: context)
        XCTAssertEqual(policy.decision(for: "/tmp/other/x", dimension: .path), .noDecision)
        XCTAssertEqual(policy.decision(for: "/tmp/extra/x", dimension: .path).disposition, .allowed)
        XCTAssertEqual(policy.decision(for: "/tmp/wsA/secret/x", dimension: .path).disposition, .blocked)
        let risk = ToolRiskContext(allowedDirectories: ["/tmp/other"], projectPolicy: policy)
        for path in ["/tmp/wsA/../wsB/x", "/tmp/wsA-evil/x", "/tmp/other/x"] {
            XCTAssertEqual(
                ToolRiskEvaluator
                    .evaluate(WriteFileTool(), arguments: ["path": path], context: risk, invocation: context).level,
                .dangerous
            )
            XCTAssertEqual(
                ToolRiskEvaluator
                    .evaluate(ReadFileTool(), arguments: ["path": path], context: risk, invocation: context).level,
                .safe
            )
        }
        for path in ["/tmp/wsA/x", "/tmp/extra/x"] {
            XCTAssertEqual(
                ToolRiskEvaluator
                    .evaluate(WriteFileTool(), arguments: ["path": path], context: risk, invocation: context).level,
                .caution
            )
        }
        let other = SecurityPolicyEngine(rules: rules, invocation: invocation(projectB, directory: "/tmp/wsB"))
        XCTAssertEqual(other.decision(for: "/tmp/extra/x", dimension: .path), .noDecision)
        let fallback = SecurityPolicyEngine(rules: rules, invocation: invocation(projectA, directory: nil))
        XCTAssertEqual(fallback.decision(for: "/tmp/other/x", dimension: .path).disposition, .allowed)
        XCTAssertEqual(fallback.decision(for: "/tmp/extra/x", dimension: .path), .noDecision)
    }

    func testSymlinkEscapesProjectZone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("a/link"),
            withDestinationURL: root.appendingPathComponent("b")
        )
        let context = invocation(projectA, directory: root.appendingPathComponent("a").path)
        let policy = SecurityPolicyEngine(rules: [], invocation: context)
        XCTAssertFalse(policy.isInProjectAllowedZone(root.appendingPathComponent("a/link/x").path))
        XCTAssertTrue(policy.isInProjectAllowedZone(root.appendingPathComponent("a/x").path))
    }

    func testMemoryIsolationRevocationAndOldApproval() {
        let memory = SessionPermissions()
        let epoch = memory.epoch(for: projectA)
        memory.remember(conversationID: projectA, toolName: "write_file", riskLevel: .caution)
        XCTAssertTrue(memory.allows(conversationID: projectA, toolName: "write_file", riskLevel: .caution))
        XCTAssertFalse(memory.allows(conversationID: projectB, toolName: "write_file", riskLevel: .caution))
        memory.remember(conversationID: projectB, toolName: "run_shell", riskLevel: .dangerous)
        XCTAssertTrue(memory.permissions(for: projectB).isEmpty)
        memory.reset(conversationID: projectA)
        memory.remember(conversationID: projectA, toolName: "write_file", riskLevel: .caution, expectedEpoch: epoch)
        XCTAssertTrue(memory.permissions.isEmpty)
        memory.remember(conversationID: projectA, toolName: "write_file", riskLevel: .caution)
        XCTAssertFalse(memory.allows(
            conversationID: projectA, toolName: "write_file", riskLevel: .caution, expectedEpoch: epoch
        ))
        XCTAssertTrue(memory.allows(
            conversationID: projectA, toolName: "write_file", riskLevel: .caution,
            expectedEpoch: memory.epoch(for: projectA)
        ))
    }

    func testMandatoryProtectionStoreAPIAndShellException() throws {
        let container = try ModelContainer(
            for: SecurityRule.self,
            Project.self,
            Conversation.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let url = URL(fileURLWithPath: "/test/default.store")
        try ApplicationProtection.ensure(context: context, storeURL: url, bundleID: "local.test")
        try ApplicationProtection.ensure(context: context, storeURL: url, bundleID: "local.test")
        let rules = try context.fetch(FetchDescriptor<SecurityRule>())
        XCTAssertEqual(rules.count, 4)
        let store = SecurityRuleStore(context: context)
        for rule in rules {
            XCTAssertThrowsError(try store.setEnabled(rule, false))
            XCTAssertThrowsError(try store.delete(rule))
            XCTAssertThrowsError(try store.save(SecurityRuleDraft(rule), rule: rule))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let contexts = [ToolInvocationContext(conversationID: projectA), invocation(projectB, directory: home)]
        for invocation in contexts {
            let engine = SecurityPolicyEngine(rules: rules.map(\.snapshot), invocation: invocation)
            for path in [
                "/test/default.store",
                "/test/default.store-wal",
                "/test/default.store-shm",
                home + "/Library/Application Support/local.test/x",
                home + "/Library/Preferences/local.test.plist",
                home + "/Library/LaunchAgents/x.plist",
            ] {
                XCTAssertEqual(engine.decision(for: path, dimension: .path).disposition, .blocked, path)
            }
            XCTAssertEqual(engine.decision(for: RunShellTool(), arguments: ["command": "anything"]), .noDecision)
        }
    }

    func testGitHeadAndWorktreeMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(GitHeadReader.read(workingDirectory: root.path))
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/test\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitHeadReader.read(workingDirectory: root.path), "feature/test")
        try "123456789abcdef\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHeadReader.read(workingDirectory: root.path), "1234567 (detached)")
        try FileManager.default.moveItem(at: git, to: root.appendingPathComponent("metadata"))
        try "gitdir: metadata\n".write(to: git, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHeadReader.read(workingDirectory: root.path), "1234567 (detached)")
    }
}

private actor PerimeterRecorder {
    private(set) var risks: [RiskLevel] = []
    func record(_ risk: RiskLevel) {
        risks.append(risk)
    }
}

private struct PerimeterProvider: LLMProvider {
    let name = "perimeter fixture"
    let path: String
    let calls: Int
    func streamChat(messages: [ChatMessage], tools _: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let count = messages.filter { $0.role == .tool }.count
            if count < calls {
                let args = ["path": path, "content": "fixture", "mode": "overwrite"]
                guard let data = try? JSONEncoder().encode(args), let json = String(data: data, encoding: .utf8) else {
                    continuation.finish(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "call-\(count)",
                    type: "function",
                    functionName: "write_file",
                    argumentsDelta: json
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

extension ProjectPerimeterTests {
    func testIndependentRunsKeepTheirProjectContexts() async throws {
        let root = try makeTwoDirectoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolInvocationContext(
            conversationID: UUID(),
            project: .init(id: UUID(), workingDirectoryPath: root.appendingPathComponent("a").path)
        )
        let second = ToolInvocationContext(
            conversationID: UUID(),
            project: .init(id: UUID(), workingDirectoryPath: root.appendingPathComponent("b").path)
        )
        let loop = AgentLoop(securityRules: { [] })
        let recorderA = PerimeterRecorder(), recorderB = PerimeterRecorder()
        let path = root.appendingPathComponent("a/x").path
        let contextA: @MainActor @Sendable () -> ToolInvocationContext = { first }
        let contextB: @MainActor @Sendable () -> ToolInvocationContext = { second }
        let taskA = Task {
            let runner = loop.independentRun()
            try await runner.streamResponse(
                to: [],
                using: PerimeterProvider(path: path, calls: 1),
                invocationContext: contextA
            ) { event in
                if case let .confirmationRequested(request) = event {
                    await recorderA.record(request.riskLevel)
                    await runner.resolveConfirmation(requestID: request.id, decision: .approved)
                }
            }
        }
        let taskB = Task {
            let runner = loop.independentRun()
            try await runner.streamResponse(
                to: [],
                using: PerimeterProvider(path: path, calls: 1),
                invocationContext: contextB
            ) { event in
                if case let .confirmationRequested(request) = event {
                    await recorderB.record(request.riskLevel)
                    await runner.resolveConfirmation(requestID: request.id, decision: .rejected)
                }
            }
        }
        try await taskA.value
        try await taskB.value
        let risksA = await recorderA.risks, risksB = await recorderB.risks
        XCTAssertEqual(risksA, [.caution])
        XCTAssertEqual(risksB, [.dangerous])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testConversationMoveFolderChangeAndDeletionResetMemory() throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let memory = SessionPermissions()
        let model = ChatViewModel(modelContext: container.mainContext, agentLoop: AgentLoop(sessionPermissions: memory))
        let project = Project(name: "A", workingDirectoryPath: "/a")
        model.saveProject(project)
        let conversation = model.createConversation(project: project)
        func remember() {
            memory.remember(conversationID: conversation.id, toolName: "write_file", riskLevel: .caution)
        }
        remember()
        project.workingDirectoryPath = "/b"
        model.saveProject(project)
        XCTAssertTrue(memory.permissions(for: conversation.id).isEmpty)
        remember()
        model.moveConversation(conversation, to: nil)
        XCTAssertTrue(memory.permissions(for: conversation.id).isEmpty)
        remember()
        model.deleteConversation(conversation)
        XCTAssertTrue(memory.permissions(for: conversation.id).isEmpty)
    }

    func testDirectoryPageCapAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< 505 {
            try Data().write(to: root.appendingPathComponent("file-\(index)"))
        }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let page = try WorkspaceDirectoryPage.read(root)
        XCTAssertEqual(page.files.count, 500)
        XCTAssertEqual(page.remaining, 5)
        XCTAssertFalse(page.files.contains { $0.url.lastPathComponent.hasPrefix(".") })
    }
}

@MainActor private final class InvocationFixture {
    var value: ToolInvocationContext
    init(_ value: ToolInvocationContext) {
        self.value = value
    }

    func replace(with value: ToolInvocationContext, memory: SessionPermissions) {
        memory.reset(conversationID: self.value.conversationID)
        self.value = value
    }
}

extension ProjectPerimeterTests {
    func testPendingApprovalUsesSnapshotAndNextCallSeesChangedDirectory() async throws {
        let root = try makeTwoDirectoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), project = UUID()
        let old = ToolInvocationContext(
            conversationID: id,
            project: .init(id: project, workingDirectoryPath: root.appendingPathComponent("a").path)
        )
        let next = ToolInvocationContext(
            conversationID: id,
            project: .init(id: project, workingDirectoryPath: root.appendingPathComponent("b").path)
        )
        let holder = InvocationFixture(old)
        let contextSource: @MainActor @Sendable () -> ToolInvocationContext = { holder.value }
        let memory = SessionPermissions()
        let loop = AgentLoop(sessionPermissions: memory, securityRules: { [] })
        let recorder = PerimeterRecorder()
        let path = root.appendingPathComponent("a/file").path
        try await loop.streamResponse(
            to: [],
            using: PerimeterProvider(path: path, calls: 2),
            invocationContext: contextSource
        ) { event in
            if case let .confirmationRequested(request) = event {
                await recorder.record(request.riskLevel)
                if request.riskLevel == .caution {
                    await holder.replace(with: next, memory: memory)
                    await loop.resolveConfirmation(requestID: request.id, decision: .approved, rememberForSession: true)
                } else {
                    await loop.resolveConfirmation(requestID: request.id, decision: .rejected)
                }
            }
        }
        let risks = await recorder.risks
        XCTAssertEqual(risks, [.caution, .dangerous])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(memory.permissions(for: id).isEmpty)
    }
}

private func makeTwoDirectoryFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for name in ["a", "b"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    return root
}

extension ProjectPerimeterTests {
    func testDirectoryChangeDuringRiskFetchCannotRememberOldSnapshot() async throws {
        let root = try makeTwoDirectoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), project = UUID()
        let old = ToolInvocationContext(
            conversationID: id,
            project: .init(id: project, workingDirectoryPath: root.appendingPathComponent("a").path)
        )
        let next = ToolInvocationContext(
            conversationID: id,
            project: .init(id: project, workingDirectoryPath: root.appendingPathComponent("b").path)
        )
        let holder = InvocationFixture(old)
        let memory = SessionPermissions()
        let loop = AgentLoop(sessionPermissions: memory, riskContext: {
            holder.replace(with: next, memory: memory)
            return .init()
        }, securityRules: { [] })
        let contextSource: @MainActor @Sendable () -> ToolInvocationContext = { holder.value }
        let recorder = PerimeterRecorder()
        let path = root.appendingPathComponent("a/file").path
        try await loop.streamResponse(
            to: [],
            using: PerimeterProvider(path: path, calls: 1),
            invocationContext: contextSource
        ) { event in
            if case let .confirmationRequested(request) = event {
                await recorder.record(request.riskLevel)
                await loop.resolveConfirmation(requestID: request.id, decision: .approved, rememberForSession: true)
            }
        }
        let risks = await recorder.risks
        XCTAssertEqual(risks, [.caution])
        XCTAssertTrue(memory.permissions(for: id).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
