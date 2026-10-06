import AppKit
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class PetBubbleTests: XCTestCase {
    func testPolicyMatrixAndNotificationPolicy() {
        for risk in RiskLevel.allCases {
            for hidden in [false, true] {
                XCTAssertTrue(PetApprovalPolicy.allows(risk: risk, source: .feed, hidden: hidden))
                XCTAssertEqual(
                    PetApprovalPolicy.allows(risk: risk, source: .pet, hidden: hidden), risk == .caution && !hidden
                )
            }
        }
        for enabled in [false, true] {
            for visible in [false, true] {
                XCTAssertFalse(PetNotificationPolicy.suppress(approval: true, enabled: enabled, visible: visible))
                XCTAssertEqual(
                    PetNotificationPolicy.suppress(approval: false, enabled: enabled, visible: visible),
                    enabled && visible
                )
            }
        }
    }

    func testRowsIncludeReadyOrderedAndDeduplicated() {
        let ids = (0 ..< 7).map { _ in UUID() }
        let aggregate = AggregateStatus(statuses: [
            ids[0]: .needsApproval(risk: .caution), ids[1]: .failed(message: "error"),
            ids[2]: .toolRunning(toolName: "tool"), ids[3]: .running, ids[4]: .running, ids[6]: .idle,
        ], unread: [ids[0], ids[5]])
        XCTAssertEqual(
            PetBubbleRow.orderedIDs(aggregate),
            [ids[0], ids[1], ids[2]]
                + [ids[3], ids[4]].sorted { $0.uuidString < $1.uuidString } + [ids[5]]
        )
        XCTAssertTrue(PetBubbleRow.orderedIDs(AggregateStatus(statuses: [:], unread: [])).isEmpty)
    }

    func testGeometrySideAndNegativeCoordinatesAndNaN() {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        for point in [CGPoint(x: -1190, y: 110), CGPoint(x: -100, y: 800), CGPoint(x: CGFloat.nan, y: CGFloat.nan)] {
            let result = PetBubblePosition.frame(
                pet: CGRect(origin: point, size: CGSize(width: 64, height: 64)),
                size: CGSize(width: 280, height: 300), screen: screen
            )
            XCTAssertTrue(screen.contains(result))
            if point.x == -1190 {
                XCTAssertGreaterThan(result.minX, point.x)
            }
            if point.x == -100 {
                XCTAssertLessThan(result.maxX, point.x)
            }
        }
    }

    func testDangerousAndHiddenCautionRejectedByRealRunner() async throws {
        for dangerous in [false, true] {
            let fixture = try fixture(dangerous: dangerous)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            let runner = try fixture.model.registry.runner(for: XCTUnwrap(fixture.model.selectedConversation))
            runner.send("request")
            let request = try await pending(runner)
            runner.petContentHidden = { !dangerous }
            runner.resolveApproval(id: request.id, decision: .approved, source: .pet)
            XCTAssertEqual(runner.pendingApproval?.id, request.id)
            XCTAssertEqual(runner.persistentToolCall(id: request.id)?.status, .pending)
            XCTAssertTrue(fixture.model.sessionPermissions.permissions.isEmpty)
            runner.resolveApproval(id: request.id, decision: .rejected, source: .pet)
            await runner.waitUntilFinished()
            let audit = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<AuditEntry>()).first)
            XCTAssertEqual(audit.outcome, .notExecuted)
            XCTAssertTrue(audit.resultSummary.contains("[approvalSource: pet]"))
        }
    }

    func testStaleDecisionNoMemoryAndAuditJSONL() async throws {
        let fixture = try fixture(dangerous: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let runner = try fixture.model.registry.runner(for: XCTUnwrap(fixture.model.selectedConversation))
        runner.petContentHidden = { false }
        runner.send("first")
        let first = try await pending(runner)
        runner.resolveApproval(id: UUID(), decision: .approved, rememberForSession: true, source: .pet)
        XCTAssertEqual(runner.pendingApproval?.id, first.id)
        runner.resolveApproval(id: first.id, decision: .approved, rememberForSession: true, source: .pet)
        await runner.waitUntilFinished()
        XCTAssertTrue(fixture.model.sessionPermissions.permissions.isEmpty)
        runner.send("second")
        let second = try await pending(runner)
        runner.resolveApproval(id: first.id, decision: .approved, source: .pet)
        XCTAssertEqual(runner.pendingApproval?.id, second.id)
        runner.resolveApproval(id: second.id, decision: .rejected)
        await runner.waitUntilFinished()
        let entries = try fixture.context.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertTrue(entries.contains { $0.resultSummary.contains("[approvalSource: pet]") })
        XCTAssertTrue(entries.contains { $0.resultSummary.contains("[approvalSource: feed]") })
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: output) }
        let maintenance = AuditMaintenance(modelContainer: fixture.container)
        let count = try await maintenance.export(filter: AuditFilter(), to: output)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("[approvalSource: pet]"))
    }

    func testQuickChatTargetsBusyRunnerAndSharedPetCommand() async throws {
        let fixture = try fixture(dangerous: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let model = fixture.model
        let original = try XCTUnwrap(model.selectedConversation)
        let project = Project(name: "test")
        fixture.context.insert(project)
        original.project = project
        XCTAssertTrue(model.quickSend("last", newChat: false))
        let runner = model.registry.runner(for: original)
        let request = try await pending(runner)
        XCTAssertFalse(model.canQuickSend("busy", newChat: false))
        XCTAssertFalse(model.quickSend("busy", newChat: false))
        var toggles = 0
        model.togglePet = { toggles += 1 }
        let before = try fixture.context.fetchCount(FetchDescriptor<Message>())
        XCTAssertTrue(model.quickSend("/pet", newChat: true))
        model.input = "/pet"
        model.send()
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Message>()), before)
        runner.resolveApproval(id: request.id, decision: .rejected)
        await runner.waitUntilFinished()
        XCTAssertTrue(model.quickSend("new", newChat: true))
        let target = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(target.id, original.id)
        XCTAssertNil(target.project)
        await model.registry.cancelAllAndWait()
    }

    func testDeletedQuickTargetForcesNewChatWithoutUsingFallbackSelection() async throws {
        let fixture = try fixture(dangerous: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let model = fixture.model
        let original = try XCTUnwrap(model.selectedConversation)
        let fallback = model.createConversation()
        model.selectConversation(original)
        model.deleteConversation(original)
        XCTAssertEqual(model.selectedConversationID, fallback.id)
        XCTAssertTrue(model.quickChatRequiresNew)
        let bubble = PetBubbleModel(viewModel: model, settings: AppSettings(defaults: fixture.defaults))
        XCTAssertTrue(bubble.forcesNewChat)
        XCTAssertTrue(model.quickSend("new after deletion", newChat: false))
        let target = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(target.id, fallback.id)
        XCTAssertNil(target.project)
        XCTAssertFalse(model.quickChatRequiresNew)
        await model.registry.cancelAllAndWait()
    }

    func testSettingsAndClosedBubbleStopsObservation() async throws {
        let fixture = try fixture(dangerous: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let settings = AppSettings(defaults: fixture.defaults)
        XCTAssertFalse(settings.petHideContent)
        XCTAssertTrue(settings.petSuppressCompletion)
        let bubble = PetBubbleModel(viewModel: fixture.model, settings: settings)
        bubble.start()
        XCTAssertTrue(bubble.rows.isEmpty)
        let conversation = try XCTUnwrap(fixture.model.selectedConversation)
        conversation.hasUnreadResult = true
        try fixture.context.save()
        settings.petHideContent = true
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(bubble.rows.map(\.id), [conversation.id])
        bubble.stop()
        settings.petHideContent = false
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(bubble.rows.isEmpty)
        settings.petHideContent = true
        settings.petSuppressCompletion = false
        XCTAssertTrue(AppSettings(defaults: fixture.defaults).petHideContent)
        XCTAssertFalse(AppSettings(defaults: fixture.defaults).petSuppressCompletion)
    }

    private func pending(_ runner: SessionRunner) async throws -> ConfirmationRequest {
        for _ in 0 ..< 400 {
            if let request = runner.pendingApproval {
                return request
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(runner.pendingApproval)
    }

    private func fixture(dangerous: Bool) throws -> BubbleFixture {
        let container = try ModelContainer(
            for: Conversation.self, Project.self, Message.self, ToolCall.self, AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "bubble-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BubbleNoNetwork.self]
        let coordinator = ProviderCoordinator(
            store: ProviderSelectionStore(defaults: defaults),
            discovery: ProviderDiscovery(session: URLSession(configuration: configuration))
        )
        try coordinator.configureManually(provider: .lmStudio, baseURLText: "http://localhost:1234", model: "fixture")
        let context = container.mainContext
        let tools: [any Tool] = dangerous ? [BubbleDangerousTool()] : [BubbleCautionTool()]
        let model = ChatViewModel(
            modelContext: context, providerCoordinator: coordinator,
            agentLoop: AgentLoop(toolRegistry: ToolRegistry(tools: tools), auditSink: {
                context.insert(AuditEntry($0)); try context.save()
            }), providerFactory: { BubbleProvider() }
        )
        model.registry.onMetadataRefresh = nil
        return BubbleFixture(container: container, context: context, model: model, defaults: defaults, suite: suite)
    }
}

@MainActor private struct BubbleFixture {
    let container: ModelContainer
    let context: ModelContext
    let model: ChatViewModel
    let defaults: UserDefaults
    let suite: String
}

private struct BubbleProvider: LLMProvider {
    let name = "bubble fixture"
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if messages.last?.role == .tool || tools.isEmpty {
                continuation.yield(.contentDelta("done"))
            } else {
                continuation.yield(.toolCallDelta(.init(
                    index: 0, id: "fixture", type: "function", functionName: "bubble_fixture", argumentsDelta: "{}"
                )))
            }
            continuation.finish()
        }
    }
}

private struct BubbleCautionTool: Tool {
    let name = "bubble_fixture"
    let description = "fixture"
    static let baseRiskLevel: RiskLevel = .caution
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .success(content: "done")
    }
}

private struct BubbleDangerousTool: Tool {
    let name = "bubble_fixture"
    let description = "fixture"
    static let baseRiskLevel: RiskLevel = .dangerous
    var parametersSchema: JSONSchema {
        .object(properties: [:], required: [])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        XCTFail("Dangerous pet approval must never execute")
        return .success(content: "done")
    }
}

private final class BubbleNoNetwork: URLProtocol, @unchecked Sendable {
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
