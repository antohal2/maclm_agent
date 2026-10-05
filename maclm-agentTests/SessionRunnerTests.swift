import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class SessionRunnerTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private func model(
        provider: @escaping () throws -> any LLMProvider = { SessionTestProvider() }
    ) throws -> ChatViewModel {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        let context = container.mainContext
        return ChatViewModel(
            modelContext: context,
            agentLoop: AgentLoop(
                toolRegistry: ToolRegistry(tools: [SessionTestTool()]),
                auditSink: { context.insert(AuditEntry($0)); try context.save() }
            ),
            providerFactory: provider
        )
    }

    private func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    func testConcurrentApprovalIsolationAndCancel() async throws {
        let model = try model()
        let first = try XCTUnwrap(model.selectedConversation)
        let firstRunner = model.registry.runner(for: first)
        firstRunner.send("first")
        let second = model.createConversation()
        let secondRunner = model.registry.runner(for: second)
        secondRunner.send("second")
        try await wait {
            firstRunner.status == .needsApproval(risk: .dangerous)
                && secondRunner.status == .needsApproval(risk: .dangerous)
        }
        let firstCall = try XCTUnwrap(first.orderedMessages.last?.toolCalls.first)
        let secondCall = try XCTUnwrap(second.orderedMessages.last?.toolCalls.first)
        XCTAssertNotEqual(firstCall.id, secondCall.id)
        secondRunner.resolveApproval(id: firstCall.id, decision: .approved)
        XCTAssertEqual(firstCall.status, .pending)
        XCTAssertEqual(secondCall.status, .pending)
        firstRunner.cancel()
        await firstRunner.waitUntilFinished()
        XCTAssertEqual(firstRunner.status, .idle)
        XCTAssertFalse(first.hasUnreadResult)
        XCTAssertEqual(secondRunner.status, .needsApproval(risk: .dangerous))
        secondRunner.resolveApproval(id: secondCall.id, decision: .approved)
        try await wait { secondRunner.status == .toolRunning(toolName: "session_test") }
        try await wait { !secondRunner.isGenerating }
        XCTAssertEqual(secondRunner.status, .idle)
        XCTAssertFalse(second.hasUnreadResult)
        XCTAssertEqual(secondCall.status, .completed)
        XCTAssertEqual(second.orderedMessages.last?.content, "finished")
        let audit = try model.modelContext.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(Set(audit.map(\.conversationID)), Set([first.id, second.id]))
        XCTAssertEqual(audit.filter { $0.record.outcome == .cancelled }.count, 1)
    }

    func testUnreadRejectAndSelectionClears() async throws {
        let model = try model()
        let first = try XCTUnwrap(model.selectedConversation)
        let runner = model.registry.runner(for: first)
        runner.send("first")
        try await wait { runner.status == .needsApproval(risk: .dangerous) }
        let call = try XCTUnwrap(first.orderedMessages.last?.toolCalls.first)
        model.createConversation()
        runner.resolveApproval(id: call.id, decision: .rejected)
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.status, .idle)
        XCTAssertEqual(call.status, .rejected)
        XCTAssertTrue(first.hasUnreadResult)
        XCTAssertEqual(model.registry.aggregate.kind, .ready)
        model.selectConversation(first)
        XCTAssertFalse(first.hasUnreadResult)
    }

    func testFailurePersistsUntilNextSendAndUnread() async throws {
        let model = try model(provider: { SessionTestProvider(fails: true) })
        let first = try XCTUnwrap(model.selectedConversation)
        let runner = model.registry.runner(for: first)
        runner.send("first")
        model.createConversation()
        await runner.waitUntilFinished()
        guard case .failed = runner.status else { return XCTFail("Expected failed") }
        XCTAssertTrue(first.hasUnreadResult)
        model.selectConversation(first)
        guard case .failed = runner.status else { return XCTFail("Failure must persist") }
        runner.send("second")
        XCTAssertEqual(runner.status, .running)
        runner.cancel()
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.status, .idle)
        XCTAssertFalse(first.hasUnreadResult)
    }

    func testShutdownCancelsEveryRunnerAndPreventsRestart() async throws {
        let model = try model()
        let firstRunner = try model.registry.runner(for: XCTUnwrap(model.selectedConversation))
        let secondRunner = model.registry.runner(for: model.createConversation())
        firstRunner.send("first")
        secondRunner.send("second")
        try await wait {
            firstRunner.status == .needsApproval(risk: .dangerous)
                && secondRunner.status == .needsApproval(risk: .dangerous)
        }
        await model.registry.cancelAllAndWait()
        XCTAssertFalse(firstRunner.isGenerating)
        XCTAssertFalse(secondRunner.isGenerating)
        XCTAssertEqual(firstRunner.status, .idle)
        XCTAssertEqual(secondRunner.status, .idle)
        firstRunner.send("ignored")
        XCTAssertFalse(firstRunner.isGenerating)
    }

    func testOverlappingConversationAndProjectDeletionWaitsForBothRuns() async throws {
        let model = try model()
        let project = Project(name: "Concurrent deletion")
        model.saveProject(project)
        let first = model.createConversation(project: project)
        let second = model.createConversation(project: project)
        let ids = Set([first.id, second.id])
        let firstRunner = model.registry.runner(for: first)
        let secondRunner = model.registry.runner(for: second)
        firstRunner.send("first")
        secondRunner.send("second")
        try await wait {
            firstRunner.status == .needsApproval(risk: .dangerous)
                && secondRunner.status == .needsApproval(risk: .dangerous)
        }
        model.deleteConversation(first)
        model.deleteProject(project, includingConversations: true)
        try await wait { model.registry.runners.isEmpty }
        XCTAssertTrue(try model.modelContext.fetch(FetchDescriptor<Project>()).isEmpty)
        XCTAssertTrue(try model.modelContext.fetch(FetchDescriptor<Conversation>()).allSatisfy { !ids.contains($0.id) })
        let audit = try model.modelContext.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(audit.count, 2)
        XCTAssertTrue(audit.allSatisfy { $0.record.outcome == .cancelled })
    }

    func testAggregateEveryPriorityCombination() {
        let values: [SessionStatus] = [
            .needsApproval(risk: .caution),
            .failed(message: "error"),
            .toolRunning(toolName: "test"),
            .running,
            .idle,
        ]
        let expected: [AggregateStatus.Kind] = [.needsApproval, .failed, .toolRunning, .running, .idle]
        let ids = values.map { _ in UUID() }
        for mask in 0 ..< 32 {
            let indices = values.indices.filter { mask & (1 << $0) != 0 }
            let statuses = Dictionary(uniqueKeysWithValues: indices.map { (ids[$0], values[$0]) })
            for unread in [false, true] {
                let aggregate = AggregateStatus(statuses: statuses, unread: unread ? [UUID()] : [])
                let priority = indices.first(where: { $0 < 4 })
                XCTAssertEqual(aggregate.kind, priority.map { expected[$0] } ?? (unread ? .ready : .idle))
                XCTAssertEqual(aggregate.needsApproval.count, indices.contains(0) ? 1 : 0)
                XCTAssertEqual(aggregate.failed.count, indices.contains(1) ? 1 : 0)
                XCTAssertEqual(aggregate.toolRunning.count, indices.contains(2) ? 1 : 0)
                XCTAssertEqual(aggregate.running.count, indices.contains(3) ? 1 : 0)
            }
        }
    }
}

private struct SessionTestProvider: LLMProvider {
    let name = "session fixture"
    var fails = false
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: LLMProviderError.invalidResponse); return
            }
            if tools.isEmpty {
                continuation.yield(.contentDelta("Test title"))
            } else if messages.last?.role == .tool {
                continuation.yield(.contentDelta("finished"))
            } else {
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "same-provider-id",
                    type: "function",
                    functionName: "session_test",
                    argumentsDelta: "{}"
                )))
            }
            continuation.finish()
        }
    }
}

private struct SessionTestTool: Tool {
    let name = "session_test"
    let description = "Test fixture"
    static let baseRiskLevel: RiskLevel = .dangerous
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(
        arguments _: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult {
        try await Task.sleep(for: .milliseconds(80))
        return .success(content: "result")
    }
}
