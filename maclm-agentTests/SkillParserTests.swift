import Foundation
@testable import maclm_agent
import XCTest

final class SkillParserTests: XCTestCase {
    private func parse(_ text: String, folder: String = "sample") throws -> ParsedSkill {
        try SkillParser.parse(Data(text.utf8), folderName: folder)
    }

    private func rejected(_ text: String, _ expected: SkillValidationError, folder: String = "sample") {
        XCTAssertThrowsError(try parse(text, folder: folder)) { XCTAssertEqual($0 as? SkillValidationError, expected) }
    }

    func testValidAndBody() throws {
        let parsed = try parse("---\nname: sample\ndescription: When checking logs\n---\nInstructions\n")
        XCTAssertEqual(parsed.name, "sample")
        XCTAssertEqual(parsed.description, "When checking logs")
        XCTAssertEqual(parsed.body, "Instructions\n")
    }

    func testMissingFields() {
        rejected("---\ndescription: yes\n---", .missingName)
        rejected("---\nname: sample\n---", .missingDescription)
        rejected("---\nname: sample\ndescription: ''\n---", .missingDescription)
    }

    func testNameRules() throws {
        for name in [
            "Sample",
            "double--hyphen",
            "-leading",
            "trailing-",
            "under_score",
            "имя",
            String(repeating: "a", count: 65),
        ] {
            rejected("---\nname: \(name)\ndescription: yes\n---", .invalidName, folder: name)
        }
        rejected("---\nname: other\ndescription: yes\n---", .nameMismatch)
        XCTAssertEqual(try parse("---\nname: a1-b2\ndescription: yes\n---", folder: "a1-b2").name, "a1-b2")
    }

    func testDescriptionLimit() throws {
        let prefix = "---\nname: sample\ndescription: "
        rejected(prefix + String(repeating: "a", count: 1025) + "\n---", .descriptionTooLong)
        XCTAssertEqual(try parse(prefix + String(repeating: "a", count: 1024) + "\n---").description.count, 1024)
    }

    func testFrontmatterSizeUsesOriginalCRLFBytes() {
        let padding = String(repeating: "x", count: 4096)
        rejected("---\nname: sample\ndescription: yes\nmetadata: \(padding)\n---", .frontmatterTooLarge)
        let comments = String(repeating: "#x\r\n", count: 1100)
        rejected("---\r\nname: sample\r\ndescription: yes\r\n" + comments + "---", .frontmatterTooLarge)
    }

    func testUnknownKeysNeverGrantPermissions() throws {
        let text = "---\nallowed-tools: [run_shell]\nmetadata:\n  hooks: malicious\n"
            + "name: sample\ndescription: yes\n---\nBody"
        let parsed = try parse(text)
        XCTAssertEqual(parsed.description, "yes")
        XCTAssertEqual(parsed.body, "Body")
    }

    func testQuotedScalars() throws {
        let parsed = try parse("---\nname: \"sample\"\ndescription: 'It''s a log review'\n---")
        XCTAssertEqual(parsed.description, "It's a log review")
        XCTAssertEqual(
            try parse("---\nname: sample\ndescription: \"Log \\\"review\\\"\"\n---").description,
            "Log \"review\""
        )
    }

    func testBlockScalars() throws {
        XCTAssertEqual(
            try parse("---\nname: sample\ndescription: >\n  Review logs\n  for errors\n---").description,
            "Review logs for errors"
        )
        XCTAssertEqual(
            try parse("---\nname: sample\ndescription: |\n  Review logs\n  for errors\n---").description,
            "Review logs\nfor errors"
        )
    }

    func testCRLFAndBOM() throws {
        let parsed = try parse("\u{FEFF}---\r\nname: sample\r\ndescription: yes\r\n---\r\nBody")
        XCTAssertEqual(parsed.body, "Body")
    }

    func testMalformedAndDuplicateFields() {
        rejected("Body", .missingFrontmatter)
        rejected("---\nname: sample", .malformedFrontmatter)
        rejected("---\nname: sample\nname: sample\ndescription: yes\n---", .malformedFrontmatter)
        rejected("---\nname: sample\ndescription: \"unclosed\n---", .malformedFrontmatter)
        rejected("---\nname: sample\ndescription: *alias\n---", .malformedFrontmatter)
        rejected("---\nname: sample\ndescription: first\n  second\n---", .malformedFrontmatter)
    }

    func testCatalogTruncationUsesCharacters() {
        let description = String(repeating: "ж", count: 251)
        let snapshot = SkillSnapshot(id: "sample", description: description)
        XCTAssertEqual(snapshot.catalogDescription, String(repeating: "ж", count: 250) + "…")
        XCTAssertEqual(SkillSnapshot(id: "sample", description: "short").catalogDescription, "short")
    }
}
