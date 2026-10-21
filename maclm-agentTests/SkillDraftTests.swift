import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

func draftJSON(
    name: String = "new-skill", description: String = "Use when investigating local logs",
    instructions: String = "Inspect logs. Summarize evidence.", files: [[String: String]] = []
) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "name": name, "description": description, "instructions": instructions, "files": files,
    ], options: .sortedKeys)
    return try XCTUnwrap(String(data: data, encoding: .utf8))
}

final class SkillDraftValidationTests: XCTestCase {
    private func parse(_ json: String) throws -> SkillDraft {
        try SkillDraft.parse(Data(json.utf8))
    }

    func testFullContentAndCRLFRoundTripAndQuotedFrontmatter() throws {
        let body = "First\r\nSecond\tline\r\n"
        let description = "When needed: \"logs\"\n---\nname: injected"
        let draft = try parse(draftJSON(description: description, instructions: body, files: [
            ["path": "references/log.txt", "content": body],
        ]))
        XCTAssertTrue(draft.files[0].content.hasSuffix(body))
        XCTAssertEqual(draft.files[1].content, body)
        XCTAssertEqual(draft.files[1].data.count, body.utf8.count)
        XCTAssertEqual(try SkillParser.parse(draft.files[0].data, folderName: draft.name).description, description)
        XCTAssertEqual(draft.hash.count, 64)
    }

    func testNameAndDescriptionUseExistingRules() throws {
        for name in ["", "a--b", "UPPER", "-start", "end-", "../x", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try parse(draftJSON(name: name)), name)
        }
        for description in ["", "  ", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try parse(draftJSON(description: description)))
        }
        XCTAssertNoThrow(try parse(draftJSON(
            name: String(repeating: "a", count: 64),
            description: String(repeating: "a", count: 1024)
        )))
    }

    func testEveryUnsafePathAndReservedSKILLMDRejected() throws {
        for path in [
            ".env",
            "sub/.hidden",
            "../x",
            "a/../x",
            "/tmp/x",
            "~/.x",
            "a\\b",
            "a//b",
            "a\0b",
            "%2e%2e/x",
            "．．/x",
            "a／b",
            "SKILL.md",
            "skill.md",
            ".DS_Store",
            "sub/._x",
        ] {
            XCTAssertThrowsError(try parse(draftJSON(files: [["path": path, "content": "text"]])), path)
        }
    }

    func testDuplicateAndFileDirectoryConflictRejected() throws {
        for paths in [["a", "a"], ["a", "A"], ["a", "a/b"], ["SKILL.md/x"]] {
            XCTAssertThrowsError(try parse(draftJSON(files: paths.map { ["path": $0, "content": "text"] })))
        }
    }

    func testDraftSpecificSizesAndFileCount() throws {
        XCTAssertThrowsError(try parse(draftJSON(instructions: String(repeating: "a", count: 16384))))
        let oversized = String(repeating: "a", count: 32769)
        XCTAssertThrowsError(try parse(draftJSON(files: [["path": "a", "content": oversized]])))
        XCTAssertNoThrow(try parse(draftJSON(files: [["path": "a", "content": String(repeating: "a", count: 32768)]])))
        XCTAssertThrowsError(try parse(draftJSON(files: (0 ..< 11).map { ["path": "file-\($0)", "content": ""] })))
        XCTAssertNoThrow(try parse(draftJSON(files: (0 ..< 10).map { ["path": "file-\($0)", "content": ""] })))
        let minimal = try parse(draftJSON(instructions: ""))
        let exact = String(repeating: "a", count: SkillScanner.maximumInstructions - minimal.files[0].data.count)
        XCTAssertEqual(try parse(draftJSON(instructions: exact)).files[0].data.count, SkillScanner.maximumInstructions)
        XCTAssertThrowsError(try parse(draftJSON(instructions: exact + "a")))
    }

    func testInvalidUTF8AndBinaryControlsAndMissingArguments() throws {
        XCTAssertThrowsError(try SkillDraft.parse(Data([0xC3, 0x28])))
        XCTAssertThrowsError(try SkillDraft.validateText(Data([0xFF])))
        for value in ["nul\0", "escape\u{1B}", "delete\u{7F}"] {
            XCTAssertThrowsError(try parse(draftJSON(instructions: value)))
            XCTAssertThrowsError(try parse(draftJSON(files: [["path": "a", "content": value]])))
        }
        for json in ["{}", "invalid", #"{"name":"x","description":"y","instructions":"z","files":[{}]}"#] {
            XCTAssertThrowsError(try parse(json))
        }
        XCTAssertNoThrow(try SkillDraft.validateText(Data("text\r\n\t✓".utf8)))
    }

    func testDescriptionSecretsAndPersonalPathsAreVisibleInRawFrontmatterWarnings() throws {
        let draft = try parse(draftJSON(description: "Use /Users/name/private/ with token=abcdefgh"))
        XCTAssertTrue(draft.files[0].warnings.contains(.personalPath))
        XCTAssertTrue(draft.files[0].warnings.contains(.assignment))
    }

    func testEachWarningPatternIsAttributedToTheCorrectFile() throws {
        let examples: [(SkillDraftWarning, String)] = [
            (.aws, "AKIA" + String(repeating: "A", count: 16)),
            (.openAI, "sk-" + String(repeating: "a", count: 20)),
            (.github, "ghp_" + String(repeating: "a", count: 30)),
            (.slack, "xoxb-" + String(repeating: "a", count: 10)),
            (.privateKey, "-----BEGIN RSA PRIVATE KEY-----"),
            (
                .jwt,
                "eyJ" + String(repeating: "a", count: 10) + "." + String(repeating: "b", count: 10)
                    + "." + String(repeating: "c", count: 10)
            ),
            (.assignment, "API_KEY = abcdefgh"),
            (.personalPath, "/Users/name/private/"),
        ]
        for (warning, text) in examples {
            let draft = try parse(draftJSON(files: [["path": "warning.txt", "content": text]]))
            XCTAssertTrue(draft.files[0].warnings.isEmpty)
            XCTAssertEqual(draft.files[1].warnings, [warning], text)
            XCTAssertEqual(draft.warningCount, 1)
        }
        for text in ["PASSWORD: abcdefgh", "passwd=abcdefgh", "secret: abcdefgh", "token=abcdefgh"] {
            XCTAssertTrue(SkillDraftWarning.matches(text).contains(.assignment))
        }
        for prefix in ["xoxa-", "xoxp-", "xoxr-", "xoxs-"] {
            XCTAssertTrue(SkillDraftWarning.matches(prefix + "1234567890").contains(.slack))
        }
        XCTAssertTrue(try parse(draftJSON()).files.allSatisfy(\.warnings.isEmpty))
    }
}

@MainActor final class SkillDraftStoreTests: XCTestCase {
    func testApprovedDraftIsDisabledWithOriginAndExactContentsAndAudit() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let draft = try SkillDraft.parse(Data(draftJSON(files: [["path": "refs/a", "content": "reference\r\n"]]).utf8))
        let result = try await fixture.store.saveDraft(draft, conversationID: fixture.conversation.id)
        XCTAssertFalse(result.isError)
        let entries = try await fixture.store.rescan()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .disabled)
        XCTAssertEqual(entry.origin, "model-drafted")
        XCTAssertTrue(entry.showsModelOrigin)
        XCTAssertNil(entry.enabledHash)
        XCTAssertEqual(entry.hash, draft.hash)
        for file in draft.files {
            XCTAssertEqual(
                try Data(contentsOf: fixture.root.appendingPathComponent(draft.name + "/" + file.path)),
                file.data
            )
        }
        let session = SessionSkills(
            store: fixture.store,
            conversation: fixture.conversation,
            context: fixture.container.mainContext
        )
        try await session.refreshCatalog()
        XCTAssertFalse(session.prompt.contains(draft.name))
        let fileResult = await session.fileRequest(.init(action: .read, arguments: ["skill": draft.name]))
        XCTAssertTrue(fileResult.isError)
        let audit = try XCTUnwrap(fixture.audits("skill.draftApproved").first)
        XCTAssertEqual(audit.conversationID, fixture.conversation.id)
        XCTAssertTrue(audit.argumentsJSON.contains(draft.hash))
        XCTAssertTrue(audit.argumentsJSON.contains("warningCount"))
    }

    func testOriginBadgeDisappearsPermanentlyAfterFirstEnable() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let draft = try SkillDraft.parse(Data(draftJSON().utf8))
        _ = try await fixture.store.saveDraft(draft, conversationID: fixture.conversation.id)
        let enabled = try await fixture.store.enable(draft.name, expectedHash: draft.hash)
        XCTAssertFalse(try XCTUnwrap(enabled.first).showsModelOrigin)
        let disabled = try await fixture.store.disable(draft.name)
        XCTAssertFalse(try XCTUnwrap(disabled.first).showsModelOrigin)
        let restarted = SkillStore(root: fixture.root, container: fixture.container)
        let scanned = try await restarted.rescan()
        XCTAssertFalse(try XCTUnwrap(scanned.first).showsModelOrigin)
        XCTAssertEqual(scanned.first?.origin, "model-drafted")
    }

    func testFolderAndAnySourceRecordCollisionSuggestThreeFreeNames() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try fixture.write("new-skill")
        let record = SkillRecord(skillID: "new-skill-2")
        record.source = "codex"
        fixture.container.mainContext.insert(record)
        try fixture.container.mainContext.save()
        do { try await fixture.store.checkDraftName("new-skill"); XCTFail("collision accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("new-skill-3, new-skill-4, new-skill-5"))
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("new-skill"))
        do { try await fixture.store.checkDraftName("new-skill-2"); XCTFail("external record accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("free alternatives"))
        }
    }

    func testMidWriteFailureCleansBothLocationsAndScannerNeverSeesStaging() throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let draft = try SkillDraft.parse(Data(draftJSON(files: [["path": "refs/a", "content": "reference"]]).utf8))
        XCTAssertThrowsError(try SkillDraftIO.write(
            draft,
            root: fixture.root,
            staging: fixture.store.stagingRoot,
            afterFile: { index in
                XCTAssertTrue(try SkillScanner.scan(root: fixture.root).isEmpty)
                XCTAssertFalse(fixture.store.stagingRoot.path.hasPrefix(fixture.root.path + "/"))
                if index == 1 {
                    throw SkillDraftError(reason: "simulated disk failure")
                }
            }
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.store.stagingRoot.path).isEmpty)
    }

    func testConcurrentNameCreationNeverReplacesExistingFolder() throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let draft = try SkillDraft.parse(Data(draftJSON().utf8))
        XCTAssertThrowsError(try SkillDraftIO.write(
            draft,
            root: fixture.root,
            staging: fixture.store.stagingRoot,
            beforeRename: {
                try fixture.write(draft.name, body: "KEEP THIS")
            }
        ))
        XCTAssertTrue(try String(
            contentsOf: fixture.root.appendingPathComponent(draft.name + "/SKILL.md"),
            encoding: .utf8
        )
        .contains("KEEP THIS"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.store.stagingRoot.path).isEmpty)
    }

    func testStartupCleanupRemovesLeftoversWithoutFollowingLinks() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        let staging = fixture.store.stagingRoot
        let partial = staging.appendingPathComponent("interrupted/nested")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial.appendingPathComponent("a"))
        try fixture.write("keep")
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("link"),
            withDestinationURL: fixture.root
        )
        try await fixture.store.cleanupStaging()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("keep/SKILL.md").path))
    }

    func testSymlinkStagingRootFailsClosed() throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.store.stagingRoot, withDestinationURL: fixture.root)
        let draft = try SkillDraft.parse(Data(draftJSON().utf8))
        XCTAssertThrowsError(try SkillDraftIO.write(draft, root: fixture.root, staging: fixture.store.stagingRoot))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }
}
