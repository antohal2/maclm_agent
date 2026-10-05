import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class SessionRegressionTests: XCTestCase {
    func testTwoCallsPreserveHistoryAndAudit() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let loop = AgentLoop(
            toolRegistry: ToolRegistry(tools: [RegressionTool()]),
            auditSink: { context.insert(AuditEntry($0)); try context.save() }
        )
        let model = ChatViewModel(modelContext: context, agentLoop: loop, providerFactory: { RegressionProvider() })
        model.input = "request"
        model.send()
        try await wait { !model.isGenerating }
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        XCTAssertEqual(model.messages.map(\.content), ["request", "working", "result", "result", "answer"])
        let calls = model.messages[1].toolCalls.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(calls.map(\.providerCallID), ["a", "b"])
        XCTAssertTrue(calls.allSatisfy { $0.status == .completed && $0.resultJSON == "result" })
        let audit = try context.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(audit.count, 2)
        XCTAssertTrue(audit.allSatisfy { $0.record.outcome == .success })
    }

    func testApprovalAndRejectionCompleteHistory() async throws {
        for decision in [ConfirmationDecision.approved, .rejected] {
            let container = try ModelContainer(
                for: Conversation.self,
                Message.self,
                ToolCall.self,
                AuditEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = container.mainContext
            let loop = AgentLoop(
                toolRegistry: ToolRegistry(tools: [RegressionApprovalTool()]),
                auditSink: { context.insert(AuditEntry($0)); try context.save() }
            )
            let model = ChatViewModel(
                modelContext: context,
                agentLoop: loop,
                providerFactory: { RegressionProvider(toolName: "approval_fixture", callIDs: ["a"]) }
            )
            model.input = "request"
            model.send()
            try await wait { model.messages.last?.toolCalls.first?.status == .pending }
            let call = try XCTUnwrap(model.messages.last?.toolCalls.first)
            model.resolveConfirmation(toolCallID: call.id, decision: decision)
            try await wait { !model.isGenerating }
            XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .tool, .assistant])
            XCTAssertEqual(call.status, decision == .approved ? .completed : .rejected)
            XCTAssertEqual(model.messages.last?.content, "answer")
            let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first).record
            XCTAssertEqual(audit.outcome, decision == .approved ? .success : .notExecuted)
            XCTAssertEqual(audit.decision, decision == .approved ? .approved : .rejected)
        }
    }

    func testProviderFailureIsPersisted() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = ChatViewModel(
            modelContext: container.mainContext,
            providerFactory: { RegressionProvider(fails: true) }
        )
        model.input = "request"
        model.send()
        try await wait { !model.isGenerating }
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant])
        XCTAssertTrue(model.messages.last?.content.hasPrefix("Ошибка:") == true)
    }

    func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }
}

private struct RegressionProvider: LLMProvider {
    let name = "regression"
    var fails = false
    var toolName = "regression"
    var callIDs = ["a", "b"]
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: LLMProviderError.invalidResponse); return
            }
            if tools.isEmpty {
                continuation.yield(.contentDelta("Regression title"))
            } else if messages.last?.role == .tool {
                continuation.yield(.contentDelta("answer"))
            } else {
                continuation.yield(.contentDelta("working"))
                for (index, id) in callIDs.enumerated() {
                    continuation.yield(.toolCallDelta(.init(
                        index: index,
                        id: id,
                        type: "function",
                        functionName: toolName,
                        argumentsDelta: "{}"
                    )))
                }
            }
            continuation.finish()
        }
    }
}

private struct RegressionTool: Tool {
    let name = "regression"
    let description = "Test fixture"
    static let baseRiskLevel: RiskLevel = .safe
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(
        arguments _: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult {
        .success(content: "result")
    }
}

private struct RegressionApprovalTool: Tool {
    let name = "approval_fixture"
    let description = "Test fixture"
    static let baseRiskLevel: RiskLevel = .dangerous
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(
        arguments _: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult {
        .success(content: "result")
    }
}
