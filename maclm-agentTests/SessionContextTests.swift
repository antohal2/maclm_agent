import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SessionContextTests: XCTestCase {
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }

    func testLiveLMStudioUsageAndMetadata() throws {
        var parser = SSEParser()
        let events = try parser.append(fixture("lmstudio-usage-live", extension: "sse"))
        XCTAssertTrue(events.contains(.usage(promptTokens: 21, completionTokens: 2)))
        XCTAssertEqual(events.last, .done)
        let models = try ModelMetadataParser.lmStudio(fixture("lmstudio-models-live", extension: "json"))
        XCTAssertEqual(models.first { $0.id == "google/gemma-4-e4b" }?.loadedContextLength, 131_072)
        XCTAssertNil(models.first { $0.id == "qwen/qwen3.8-27b" }?.loadedContextLength)
    }

    func testSyntheticOllamaAndMissingUsage() throws {
        var parser = OllamaNDJSONParser()
        XCTAssertEqual(
            try parser.append(fixture("ollama-usage-synthetic", extension: "ndjson")),
            [.usage(promptTokens: 11, completionTokens: 18), .done]
        )
        var absent = OllamaNDJSONParser()
        XCTAssertEqual(try absent.append(Data("{\"done\":true}\n".utf8)), [.done])
        var sse = SSEParser()
        XCTAssertEqual(try sse.append(Data("data: {\"choices\":[]}\n\ndata: [DONE]\n\n".utf8)), [.done])
        let info = try ModelMetadataParser.enrichOllama(
            ModelInfo(id: "gemma4"),
            show: nil,
            running: fixture("ollama-context-ps-synthetic", extension: "json")
        )
        XCTAssertEqual(info.loadedContextLength, 4096)
    }

    func testLimitsThresholdsAndFormatting() {
        let model = ModelInfo(id: "test", contextLength: 262_144, loadedContextLength: 1000)
        XCTAssertEqual(ContextUsage(used: 699, model: model, fallback: 8192).level, .normal)
        XCTAssertEqual(ContextUsage(used: 700, model: model, fallback: 8192).level, .warning)
        XCTAssertEqual(ContextUsage(used: 899, model: model, fallback: 8192).level, .warning)
        XCTAssertEqual(ContextUsage(used: 900, model: model, fallback: 8192).level, .critical)
        XCTAssertFalse(ContextUsage(used: nil, model: model, fallback: 8192).approximate)
        let fallback = ContextUsage(used: nil, model: ModelInfo(id: "test", contextLength: 262_144), fallback: 8192)
        XCTAssertEqual(fallback.limit, 8192)
        XCTAssertTrue(fallback.approximate)
        let values = [950, 47300, 128_000, 1_048_576]
        XCTAssertEqual(
            values.map { ContextUsage.format($0, locale: Locale(identifier: "ru_RU")) },
            ["950", "47,3 тыс.", "128 тыс.", "1 млн"]
        )
        XCTAssertEqual(
            values.map { ContextUsage.format($0, locale: Locale(identifier: "en_US")) },
            ["950", "47.3K", "128K", "1M"]
        )
    }

    func testSessionSelectionDefaultsAndFork() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let coordinator = ProviderCoordinator(store: ProviderSelectionStore(defaults: defaults))
        try coordinator.configureManually(provider: .lmStudio, baseURLText: "http://localhost:1234", model: "first")
        let conversation = Conversation()
        XCTAssertFalse(ModelInfo(id: "no-tools", supportsTools: false).toolsEnabled)
        XCTAssertTrue(ModelInfo(id: "unknown").toolsEnabled)
        XCTAssertEqual(coordinator.sessionSelection(conversation)?.model, "first")
        conversation.modelID = "own"
        conversation.providerID = try ProviderEndpoint(
            provider: .lmStudio,
            baseURL: XCTUnwrap(URL(string: "http://localhost:1234"))
        ).id
        try coordinator.configureManually(provider: .ollama, baseURLText: "http://localhost:11434", model: "second")
        XCTAssertEqual(coordinator.sessionSelection(conversation)?.model, "own")
        XCTAssertEqual(coordinator.sessionSelection(conversation)?.provider, .lmStudio)
        XCTAssertEqual(try (coordinator.makeProvider(for: conversation) as? LMStudioProvider)?.model, "own")
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container.mainContext.insert(conversation)
        container.mainContext.insert(Message(
            role: .user,
            content: "prompt",
            timestamp: Date().addingTimeInterval(-1),
            conversation: conversation
        ))
        let response = Message(role: .assistant, content: "answer", conversation: conversation)
        container.mainContext.insert(response)
        let viewModel = ChatViewModel(modelContext: container.mainContext, providerCoordinator: coordinator)
        viewModel.selectConversation(conversation)
        let branch = try XCTUnwrap(viewModel.fork(at: response))
        XCTAssertEqual(branch.modelID, conversation.modelID)
        XCTAssertEqual(branch.providerID, conversation.providerID)
    }

    func testRunnerPersistsAndResetsUsage() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let conversation = Conversation()
        container.mainContext.insert(conversation)
        let recorder = ContextRecordingProvider()
        let runner = SessionRunner(
            conversation: conversation,
            modelContext: container.mainContext,
            agentLoop: AgentLoop(),
            autoTitles: AutoTitleService(context: container.mainContext),
            providerFactory: { recorder }
        )
        runner.send("first")
        await runner.waitUntilFinished()
        XCTAssertEqual(conversation.lastContextTokens, 23)
        await recorder.disableUsage()
        runner.send("second")
        await runner.waitUntilFinished()
        XCTAssertNil(conversation.lastContextTokens)
    }

    func testIntermediateRequestReplacesUsage() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let conversation = Conversation()
        container.mainContext.insert(conversation)
        let runner = SessionRunner(
            conversation: conversation,
            modelContext: container.mainContext,
            agentLoop: AgentLoop(toolRegistry: ToolRegistry(tools: [ContextFixtureTool()])),
            autoTitles: AutoTitleService(context: container.mainContext),
            providerFactory: { ContextMultiTurnProvider() }
        )
        runner.send("test")
        await runner.waitUntilFinished()
        XCTAssertEqual(conversation.lastContextTokens, 102)
        XCTAssertEqual(conversation.messages.flatMap(\.toolCalls).count, 1)
    }

    func testToolsGateAndLastRequestUsage() async throws {
        for enabled in [false, true] {
            let recorder = ContextRecordingProvider()
            let loop = AgentLoop()
            var usage: Int?
            try await loop.streamResponse(
                to: [],
                using: recorder,
                toolsEnabled: enabled,
                invocationContext: { ToolInvocationContext(conversationID: UUID()) },
                onEvent: { event in
                    if case let .usage(prompt, completion) = event {
                        await recorder.record(prompt + completion)
                    }
                }
            )
            let count = await recorder.toolCount
            usage = await recorder.usage
            XCTAssertEqual(count, enabled ? 7 : 0)
            XCTAssertEqual(usage, 23)
        }
    }
}

private actor ContextRecordingProvider: LLMProvider {
    nonisolated let name = "test"
    var toolCount = 0
    var usage: Int?
    var includesUsage = true
    func disableUsage() {
        includesUsage = false
    }

    func record(_ value: Int) {
        usage = value
    }

    nonisolated func streamChat(
        messages _: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await setCount(tools.count)
                if await includesUsage {
                    continuation.yield(.usage(promptTokens: 21, completionTokens: 2))
                }
                continuation.yield(.contentDelta("OK"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func setCount(_ value: Int) {
        toolCount = value
    }
}

private struct ContextMultiTurnProvider: LLMProvider {
    let name = "test"
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if tools.isEmpty {
                continuation.yield(.contentDelta("Fixture title"))
            } else if messages.last?.role == .tool {
                continuation.yield(.usage(promptTokens: 100, completionTokens: 2))
                continuation.yield(.contentDelta("done"))
            } else {
                continuation.yield(.usage(promptTokens: 10, completionTokens: 1))
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "fixture",
                    type: "function",
                    functionName: "context_fixture",
                    argumentsDelta: "{}"
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private struct ContextFixtureTool: Tool {
    let name = "context_fixture"
    let description = "Test only"
    static let baseRiskLevel: RiskLevel = .safe
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .success(content: "fixture")
    }
}
