import AppKit
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class PetLiveSessionTests: XCTestCase {
    func testBackgroundRunnerUpdatesPetAndClickPriority() async throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = ChatViewModel(
            modelContext: container.mainContext,
            providerCoordinator: coordinator(),
            agentLoop: AgentLoop(toolRegistry: ToolRegistry(tools: [PetLiveTool()])),
            providerFactory: { PetLiveProvider() }
        )
        model.registry.onMetadataRefresh = nil
        let background = try XCTUnwrap(model.selectedConversation)
        let runner = model.registry.runner(for: background)
        let foreground = model.createConversation()
        let suite = "pet-live-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = SceneActions()
        var opened = false
        actions.openMainWindowAction = { opened = true }
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let controller = PetController(
            settings: AppSettings(defaults: defaults),
            viewModel: model,
            sceneActions: actions,
            defaults: defaults
        )
        let runtime = controller.runtime
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is PetPanel && !previous.contains($0.windowNumber) }
            as? PetPanel)
        defer { panel.orderOut(nil) }
        XCTAssertFalse(panel.isVisible)
        runner.send("background")
        try await wait { runtime.state == .running }
        try await wait { runtime.state == .needsApproval }
        XCTAssertEqual(model.selectedConversationID, foreground.id)
        XCTAssertEqual(PetState.conversationID(for: model.registry.aggregate), background.id)
        panel.onClick?()
        XCTAssertTrue(opened)
        XCTAssertEqual(model.selectedConversationID, background.id)
        model.selectConversation(foreground)
        try await completeBackground(runner, background: background, runtime: runtime)
        try await checkPriority(model, foreground: foreground, runtime: runtime, panel: panel)
        withExtendedLifetime(controller) {}
    }

    private func coordinator() -> ProviderCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PetNoNetworkProtocol.self]
        return ProviderCoordinator(discovery: ProviderDiscovery(session: URLSession(configuration: configuration)))
    }

    private func completeBackground(
        _ runner: SessionRunner, background: Conversation, runtime: PetRuntime
    ) async throws {
        let call = try XCTUnwrap(background.orderedMessages.last?.toolCalls.first)
        runner.resolveApproval(id: call.id, decision: .approved)
        try await wait { runtime.state == .toolRunning }
        try await wait { runtime.state == .ready }
        runner.send("fail")
        try await wait { runtime.state == .failed }
        await runner.waitUntilFinished()
    }

    private func checkPriority(
        _ model: ChatViewModel, foreground: Conversation, runtime: PetRuntime, panel: PetPanel
    ) async throws {
        let failedID = PetState.conversationID(for: model.registry.aggregate)
        let approval = model.createConversation()
        model.selectConversation(foreground)
        let runner = model.registry.runner(for: approval)
        runner.send("approval")
        XCTAssertEqual(model.registry.aggregate.kind, .failed)
        XCTAssertEqual(PetState.conversationID(for: model.registry.aggregate), failedID)
        try await wait { runtime.state == .needsApproval }
        panel.onClick?()
        XCTAssertEqual(model.selectedConversationID, approval.id)
        await model.registry.cancelAllAndWait()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Pet did not follow the real registry")
    }
}

private struct PetLiveProvider: LLMProvider {
    let name = "pet live fixture"
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    if messages.last?.content == "fail" {
                        throw LLMProviderError.invalidResponse
                    }
                    if tools.isEmpty || messages.last?.role == .tool {
                        continuation.yield(.contentDelta("finished"))
                    } else {
                        continuation.yield(.toolCallDelta(.init(
                            index: 0,
                            id: "pet-call",
                            type: "function",
                            functionName: "pet_live",
                            argumentsDelta: "{}"
                        )))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct PetLiveTool: Tool {
    let name = "pet_live"
    let description = "Pet fixture"
    static let baseRiskLevel: RiskLevel = .dangerous
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        try await Task.sleep(for: .milliseconds(150))
        return .success(content: "done")
    }
}

private final class PetNoNetworkProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
