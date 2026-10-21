import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillSessionTests: XCTestCase {
    func testCatalogMetadataRefreshExcludesDisabledSkillWithoutReadingBody() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        try await fixture.skills.refreshCatalog()
        XCTAssertTrue(fixture.skills.prompt.contains("sample:"))
        try fixture.write(body: "Changed on disk")
        await fixture.skills.updateCatalogMetadata()
        XCTAssertEqual(try fixture.audits("skill.hashMismatch").count, 0)
        _ = try await fixture.store.disable("sample")
        await fixture.skills.updateCatalogMetadata()
        XCTAssertFalse(fixture.skills.prompt.contains("sample:"))
    }

    func testAuxiliaryChangesAlsoRefuseAttach() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        try Data("new reference".utf8).write(to: fixture.root.appendingPathComponent("sample/reference.txt"))
        do { _ = try await fixture.skills.attach("sample"); XCTFail("Folder hash mismatch accepted") } catch {}
        let state = try await fixture.store.state(of: "sample")
        XCTAssertEqual(state, .needsReconfirm)
        XCTAssertTrue(fixture.skills.attached.isEmpty)
    }

    func testCumulativeBudgetAndReopenedSessionReverification() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable("first", body: String(repeating: "a", count: 200))
        try await fixture.enable("second", body: String(repeating: "b", count: 200))
        fixture.skills.contextWindow = { 1024 }
        _ = try await fixture.skills.attach("first")
        do { _ = try await fixture.skills.attach("second"); XCTFail("Cumulative budget exceeded") } catch {}
        XCTAssertEqual(fixture.skills.attached.count, 1)
        XCTAssertEqual(fixture.skills.attached.first?.body.count, 200)
        _ = try await fixture.store.disable("first")
        try await fixture.skills.refreshCatalog()
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        XCTAssertFalse(fixture.skills.notices.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.audits("skill.detached").first).argumentsJSON.contains("disabled"))
    }

    func testAttachReadsVerifiedBodyAndRetainsItInMemory() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        _ = try await fixture.skills.attach("sample")
        XCTAssertEqual(fixture.skills.attached.first?.body, "Secret skill instructions")
        XCTAssertEqual(fixture.skills.attached.first?.reference.hash, hash)
        try fixture.write(body: "Changed on disk")
        XCTAssertTrue(fixture.skills.prompt.contains("Secret skill instructions"))
        XCTAssertFalse(fixture.skills.prompt.contains("Changed on disk"))
        let saved = try JSONDecoder().decode(
            [SkillAttachment].self,
            from: XCTUnwrap(fixture.conversation.attachedSkillsData)
        )
        XCTAssertEqual(saved, [.init(id: "sample", hash: hash, source: "appFolder")])
        XCTAssertFalse((String(data: fixture.conversation.attachedSkillsData ?? Data(), encoding: .utf8) ?? "")
            .contains("Secret"))
    }

    func testHashMismatchRefusesAttachAndRequiresReconfirm() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        try await fixture.skills.prepare()
        try fixture.write(body: "Modified after enable")
        do { _ = try await fixture.skills.attach("sample"); XCTFail("Changed skill attached") } catch { XCTAssertEqual(
            error as? SkillValidationError,
            .reconfirmRequired
        ) }
        let scanned = try await fixture.store.rescan()
        XCTAssertEqual(scanned.first?.state, .needsReconfirm)
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        XCTAssertEqual(try fixture.audits("skill.hashMismatch").count, 1)
    }

    func testFourthAttachmentRefusedAndDuplicateIsIdempotent() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        for name in ["first", "second", "third", "fourth"] {
            try await fixture.enable(name)
        }
        for name in ["first", "second", "third", "first"] {
            _ = try await fixture.skills.attach(name)
        }
        do { _ = try await fixture.skills.attach("fourth"); XCTFail("Fourth attached") } catch {
            XCTAssertTrue(error is SkillAttachError)
        }
        XCTAssertEqual(fixture.skills.attached.count, 3)
        XCTAssertEqual(try fixture.audits("skill.attached").count, 3)
    }

    func testTokenBudgetRefusesWithoutTruncatingAndIncludesWrapper() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable(body: String(repeating: "я", count: 4000))
        do { _ = try await fixture.skills.attach("sample"); XCTFail("Over budget") } catch {}
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        fixture.skills.contextWindow = { 20000 }
        _ = try await fixture.skills.attach("sample")
        XCTAssertEqual(fixture.skills.attached.first?.body.count, 4000)
        fixture.skills.detach("sample")
        fixture.skills.contextWindow = { 1 }
        do { _ = try await fixture.skills.attach("sample"); XCTFail("Wrapper exceeds budget") } catch {}
        XCTAssertTrue(fixture.skills.attached.isEmpty)
    }

    func testRelaunchRereadsUnchangedSkillAndUserDetachAudits() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        _ = try await fixture.skills.attach("sample")
        let restarted = fixture.restarted()
        try await restarted.prepare()
        XCTAssertEqual(restarted.attached.first?.reference.hash, hash)
        XCTAssertEqual(restarted.attached.first?.body, "Secret skill instructions")
        restarted.detach("sample")
        XCTAssertTrue(restarted.attached.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.audits("skill.detached").first).argumentsJSON.contains("user"))
        XCTAssertEqual(try fixture.audits("skill.attached").count, 1)
    }

    func testRelaunchChangedDisabledAndReconfirmedAreDetachedWithNotice() async throws {
        for mode in ["changed", "disabled", "reconfirmed"] {
            let fixture = try SkillSessionFixture()
            defer { fixture.clean() }
            let hash = try await fixture.enable()
            _ = try await fixture.skills.attach("sample")
            if mode == "disabled" {
                _ = try await fixture.store.disable("sample")
            } else {
                try fixture.write(body: "New instructions")
                if mode == "reconfirmed" {
                    let scan = try await fixture.store.rescan()
                    _ = try await fixture.store.reconfirm("sample", expectedHash: XCTUnwrap(scan.first?.hash))
                }
            }
            let restarted = fixture.restarted()
            try await restarted.prepare()
            XCTAssertTrue(restarted.attached.isEmpty, mode)
            XCTAssertFalse(restarted.notices.isEmpty, mode)
            let audit = try XCTUnwrap(fixture.audits("skill.detached").first)
            let arguments = try XCTUnwrap(JSONSerialization
                .jsonObject(with: Data(audit.argumentsJSON.utf8)) as? [String: String])
            XCTAssertEqual(arguments["hash"], hash)
            XCTAssertEqual(arguments["source"], "appFolder")
            XCTAssertEqual(arguments["reason"], mode == "disabled" ? "disabled" : "relaunchMismatch")
            let again = fixture.restarted()
            try await again.prepare()
            XCTAssertTrue(again.attached.isEmpty)
            XCTAssertEqual(try fixture.audits("skill.detached").count, 1)
        }
    }

    func testPaletteUsesAttachChecksAndShowsRefusal() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        XCTAssertEqual(SkillPalette.query("Use @sam"), "sam")
        XCTAssertEqual(SkillPalette.query("@"), "")
        XCTAssertNil(SkillPalette.query("email@example"))
        XCTAssertNil(SkillPalette.query("@sample "))
        let selected = await fixture.skills.selectFromPalette("sample")
        XCTAssertTrue(selected)
        fixture.skills.detach("sample")
        try fixture.write(body: "Tampered")
        let refused = await fixture.skills.selectFromPalette("sample")
        XCTAssertFalse(refused)
        XCTAssertFalse(fixture.skills.notices.isEmpty)
    }
}
