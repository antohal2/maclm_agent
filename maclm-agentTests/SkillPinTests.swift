import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillPinTests: XCTestCase {
    private func project(_ fixture: SkillSessionFixture) throws -> Project {
        let project = Project(name: "Skills project")
        fixture.container.mainContext.insert(project)
        fixture.conversation.project = project
        try fixture.container.mainContext.save()
        return project
    }

    @discardableResult private func pin(_ id: String = "sample", fixture: SkillSessionFixture) async throws -> String {
        let hash = try await fixture.enable(id)
        _ = try await fixture.skills.attach(id)
        try await fixture.skills.pin(id)
        return hash
    }

    private func newSession(_ fixture: SkillSessionFixture, project: Project?) throws -> SessionSkills {
        let conversation = Conversation()
        conversation.project = project
        fixture.container.mainContext.insert(conversation)
        try fixture.container.mainContext.save()
        return SessionSkills(store: fixture.store, conversation: conversation, context: fixture.container.mainContext)
    }

    func testPinAutoAttachesOnNewSessionAndOpenAndAuditsProjectID() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        let hash = try await pin(fixture: fixture)
        let fresh = try newSession(fixture, project: project)
        try await fresh.prepare()
        XCTAssertEqual(fresh.attached.map(\.reference.hash), [hash])
        let reopened = SessionSkills(
            store: fixture.store,
            conversation: fresh.conversation,
            context: fixture.container.mainContext
        )
        try await reopened.refreshCatalog()
        XCTAssertEqual(reopened.attached.map(\.id), ["sample"])
        XCTAssertEqual(try fixture.audits("skill.pin").count, 1)
        let audit = try XCTUnwrap(fixture.audits("skill.autoAttached").first)
        XCTAssertEqual(audit.decision, .auto)
        XCTAssertTrue(audit.argumentsJSON.contains(project.id.uuidString))
        XCTAssertEqual(try fixture.audits("skill.autoAttached").count, 1)
    }

    func testExistingUnattachedSessionAttachesWhenOpenedAfterPin() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        let existing = try newSession(fixture, project: project)
        try await existing.prepare()
        try await pin(fixture: fixture)
        try await existing.refreshCatalog()
        XCTAssertEqual(existing.attached.map(\.id), ["sample"])
    }

    func testMismatchKeepsInactivePinShowsBannerAndProjectAuditOnce() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        let hash = try await pin(fixture: fixture)
        try fixture.write(body: "New instructions")
        let fresh = try newSession(fixture, project: project)
        try await fresh.refreshCatalog()
        try await fresh.refreshCatalog()
        XCTAssertTrue(fresh.attached.isEmpty)
        XCTAssertEqual(project.pinnedSkills.first?.hash, hash)
        XCTAssertEqual(fresh.changedPins.map(\.id), ["sample"])
        let events = try fixture.audits("skill.hashMismatch").filter {
            $0.argumentsJSON.contains(project.id.uuidString)
        }
        XCTAssertEqual(events.count, 1)
    }

    func testExplicitDetachWinsOnReopenAndManualAttachClearsSuppression() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        _ = try project(fixture)
        try await pin(fixture: fixture)
        fixture.skills.detach("sample")
        let reopened = fixture.restarted()
        try await reopened.refreshCatalog()
        XCTAssertTrue(reopened.attached.isEmpty)
        XCTAssertEqual(reopened.detachedPins, ["sample"])
        _ = try await reopened.attach("sample")
        XCTAssertTrue(reopened.detachedPins.isEmpty)
        let again = fixture.restarted()
        try await again.prepare()
        XCTAssertEqual(again.attached.map(\.id), ["sample"])
    }

    func testDisabledAndProjectlessSessionsDoNotAutoAttach() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        try await pin(fixture: fixture)
        let free = try newSession(fixture, project: nil)
        try await free.prepare()
        XCTAssertTrue(free.attached.isEmpty)
        XCTAssertTrue(free.changedPins.isEmpty)
        _ = try await fixture.store.disable("sample")
        let fresh = try newSession(fixture, project: project)
        try await fresh.prepare()
        XCTAssertTrue(fresh.attached.isEmpty)
        XCTAssertTrue(fresh.changedPins.isEmpty)
        XCTAssertEqual(project.pinnedSkills.count, 1)
    }

    func testCountOverflowFollowsPinOrderAndReportsRemaining() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        var pins: [SkillAttachment] = []
        for id in ["zulu", "third", "alpha", "last"] {
            let hash = try await fixture.enable(id)
            pins.append(.init(id: id, hash: hash, source: "appFolder"))
        }
        project.pinnedSkillsData = try JSONEncoder().encode(pins)
        try fixture.container.mainContext.save()
        let fresh = try newSession(fixture, project: project)
        try await fresh.prepare()
        XCTAssertEqual(fresh.attached.map(\.id), ["zulu", "third", "alpha"])
        XCTAssertEqual(fresh.notices.count, 1)
        XCTAssertTrue(try XCTUnwrap(fresh.notices.first).contains("last"))
        XCTAssertEqual(project.pinnedSkills.count, 4)
    }

    func testTokenOverflowUsesSameBudgetWithoutTruncation() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        for id in ["first", "second"] {
            let hash = try await fixture.enable(id, body: String(repeating: "я", count: 200))
            var pins = project.pinnedSkills
            pins.append(.init(id: id, hash: hash, source: "appFolder"))
            project.pinnedSkillsData = try JSONEncoder().encode(pins)
        }
        try fixture.container.mainContext.save()
        let fresh = try newSession(fixture, project: project)
        fresh.contextWindow = { 1600 }
        try await fresh.prepare()
        XCTAssertEqual(fresh.attached.map(\.id), ["first"])
        XCTAssertEqual(fresh.attached.first?.body, String(repeating: "я", count: 200))
        XCTAssertEqual(fresh.notices.count, 1)
    }

    func testSettingsReconfirmLeavesOldPinInactiveUntilProjectReview() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        let old = try await pin(fixture: fixture)
        try fixture.write(body: "New instructions")
        let settingsReview = try await fixture.store.review("sample")
        let newHash = try XCTUnwrap(settingsReview.current.hash)
        _ = try await fixture.store.reconfirm("sample", expectedHash: newHash)
        XCTAssertEqual(project.pinnedSkills.first?.hash, old)
        let fresh = try newSession(fixture, project: project)
        try await fresh.refreshCatalog()
        XCTAssertTrue(fresh.attached.isEmpty)
        let reference = try XCTUnwrap(fresh.changedPins.first)
        let review = try await fixture.store.review("sample", referenceHash: reference.hash)
        XCTAssertTrue(review.hasSnapshot)
        XCTAssertTrue(try XCTUnwrap(review.diff).lines.contains { $0.kind == "-" && $0.text.contains("Secret") })
        try await fresh.confirmReview(review, pin: reference)
        XCTAssertEqual(project.pinnedSkills.first?.hash, newHash)
        XCTAssertEqual(fresh.attached.first?.reference.hash, newHash)
        XCTAssertTrue(fresh.changedPins.isEmpty)
        let event = try XCTUnwrap(fixture.audits("skill.reconfirm").first {
            $0.argumentsJSON.contains(project.id.uuidString)
        })
        XCTAssertTrue(event.argumentsJSON.contains(old))
        XCTAssertTrue(event.argumentsJSON.contains(newHash))
    }

    func testUnpinStopsAutoAttachButKeepsExistingAttachment() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        try await pin(fixture: fixture)
        try await fixture.skills.unpin("sample")
        XCTAssertTrue(project.pinnedSkills.isEmpty)
        XCTAssertEqual(fixture.skills.attached.map(\.id), ["sample"])
        let fresh = try newSession(fixture, project: project)
        try await fresh.prepare()
        XCTAssertTrue(fresh.attached.isEmpty)
        XCTAssertEqual(try fixture.audits("skill.unpin").count, 1)
    }

    func testProjectReviewUpdatesOnlyThatProject() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let first = try project(fixture)
        let oldHash = try await pin(fixture: fixture)
        let second = Project(name: "Other project")
        second.pinnedSkillsData = first.pinnedSkillsData
        fixture.container.mainContext.insert(second)
        try fixture.container.mainContext.save()
        try fixture.write(body: "Reviewed for first project")
        try await fixture.skills.refreshCatalog()
        let pin = try XCTUnwrap(first.pinnedSkills.first)
        let review = try await fixture.store.review("sample", referenceHash: oldHash)
        try await fixture.skills.confirmReview(review, pin: pin)
        XCTAssertEqual(first.pinnedSkills.first?.hash, review.current.hash)
        XCTAssertEqual(second.pinnedSkills.first?.hash, oldHash)
        let otherSession = try newSession(fixture, project: second)
        try await otherSession.prepare()
        XCTAssertTrue(otherSession.attached.isEmpty)
        XCTAssertEqual(otherSession.changedPins.first?.hash, oldHash)
    }

    func testChatViewModelCreationAndSelectionUseSharedStoreForAutoAttach() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let project = try project(fixture)
        try await pin(fixture: fixture)
        let model = ChatViewModel(modelContext: fixture.container.mainContext)
        model.registry.skillStore = fixture.store
        let created = model.createConversation(project: project)
        let skills = try XCTUnwrap(model.registry.runner(for: created).skills)
        XCTAssertTrue(skills.store === fixture.store)
        try await fixture.wait { skills.attached.count == 1 }
        skills.detach("sample")
        let existing = Conversation()
        existing.project = project
        fixture.container.mainContext.insert(existing)
        try fixture.container.mainContext.save()
        model.selectConversation(existing)
        let opened = try XCTUnwrap(model.registry.runner(for: existing).skills)
        try await fixture.wait { opened.attached.count == 1 }
        XCTAssertEqual(opened.attached.map(\.id), ["sample"])
        XCTAssertTrue(skills.attached.isEmpty)
    }

    func testChatViewModelProjectDeletionCleansOldSnapshotForBothDeletionModes() async throws {
        for includingConversations in [false, true] {
            let fixture = try SkillSessionFixture()
            defer { fixture.clean() }
            let project = try project(fixture)
            let hash = try await pin(fixture: fixture)
            _ = try await fixture.store.disable("sample")
            let snapshot = fixture.store.snapshotRoot.appendingPathComponent("sample/\(hash)/SKILL.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
            let model = ChatViewModel(modelContext: fixture.container.mainContext)
            model.registry.skillStore = fixture.store
            model.deleteProject(project, includingConversations: includingConversations)
            try await fixture.wait { !FileManager.default.fileExists(atPath: snapshot.path) }
            XCTAssertTrue(try fixture.container.mainContext.fetch(FetchDescriptor<Project>()).isEmpty)
        }
    }

    func testCatalogPinsFirstThenStableAfterAttachUsageAndRelaunch() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        _ = try project(fixture)
        try await fixture.enable("alpha")
        try await pin("zulu", fixture: fixture)
        try await fixture.skills.refreshCatalog()
        let first = fixture.skills.prompt.components(separatedBy: "\n").prefix(3)
        XCTAssertTrue(first.dropFirst().first?.hasPrefix("zulu:") == true)
        _ = try await fixture.skills.attach("alpha")
        await fixture.skills.updateCatalogMetadata()
        XCTAssertEqual(Array(first), Array(fixture.skills.prompt.components(separatedBy: "\n").prefix(3)))
        try await fixture.enable("aardvark")
        await fixture.skills.updateCatalogMetadata()
        let catalog = fixture.skills.prompt.components(separatedBy: "\n")
        XCTAssertTrue(catalog[3].hasPrefix("aardvark:"))
        let restarted = fixture.restarted()
        try await restarted.refreshCatalog()
        XCTAssertEqual(Array(catalog.prefix(4)), Array(restarted.prompt.components(separatedBy: "\n").prefix(4)))
    }
}
