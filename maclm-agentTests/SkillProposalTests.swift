import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillProposalTests: XCTestCase {
    func testOnlyEnabledSkillsAndDeclinedNeverProposedAgainEvenAfterRelaunch() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write()
        let unavailable = try await fixture.skills.suggest(name: "sample", reason: "task")
        XCTAssertTrue(unavailable.hasPrefix("unavailable: "))
        try await fixture.enable()
        let suggestion = Task { try await fixture.skills.suggest(name: "sample", reason: "task") }
        try await fixture.wait { fixture.skills.pending != nil }
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        let pending = try XCTUnwrap(fixture.skills.pending)
        await fixture.skills.resolveProposal(id: pending.id, attach: false)
        let result = try await suggestion.value
        XCTAssertEqual(result, "declined")
        let repeated = try await fixture.skills.suggest(name: "sample", reason: "again")
        XCTAssertEqual(repeated, "declined")
        let afterRelaunch = try await fixture.restarted().suggest(name: "sample", reason: "again")
        XCTAssertEqual(afterRelaunch, "declined")
        XCTAssertEqual(try fixture.audits("skill.proposed").count, 1)
        XCTAssertEqual(try fixture.audits("skill.declined").count, 1)
    }

    func testOnePendingProposalPetRefusalAndAttachResultContainsNoText() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        let suggestion = Task { try await fixture.skills.suggest(name: "sample", reason: "task") }
        try await fixture.wait { fixture.skills.pending != nil }
        let proposal = try XCTUnwrap(fixture.skills.pending)
        let second = try await fixture.skills.suggest(name: "sample", reason: "again")
        XCTAssertEqual(second, "unavailable: another proposal is pending")
        await fixture.skills.resolveProposal(id: proposal.id, attach: true, source: .pet)
        XCTAssertNotNil(fixture.skills.pending)
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        await fixture.skills.resolveProposal(id: proposal.id, attach: true)
        let result = try await suggestion.value
        XCTAssertEqual(result, "attached")
        XCTAssertFalse(result.contains("Secret"))
        XCTAssertTrue(fixture.skills.prompt.contains("Secret skill instructions"))
        XCTAssertEqual(
            proposal.tokenEstimate,
            try SkillCatalogBuilder.tokens(XCTUnwrap(fixture.skills.attached.first).rendered)
        )
        XCTAssertNil(fixture.skills.pending)
        XCTAssertEqual(try fixture.audits("skill.attached").count, 1)
    }

    func testChangedAfterProposalCannotAttachAndCancellationResolvesWait() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        let suggestion = Task { try await fixture.skills.suggest(name: "sample", reason: "task") }
        try await fixture.wait { fixture.skills.pending != nil }
        let proposal = try XCTUnwrap(fixture.skills.pending)
        try fixture.write(body: "Tampered")
        await fixture.skills.resolveProposal(id: proposal.id, attach: true)
        let result = try await suggestion.value
        XCTAssertTrue(result.hasPrefix("unavailable: "))
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        XCTAssertFalse(fixture.skills.notices.isEmpty)
        let scan = try await fixture.store.rescan()
        _ = try await fixture.store.reconfirm("sample", expectedHash: XCTUnwrap(scan.first?.hash))
        let cancelled = Task { try await fixture.skills.suggest(name: "sample", reason: "task") }
        try await fixture.wait { fixture.skills.pending != nil }
        cancelled.cancel()
        let cancelledResult = try await cancelled.value
        XCTAssertEqual(cancelledResult, "unavailable: cancelled")
        XCTAssertNil(fixture.skills.pending)
    }

    func testRunnerNeedsApprovalAndNextModelRequestHasAttachedSystemText() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        let capture = SkillPromptCapture()
        let provider = SkillCallingProvider(capture: capture)
        let runner = SessionRunner(
            conversation: fixture.conversation, modelContext: fixture.container.mainContext,
            agentLoop: AgentLoop(), autoTitles: AutoTitleService(context: fixture.container.mainContext),
            skillStore: fixture.store, providerFactory: { provider }
        )
        runner.send("Use the sample skill")
        try await fixture.wait { runner.skills?.pending != nil }
        XCTAssertEqual(runner.status, .needsApproval(risk: .safe))
        XCTAssertNil(runner.pendingApproval)
        let proposal = try XCTUnwrap(runner.skills?.pending)
        await runner.skills?.resolveProposal(id: proposal.id, attach: true)
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.status, .idle)
        let requests = await capture.requests
        let chat = requests.filter { $0.contains(where: { $0.role == .user }) }
        XCTAssertEqual(chat.count, 2)
        XCTAssertFalse(chat[0].contains { $0.content.contains("Secret skill instructions") })
        XCTAssertTrue(chat[1].contains { $0.role == .system && $0.content.contains("Secret skill instructions") })
        XCTAssertEqual(chat[1].first { $0.role == .tool }?.content, "attached")
    }

    func testRunnerCancelAndPetBubbleOfferOnlyOpenInChat() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        let model = ChatViewModel(
            modelContext: fixture.container.mainContext,
            providerFactory: { SkillCallingProvider(capture: SkillPromptCapture()) }
        )
        model.registry.skillStore = fixture.store
        let runner = model.registry.runner(for: fixture.conversation)
        runner.send("use sample")
        try await fixture.wait { runner.skills?.pending != nil }
        let domain = "SkillPet-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let bubble = PetBubbleModel(viewModel: model, settings: AppSettings(defaults: defaults))
        bubble.start()
        defer { bubble.stop() }
        let row = try XCTUnwrap(bubble.rows.first { $0.id == fixture.conversation.id })
        XCTAssertTrue(row.hasSkillProposal)
        XCTAssertNil(row.request) // No risk approval or approve/reject buttons can be rendered.
        bubble.resolve(row, decision: .approved)
        XCTAssertNotNil(runner.skills?.pending)
        runner.cancel()
        await runner.waitUntilFinished()
        XCTAssertNil(runner.skills?.pending)
        XCTAssertEqual(runner.status, .idle)
    }
}

actor SkillPromptCapture {
    var requests: [[ChatMessage]] = []
    func append(_ request: [ChatMessage]) {
        requests.append(request)
    }
}

struct SkillCallingProvider: LLMProvider {
    let name = "skill fixture"
    let capture: SkillPromptCapture
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await capture.append(messages)
                if !tools.isEmpty, !messages.contains(where: { $0.role == .tool }) {
                    continuation.yield(.toolCallDelta(.init(
                        index: 0, id: "skill-call", type: "function", functionName: "suggest_skill",
                        argumentsDelta: #"{"name":"sample","reason":"helps the task"}"#
                    )))
                } else {
                    continuation.yield(.contentDelta("Done"))
                }
                continuation.finish()
            }
        }
    }
}
