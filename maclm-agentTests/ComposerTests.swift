import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class ComposerTests: XCTestCase {
    func testShortModelName() {
        XCTAssertEqual(ComposerRules.shortModelName("qwen/qwen3.8-27b"), "qwen3.8-27b")
        let name = ComposerRules.shortModelName("org/" + String(repeating: "a", count: 80))
        XCTAssertEqual(name.count, 28)
        XCTAssertTrue(name.contains("…"))
        XCTAssertEqual(ComposerRules.shortModelName(""), "")
    }

    func testSubmissionRules() {
        XCTAssertFalse(ComposerRules.canSubmit(" \n\t"))
        XCTAssertTrue(ComposerRules.canSubmit(" first\nsecond \n"))
    }

    @MainActor
    func testStopWaitingForConfirmationAuditsCancellation() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        let model = ChatViewModel(
            modelContext: context,
            agentLoop: loop,
            providerFactory: { ComposerToolProvider() }
        )
        model.input = "test"
        model.send()
        for _ in 0 ..< 200 where model.messages.last?.toolCalls.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .pending)
        model.stopGeneration()
        for _ in 0 ..< 200 where model.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.messages.first(where: { !$0.toolCalls.isEmpty })?.toolCalls.first?.status, .rejected)
        XCTAssertEqual(
            model.messages.first(where: { !$0.toolCalls.isEmpty })?.toolCalls.first?.resultJSON,
            "Cancelled by user"
        )
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first).record
        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(record.errorDescription, "Cancelled by user")
    }

    @MainActor
    func testStopCancelsExecutingTestTool() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let probe = ComposerCancellationProbe()
        let loop = AgentLoop(toolRegistry: ToolRegistry(tools: [ComposerWaitingTool(probe: probe)]))
        let model = ChatViewModel(
            modelContext: container.mainContext,
            agentLoop: loop,
            providerFactory: { ComposerToolProvider(name: "waiting_test") }
        )
        model.input = "test"
        model.send()
        for _ in 0 ..< 200 where model.messages.last?.toolCalls.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let call = try XCTUnwrap(model.messages.last?.toolCalls.first)
        model.resolveConfirmation(toolCallID: call.id, decision: .approved)
        for _ in 0 ..< 200 {
            if await probe.started {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await probe.started
        XCTAssertTrue(started)
        model.stopGeneration()
        for _ in 0 ..< 200 where model.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isGenerating)
        let cancelled = await probe.cancelled
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testStopStreamingPreservesTextAndAllowsNextMessage() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let viewModel = ChatViewModel(
            modelContext: container.mainContext,
            providerFactory: { WaitingComposerProvider() }
        )
        viewModel.input = " first\nsecond \n"
        viewModel.send()
        for _ in 0 ..< 200 where viewModel.messages.last?.content != "partial" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(viewModel.messages.first?.content, " first\nsecond \n")
        XCTAssertEqual(viewModel.messages.last?.content, "partial")
        viewModel.stopGeneration()
        for _ in 0 ..< 200 where viewModel.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertEqual(viewModel.messages.last?.content, "partial")
        viewModel.input = "next"
        viewModel.send()
        XCTAssertTrue(viewModel.isGenerating)
        viewModel.stopGeneration()
        for _ in 0 ..< 200 where viewModel.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(viewModel.isGenerating)
    }
}

private struct WaitingComposerProvider: LLMProvider {
    let name = "test"
    func streamChat(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.contentDelta("partial"))
                do { try await Task.sleep(for: .seconds(60)); continuation.finish() } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct ComposerToolProvider: LLMProvider {
    var name = "run_shell"
    func streamChat(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolCallDelta(.init(
                index: 0,
                id: "test-call",
                type: "function",
                functionName: name,
                argumentsDelta: "{}"
            )))
            continuation.finish()
        }
    }
}

private actor ComposerCancellationProbe {
    var started = false
    var cancelled = false
    func start() {
        started = true
    }

    func cancel() {
        cancelled = true
    }
}

private struct ComposerWaitingTool: Tool {
    let probe: ComposerCancellationProbe
    let name = "waiting_test"
    let description = "Test only"
    static let baseRiskLevel: RiskLevel = .dangerous
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(
        arguments _: [String: Any],
        invocation _: ToolInvocationContext
    ) async throws -> ToolExecutionResult {
        await probe.start()
        do { try await Task.sleep(for: .seconds(60)) } catch { await probe.cancel(); throw error }
        return .success(content: "done")
    }
}
