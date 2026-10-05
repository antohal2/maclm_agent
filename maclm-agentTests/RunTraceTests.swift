import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class RunTraceTests: XCTestCase {
    private func message(_ role: MessageRole, _ content: String = "", calls: Int = 0) -> Message {
        Message(role: role, content: content, toolCalls: (0 ..< calls).map { _ in
            ToolCall(toolName: "read_file", argumentsJSON: "{}", status: .completed)
        })
    }

    func testPlainAndMultipleTurns() {
        let firstAnswer = message(.assistant, "answer")
        let secondAnswer = message(.assistant, "answer 2")
        let turns = RunTraceGrouping.group([message(.user), firstAnswer, message(.user), secondAnswer])
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.allSatisfy(\.steps.isEmpty))
        XCTAssertEqual(turns.map { $0.final?.id }, [firstAnswer.id, secondAnswer.id])
    }

    func testThreeCallsIntermediateTextAndMixedContent() {
        let mixed = message(.assistant, "I will read", calls: 3)
        let intermediate = message(.assistant, "progress")
        let final = message(.assistant, "answer")
        let turn = RunTraceGrouping.group([message(.user), mixed, message(.tool), intermediate, final])[0]
        XCTAssertEqual(turn.steps.map(\.id), [mixed.id, intermediate.id])
        XCTAssertEqual(turn.stepCount, 3)
        XCTAssertEqual(turn.final?.id, final.id)
        XCTAssertNil(RunTraceGrouping.group([message(.user), mixed])[0].final)
    }

    func testActiveCancelledAndFailedHaveNoFinal() {
        let messages = [message(.user), message(.assistant, "partial", calls: 1), message(.assistant, "partial answer")]
        XCTAssertNil(RunTraceGrouping.group(messages, active: true)[0].final)
        XCTAssertNil(RunTraceGrouping.group(messages, cancelled: true)[0].final)
        XCTAssertNil(RunTraceGrouping.group(messages, failed: true)[0].final)
        XCTAssertNil(RunTraceGrouping.group([message(.user), message(.assistant, "Ошибка: server")])[0].final)
    }

    func testCancelledTurnRemainsUnfinishedAfterNextPrompt() {
        let user = message(.user)
        let nextUser = message(.user)
        let turns = RunTraceGrouping.group(
            [user, message(.assistant, "partial"), nextUser, message(.assistant, "answer")],
            endings: [user.id: TraceRunEnd(timestamp: Date(), cancelled: true, failed: false)]
        )
        XCTAssertNil(turns[0].final)
        XCTAssertNotNil(turns[1].final)
    }

    func testPendingConfirmationIsSeparateFromCollapsedSteps() {
        let assistant = message(.assistant, calls: 1)
        assistant.toolCalls[0].status = .pending
        let turn = RunTraceGrouping.group([message(.user), assistant], active: true)[0]
        XCTAssertTrue(turn.expandedSteps(isExpanded: false).isEmpty)
        XCTAssertEqual(turn.expandedSteps(isExpanded: true).count, 1)
        XCTAssertEqual(turn.pendingCalls.map(\.id), [assistant.toolCalls[0].id])
        assistant.toolCalls[0].status = .approved
        XCTAssertTrue(turn.pendingCalls.isEmpty)
        XCTAssertEqual(turn.calls.count, 1)
    }

    func testIncidentsAndRepeatedArgumentsConsumeAuditOnce() {
        let calls = (0 ..< 5).map { _ in ToolCall(toolName: "write_file", argumentsJSON: "{}") }
        calls[0].status = .rejected
        calls[1].status = .failed
        calls[2].status = .completed
        calls[3].status = .failed
        calls[4].status = .rejected
        calls[4].resultJSON = "Cancelled by user"
        let choices: [AuditDecision] = [.rejected, .blocked, .approved, .auto]
        let audits = choices.enumerated().map { index, choice in
            AuditEntry(AuditRecord(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                toolName: "write_file",
                argumentsJSON: "{}",
                riskLevel: .dangerous,
                decision: choice
            ))
        }
        XCTAssertEqual(
            TraceIncidents.count(calls: calls, audits: audits),
            TraceIncidents(rejected: 1, blocked: 1, dangerous: 1, errors: 1)
        )
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self,
            Conversation.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testForkCopiesHistoryAndProjectWithoutAuditOrPermissions() throws {
        let container = try container()
        let context = container.mainContext
        let model = ChatViewModel(modelContext: context)
        for withProject in [true, false] {
            let project = withProject ? Project(name: "Trace") : nil
            if let project {
                context.insert(project)
            }
            let source = model.createConversation(project: project)
            source.title = "Source"
            source.isPinned = true
            model.sessionPermissions.remember(conversationID: source.id, toolName: "write_file", riskLevel: .caution)
            let messages = [
                message(.user, "prompt"),
                message(.assistant, "mixed", calls: 1),
                message(.tool, "result"),
                message(.assistant, "final"),
                message(.user, "later"),
            ]
            for (index, message) in messages.enumerated() {
                message.timestamp = Date(timeIntervalSince1970: Double(index))
                message.conversation = source
                context.insert(message)
            }
            messages[1].toolCalls[0].confirmationRiskRawValue = RiskLevel.dangerous.rawValue
            context.insert(AuditEntry(AuditRecord(
                toolName: "read_file",
                argumentsJSON: "{}",
                conversationID: source.id
            )))
            try context.save()
            let before = try context.fetch(FetchDescriptor<AuditEntry>()).count
            let branch = try XCTUnwrap(model.fork(at: messages[3]))
            XCTAssertEqual(branch.orderedMessages.map(\.content), ["prompt", "mixed", "result", "final"])
            XCTAssertEqual(branch.project?.id, project?.id)
            XCTAssertTrue(branch.titleIsManual)
            XCTAssertFalse(branch.isPinned || branch.isArchived || branch.hasUnreadResult)
            XCTAssertNotEqual(branch.id, source.id)
            XCTAssertTrue(model.sessionPermissions.permissions(for: branch.id).isEmpty)
            XCTAssertFalse(model.sessionPermissions.permissions(for: source.id).isEmpty)
            XCTAssertNil(model.currentRunner)
            XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).count, before)
            let cloned = try XCTUnwrap(branch.orderedMessages[1].toolCalls.first)
            XCTAssertEqual(cloned.status, .completed)
            XCTAssertEqual(cloned.confirmationRiskRawValue, RiskLevel.dangerous.rawValue)
            XCTAssertNotEqual(cloned.id, messages[1].toolCalls[0].id)
            branch.orderedMessages[0].content = "changed"
            XCTAssertEqual(source.orderedMessages[0].content, "prompt")
            XCTAssertEqual(source.messages.count, 5)
        }
    }

    func testRetryPreservesUserAuditAndMemoryAndDeletesLaterCalls() throws {
        let container = try container()
        let context = container.mainContext
        let model = ChatViewModel(modelContext: context, providerFactory: { throw URLError(.cannotConnectToHost) })
        let source = try XCTUnwrap(model.selectedConversation)
        let first = message(.user, "first")
        let answer = message(.assistant, "old", calls: 1)
        let later = message(.user, "later")
        for (index, message) in [first, answer, later].enumerated() {
            message.timestamp = Date(timeIntervalSince1970: Double(index))
            message.conversation = source
            context.insert(message)
        }
        let oldCallID = answer.toolCalls[0].id
        context.insert(AuditEntry(AuditRecord(toolName: "read_file", argumentsJSON: "{}", conversationID: source.id)))
        model.sessionPermissions.remember(conversationID: source.id, toolName: "write_file", riskLevel: .caution)
        try context.save()
        model.retryMessage(first)
        XCTAssertEqual(source.orderedMessages.first?.id, first.id)
        XCTAssertFalse(source.messages.contains { $0.id == later.id || $0.id == answer.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<ToolCall>()).contains { $0.id == oldCallID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).count, 1)
        XCTAssertFalse(model.sessionPermissions.permissions(for: source.id).isEmpty)
        source.orderedMessages.last?.toolCalls.append(ToolCall(toolName: "write_file", argumentsJSON: "{}"))
        XCTAssertFalse(model.canRetryMessage)
    }

    func testGroupingPerformanceForLargeConversation() {
        let messages = (0 ..< 100).flatMap { _ in
            [message(.user), message(.assistant, "mixed", calls: 3), message(.tool), message(.assistant, "final")]
        }
        measure { XCTAssertEqual(RunTraceGrouping.group(messages).count, 100) }
    }
}

private struct TraceWaitingProvider: LLMProvider {
    let name = "Trace fixture"
    func streamChat(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(60))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension RunTraceTests {
    func testRetryIsUnavailableDuringGeneration() async throws {
        let container = try container()
        let context = container.mainContext
        let model = ChatViewModel(modelContext: context, providerFactory: { TraceWaitingProvider() })
        let source = try XCTUnwrap(model.selectedConversation)
        let runner = model.registry.runner(for: source)
        runner.send("prompt")
        XCTAssertTrue(runner.isGenerating)
        XCTAssertFalse(model.canRetryMessage)
        let user = try XCTUnwrap(source.orderedMessages.first)
        let ids = source.orderedMessages.map(\.id)
        model.retryMessage(user)
        runner.retry(after: user)
        XCTAssertEqual(source.orderedMessages.map(\.id), ids)
        runner.cancel()
        await runner.waitUntilFinished()
    }
}
