import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillSnapshotTests: XCTestCase {
    private func url(_ fixture: SkillSessionFixture, hash: String) -> URL {
        fixture.store.snapshotRoot.appendingPathComponent("sample/\(hash)/SKILL.md")
    }

    private func setPin(_ fixture: SkillSessionFixture, hash: String) throws -> Project {
        let project = Project(name: "Snapshot references")
        fixture.container.mainContext.insert(project)
        project.pinnedSkillsData = try JSONEncoder().encode([
            SkillAttachment(id: "sample", hash: hash, source: "appFolder"),
        ])
        fixture.conversation.project = project
        try fixture.container.mainContext.save()
        return project
    }

    func testEnableWritesSnapshotAndMetadataManifestWithoutContent() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: hash).path))
        let text = try String(contentsOf: url(fixture, hash: hash), encoding: .utf8)
        XCTAssertTrue(text.contains("Secret skill instructions"))
        let record = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<SkillRecord>()).first)
        let data = try XCTUnwrap(record.manifestsData)
        let manifests = try JSONDecoder().decode([String: [SkillFile]].self, from: data)
        XCTAssertEqual(manifests[hash]?.first?.path, "SKILL.md")
        XCTAssertEqual(manifests[hash]?.first?.size, text.utf8.count)
        XCTAssertEqual(manifests[hash]?.first?.digest, SkillHasher.digest(Data(text.utf8)))
        XCTAssertFalse((String(data: data, encoding: .utf8) ?? "").contains("Secret skill instructions"))
        XCTAssertFalse(fixture.store.snapshotRoot.path.hasPrefix(fixture.root.path + "/"))
    }

    func testReviewShowsAddedRemovedChangedFilesAndExactSizesAndDiff() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write(body: "old line\n")
        let folder = fixture.root.appendingPathComponent("sample")
        try Data("old".utf8).write(to: folder.appendingPathComponent("change.txt"))
        try Data("remove".utf8).write(to: folder.appendingPathComponent("gone.txt"))
        let initial = try await fixture.store.rescan()
        _ = try await fixture.store.enable("sample", expectedHash: XCTUnwrap(initial.first?.hash))
        try fixture.write(body: "new line\n")
        try Data("new data".utf8).write(to: folder.appendingPathComponent("change.txt"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gone.txt"))
        try Data("hello".utf8).write(to: folder.appendingPathComponent("added.txt"))
        let review = try await fixture.store.review("sample")
        XCTAssertTrue(review.hasSnapshot)
        XCTAssertEqual(review.changes.map(\.path), ["SKILL.md", "added.txt", "change.txt", "gone.txt"])
        let added = try XCTUnwrap(review.changes.first { $0.path == "added.txt" })
        XCTAssertEqual(added.kind, .added)
        XCTAssertNil(added.oldSize)
        XCTAssertEqual(added.newSize, 5)
        let changed = try XCTUnwrap(review.changes.first { $0.path == "change.txt" })
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertEqual(changed.oldSize, 3)
        XCTAssertEqual(changed.newSize, 8)
        let removed = try XCTUnwrap(review.changes.first { $0.path == "gone.txt" })
        XCTAssertEqual(removed.kind, .removed)
        XCTAssertEqual(removed.oldSize, 6)
        XCTAssertNil(removed.newSize)
        XCTAssertTrue(try XCTUnwrap(review.diff).lines.contains { $0.kind == "-" && $0.text == "old line" })
        XCTAssertTrue(try XCTUnwrap(review.diff).lines.contains { $0.kind == "+" && $0.text == "new line" })
    }

    func testReviewWithoutLegacySnapshotShowsCurrentListAndFullText() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write()
        let scanned = try await fixture.store.rescan()
        let record = try XCTUnwrap(fixture.container.mainContext.fetch(FetchDescriptor<SkillRecord>()).first)
        record.state = .enabled
        record.enabledHash = scanned.first?.hash
        try fixture.container.mainContext.save()
        let review = try await fixture.store.review("sample")
        XCTAssertFalse(review.hasSnapshot)
        XCTAssertNil(review.diff)
        XCTAssertEqual(review.changes.map(\.kind), [.current])
        XCTAssertTrue(review.current.text.contains("Secret skill instructions"))
        XCTAssertNil(record.manifestsData)
    }

    func testOpeningAndCancellingReviewDoesNotChangeHashesPinsOrSnapshots() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let oldHash = try await fixture.enable()
        let project = try setPin(fixture, hash: oldHash)
        try fixture.write(body: "Unapproved edit")
        let review = try await fixture.store.review("sample", referenceHash: oldHash)
        XCTAssertNotEqual(review.current.hash, oldHash)
        let record = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<SkillRecord>()).first)
        XCTAssertEqual(record.enabledHash, oldHash)
        XCTAssertEqual(project.pinnedSkills.first?.hash, oldHash)
        XCTAssertEqual(try fixture.audits("skill.reconfirm").count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: oldHash).path))
    }

    func testChangedAfterReviewRefusesSettingsAndProjectConfirmation() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let oldHash = try await fixture.enable()
        let project = try setPin(fixture, hash: oldHash)
        try fixture.write(body: "Shown edit")
        let review = try await fixture.store.review("sample", referenceHash: oldHash)
        try Data("not shown".utf8).write(to: fixture.root.appendingPathComponent("sample/new.txt"))
        do {
            _ = try await fixture.store.reconfirm("sample", expectedHash: XCTUnwrap(review.current.hash))
            XCTFail("Stale Settings confirmation accepted")
        } catch { XCTAssertEqual(error as? SkillValidationError, .changedSincePreview) }
        do {
            try await fixture.skills.confirmReview(review, pin: XCTUnwrap(project.pinnedSkills.first))
            XCTFail("Stale project confirmation accepted")
        } catch { XCTAssertEqual(error as? SkillValidationError, .changedSincePreview) }
        XCTAssertEqual(project.pinnedSkills.first?.hash, oldHash)
        XCTAssertTrue(fixture.skills.attached.isEmpty)
        XCTAssertEqual(try fixture.audits("skill.reconfirm").count, 0)
    }

    func testReconfirmWritesNewSnapshotKeepsPinnedOldThenUnpinCleansIt() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let oldHash = try await fixture.enable()
        let project = try setPin(fixture, hash: oldHash)
        try fixture.write(body: "Approved new version")
        let review = try await fixture.store.review("sample")
        let newHash = try XCTUnwrap(review.current.hash)
        _ = try await fixture.store.reconfirm("sample", expectedHash: newHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: oldHash).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: newHash).path))
        try await fixture.skills.unpin("sample")
        XCTAssertTrue(project.pinnedSkills.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(fixture, hash: oldHash).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: newHash).path))
        _ = try await fixture.store.disable("sample")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(fixture, hash: newHash).path))
    }

    func testTwoProjectsKeepSnapshotUntilLastPinIsDeleted() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        let first = try setPin(fixture, hash: hash)
        let second = try setPin(fixture, hash: hash)
        _ = try await fixture.store.disable("sample")
        try SkillProjectActions.unpin("sample", project: first, context: fixture.container.mainContext)
        try await fixture.store.cleanupSnapshots()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: hash).path))
        fixture.container.mainContext.delete(second)
        try fixture.container.mainContext.save()
        try await fixture.store.cleanupSnapshots()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(fixture, hash: hash).path))
    }

    func testPinCreatesMissingLegacySnapshot() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        _ = try setPin(fixture, hash: hash)
        try FileManager.default.removeItem(at: fixture.store.snapshotRoot)
        _ = try await fixture.skills.attach("sample")
        try await fixture.skills.pin("sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(fixture, hash: hash).path))
    }

    func testCorruptOrSymlinkSnapshotFallsBackWithoutFollowingLink() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        let snapshot = url(fixture, hash: hash)
        try Data("tampered".utf8).write(to: snapshot)
        let corrupt = try await fixture.store.review("sample")
        XCTAssertFalse(corrupt.hasSnapshot)
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(atPath: snapshot.path, withDestinationPath: "/etc/passwd")
        let linked = try await fixture.store.review("sample")
        XCTAssertFalse(linked.hasSnapshot)
        XCTAssertFalse(linked.current.text.contains("root:"))
    }

    func testSnapshotDirectorySymlinkCannotRedirectEnable() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write()
        let target = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.store.snapshotRoot, withDestinationURL: target)
        let scanned = try await fixture.store.rescan()
        do {
            _ = try await fixture.store.enable(
                "sample", expectedHash: XCTUnwrap(scanned.first { $0.id == "sample" }?.hash)
            )
            XCTFail("Snapshot root symlink accepted")
        } catch {}
        let state = try await fixture.store.state(of: "sample")
        XCTAssertEqual(state, .disabled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testSkillRemovalDeletesPinsManifestsAndSnapshots() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let hash = try await fixture.enable()
        _ = try setPin(fixture, hash: hash)
        let entries = try await fixture.store.remove("sample")
        XCTAssertTrue(entries.isEmpty)
        let context = ModelContext(fixture.container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SkillRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).allSatisfy(\.pinnedSkills.isEmpty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(fixture, hash: hash).path))
        XCTAssertEqual(try fixture.audits("skill.removed").count, 1)
    }

    func testModelFileToolsCannotAccessSnapshotEvenWithAllowRule() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent(
            "Library/Application Support/local.test/skill-snapshots/sample/hash/SKILL.md"
        ).path
        var rules = ApplicationProtection.rules(
            storeURL: home.appendingPathComponent("store"), bundleID: "local.test", home: home
        )
        rules.append(.init(pattern: path, action: .allow, order: -1000))
        let policy = SecurityPolicyEngine(rules: rules)
        for tool: any Tool in [
            ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SearchFilesTool(), DeleteFileTool(), MoveFileTool(),
        ] {
            XCTAssertEqual(
                policy.decision(
                    for: tool, arguments: ["path": path, "root": path, "from": path, "to": path]
                ).disposition,
                .blocked
            )
        }
    }
}
