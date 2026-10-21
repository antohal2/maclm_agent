import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

struct DraftCallingProvider: LLMProvider {
    let name = "draft fixture"
    let calls: [String]
    var capture: SkillPromptCapture?
    var hold = false

    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await capture?.append(messages)
                if hold {
                    continuation.yield(.contentDelta("waiting"))
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        continuation.finish(throwing: error); return
                    }
                }
                let current = messages.lastIndex { $0.role == .user }.map { Array(messages[$0...]) } ?? []
                let index = current.filter { $0.role == .tool }.count
                if !current.isEmpty, !tools.isEmpty, index < calls.count {
                    continuation.yield(.toolCallDelta(.init(
                        index: 0, id: "draft-\(index)", type: "function", functionName: "create_skill_draft",
                        argumentsDelta: calls[index]
                    )))
                } else {
                    continuation.yield(.contentDelta("Done"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor final class SkillDraftFlowTests: XCTestCase {
    private func runner(
        _ fixture: SkillSessionFixture, calls: [String], capture: SkillPromptCapture? = nil,
        permissions: SessionPermissions? = nil, hold: Bool = false
    ) -> SessionRunner {
        SessionRunner(
            conversation: fixture.conversation, modelContext: fixture.container.mainContext,
            agentLoop: AgentLoop(sessionPermissions: permissions ?? SessionPermissions()),
            autoTitles: AutoTitleService(context: fixture.container.mainContext), skillStore: fixture.store,
            providerFactory: { DraftCallingProvider(calls: calls, capture: capture, hold: hold) }
        )
    }

    func testUnrequestedMalformedCallSkipsValidationAndCardAndWritesOnlyAudit() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let session = try runner(fixture, calls: ["invalid JSON", draftJSON()])
        session.send("ordinary work")
        await session.waitUntilFinished()
        XCTAssertNil(session.pendingApproval)
        let results = session.messages.filter { $0.role == .tool }.map(\.content)
        XCTAssertEqual(results, ["not requested", "not requested"])
        XCTAssertEqual(try fixture.audits("skill.draftUnrequested").count, 2)
        XCTAssertTrue(try fixture.audits("skill.draftShown").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new-skill").path))
    }

    func testNoSkillSessionAlsoReturnsNotRequestedAndAuditsIt() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let loop = AgentLoop(auditSink: { record in
            fixture.container.mainContext.insert(AuditEntry(record))
            try fixture.container.mainContext.save()
        })
        try await loop.streamResponse(
            to: [.init(role: .user, content: "ordinary work")], using: DraftCallingProvider(calls: ["bad JSON"]),
            invocationContext: { .init(conversationID: fixture.conversation.id) },
            onEvent: { event in
                if case .confirmationRequested = event {
                    XCTFail("unrequested card")
                }
            }
        )
        XCTAssertEqual(try fixture.audits("skill.draftUnrequested").count, 1)
    }

    func testRequestAllowsOneCardAndRejectWritesNothing() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let json = try draftJSON(files: [["path": "refs/a", "content": "FULL FILE CONTENT"]])
        let session = runner(fixture, calls: [json, json])
        XCTAssertTrue(session.createSkillFromSession())
        try await fixture.wait { session.pendingApproval != nil }
        let request = try XCTUnwrap(session.pendingApproval)
        XCTAssertEqual(session.status, .needsApproval(risk: .caution))
        XCTAssertTrue(request.neverRemember)
        let shown = try SkillDraft.parse(Data(request.toolCall.function.arguments.utf8))
        XCTAssertTrue(shown.files[0].content.contains("Inspect logs. Summarize evidence."))
        XCTAssertEqual(shown.files[1].content, "FULL FILE CONTENT")
        XCTAssertFalse(try XCTUnwrap(session.skillDraft).requested)
        session.resolveApproval(id: request.id, decision: .rejected)
        await session.waitUntilFinished()
        XCTAssertEqual(session.messages.filter { $0.role == .tool }.map(\.content), ["rejected", "not requested"])
        XCTAssertEqual(try fixture.audits("skill.draftShown").count, 1)
        XCTAssertEqual(try fixture.audits("skill.draftRejected").count, 1)
        XCTAssertEqual(try fixture.audits("skill.draftUnrequested").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.stagingRoot.path))
        let scanned = try await fixture.store.rescan()
        XCTAssertTrue(scanned.isEmpty)
    }

    func testValidationErrorKeepsRequestAndRetryCanReachCard() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let session = try runner(
            fixture,
            calls: [draftJSON(files: [["path": ".env", "content": "hidden"]]), draftJSON()]
        )
        session.createSkillFromSession()
        try await fixture.wait { session.pendingApproval != nil }
        XCTAssertTrue(session.messages
            .contains { $0.role == .tool && $0.content.contains("invalid or hidden relative path") })
        XCTAssertEqual(try fixture.audits("skill.draftShown").count, 1)
        try session.resolveApproval(id: XCTUnwrap(session.pendingApproval).id, decision: .approved)
        await session.waitUntilFinished()
        let entries = try await fixture.store.rescan()
        XCTAssertEqual(entries.first?.state, .disabled)
        XCTAssertEqual(entries.first?.origin, "model-drafted")
        XCTAssertTrue(try fixture.audits("skill.draftRejected").isEmpty)
    }

    func testValidationErrorsNeverConsumeRequestOrCreateCard() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let draft = SessionSkillDraft(store: fixture.store, conversationID: fixture.conversation.id)
        draft.request()
        let failures = try [
            draftJSON(name: "INVALID"), draftJSON(description: ""),
            draftJSON(files: [["path": "a/../b", "content": "x"]]),
            draftJSON(files: [["path": "a", "content": "x"], ["path": "a", "content": "x"]]),
            draftJSON(files: [["path": "SKILL.md", "content": "x"]]),
            draftJSON(instructions: String(repeating: "x", count: 16385)),
            draftJSON(files: [["path": "a", "content": String(repeating: "x", count: 32769)]]),
            draftJSON(files: (0 ..< 11).map { ["path": "\($0)", "content": ""] }),
            draftJSON(files: [["path": "a", "content": "\0"]]),
        ]
        for raw in failures {
            do { _ = try await draft.prepare(raw); XCTFail("invalid draft accepted") } catch {}
            XCTAssertTrue(draft.requested)
        }
        XCTAssertTrue(try fixture.audits("skill.draftShown").isEmpty)
    }

    func testNameCollisionIsErrorWithoutCardAndKeepsRequest() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write("new-skill")
        let draft = SessionSkillDraft(store: fixture.store, conversationID: fixture.conversation.id)
        draft.request()
        do { _ = try await draft.prepare(draftJSON()); XCTFail("collision accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("new-skill-2, new-skill-3, new-skill-4"))
        }
        XCTAssertTrue(draft.requested)
        XCTAssertTrue(try fixture.audits("skill.draftShown").isEmpty)
    }

    func testCancellationBeforeCallAndNormalGenerationEndClearRequest() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let held = runner(fixture, calls: [], hold: true)
        held.createSkillFromSession()
        try await fixture.wait { held.messages.contains { $0.role == .assistant && $0.content == "waiting" } }
        XCTAssertTrue(try XCTUnwrap(held.skillDraft).requested)
        held.cancel()
        XCTAssertFalse(try XCTUnwrap(held.skillDraft).requested)
        await held.waitUntilFinished()
        let normal = runner(fixture, calls: [])
        normal.createSkillFromSession()
        await normal.waitUntilFinished()
        XCTAssertFalse(try XCTUnwrap(normal.skillDraft).requested)
    }

    func testCancellationAtCardWritesNothingAndAuditsRejection() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let session = try runner(fixture, calls: [draftJSON()])
        session.createSkillFromSession()
        try await fixture.wait { session.pendingApproval != nil }
        session.cancel()
        await session.waitUntilFinished()
        XCTAssertNil(session.pendingApproval)
        let scanned = try await fixture.store.rescan()
        XCTAssertTrue(scanned.isEmpty)
        XCTAssertEqual(try fixture.audits("skill.draftRejected").count, 1)
    }

    func testSecondRequestedDraftPromptsAgainDespiteCautionMemoryAndPetCannotApprove() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let memory = SessionPermissions()
        memory.remember(conversationID: fixture.conversation.id, toolName: "write_file", riskLevel: .caution)
        memory.remember(conversationID: fixture.conversation.id, toolName: "create_skill_draft", riskLevel: .caution)
        XCTAssertFalse(memory.allows(
            conversationID: fixture.conversation.id,
            toolName: "create_skill_draft",
            riskLevel: .caution
        ))
        XCTAssertTrue(memory.allows(
            conversationID: fixture.conversation.id,
            toolName: "write_file",
            riskLevel: .caution
        ))
        let session = try runner(fixture, calls: [draftJSON()], permissions: memory)
        for _ in 0 ..< 2 {
            session.createSkillFromSession()
            try await fixture.wait { session.pendingApproval != nil }
            let id = try XCTUnwrap(session.pendingApproval).id
            session.resolveApproval(id: id, decision: .approved, source: .pet)
            XCTAssertNotNil(session.pendingApproval)
            session.resolveApproval(id: id, decision: .rejected, rememberForSession: true)
            await session.waitUntilFinished()
        }
        XCTAssertEqual(try fixture.audits("skill.draftShown").count, 2)
        XCTAssertFalse(memory.allows(
            conversationID: fixture.conversation.id,
            toolName: "create_skill_draft",
            riskLevel: .caution
        ))
    }

    func testApprovedDraftCannotRememberAndNextExplicitRequestPromptsAgain() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let memory = SessionPermissions()
        let calls = try [draftJSON(name: "first-draft"), draftJSON(name: "second-draft")]
        var generation = 0
        let session = SessionRunner(
            conversation: fixture.conversation, modelContext: fixture.container.mainContext,
            agentLoop: AgentLoop(sessionPermissions: memory),
            autoTitles: AutoTitleService(context: fixture.container.mainContext), skillStore: fixture.store,
            providerFactory: {
                let provider = DraftCallingProvider(calls: [calls[min(generation, 1)]])
                generation += 1
                return provider
            }
        )
        for _ in 0 ..< 2 {
            XCTAssertTrue(session.createSkillFromSession())
            try await fixture.wait { session.pendingApproval != nil }
            try session.resolveApproval(
                id: XCTUnwrap(session.pendingApproval).id, decision: .approved, rememberForSession: true
            )
            await session.waitUntilFinished()
        }
        let scanned = try await fixture.store.rescan()
        XCTAssertEqual(scanned.count, 2)
        XCTAssertTrue(scanned.allSatisfy { $0.state == .disabled && $0.origin == "model-drafted" })
        XCTAssertTrue(memory.permissions.isEmpty)
        XCTAssertEqual(try fixture.audits("skill.draftShown").count, 2)
        XCTAssertEqual(try fixture.audits("skill.draftApproved").count, 2)
    }

    func testCommandAndMenuActionSendExactBuiltInInstructionAsUserMessage() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let capture = SkillPromptCapture()
        let model = ChatViewModel(
            modelContext: fixture.container.mainContext, providerFactory: { DraftCallingProvider(
                calls: [],
                capture: capture
            ) }
        )
        model.registry.skillStore = fixture.store
        model.selectConversation(fixture.conversation)
        model.input = "/skill new"
        model.send()
        let session = model.registry.runner(for: fixture.conversation)
        await session.waitUntilFinished()
        XCTAssertEqual(model.input, "")
        XCTAssertEqual(session.messages.last(where: { $0.role == .user })?.content, SessionSkillDraft.instruction)
        XCTAssertTrue(model.createSkillFromSession(fixture.conversation))
        await session.waitUntilFinished()
        XCTAssertEqual(
            session.messages.filter { $0.role == .user }.map(\.content),
            Array(repeating: SessionSkillDraft.instruction, count: 2)
        )
        let requests = await capture.requests
        XCTAssertTrue(requests
            .contains { $0.contains { $0.role == .user && $0.content == SessionSkillDraft.instruction } })
    }

    func testRequestDoesNotAuthorizeAnotherSession() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let requested = SessionSkillDraft(store: fixture.store, conversationID: fixture.conversation.id)
        let other = SessionSkillDraft(store: fixture.store, conversationID: UUID())
        requested.request()
        let result = try await other.prepare(draftJSON())
        XCTAssertNil(result)
        XCTAssertTrue(requested.requested)
        XCTAssertEqual(try fixture.audits("skill.draftUnrequested").count, 1)
    }
}
