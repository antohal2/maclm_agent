import Darwin
import Foundation
@testable import maclm_agent
import XCTest

final class SkillScannerTests: XCTestCase {
    private func withSkill(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("---\nname: sample\ndescription: yes\n---\nBody".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        try operation(skill)
    }

    func testValidAndBinaryFiles() throws {
        try withSkill { folder in
            try Data([0, 255, 128]).write(to: folder.appendingPathComponent("asset.bin"))
            let scan = SkillScanner.scanSkill(at: folder)
            XCTAssertNil(scan.problem)
            XCTAssertEqual(scan.state, .disabled)
            XCTAssertEqual(scan.files.count, 2)
            XCTAssertNotNil(scan.hash)
        }
    }

    func testSymlinksIncludingFolderAndDanglingLinksAreInvalid() throws {
        try withSkill { folder in
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .symlink)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .symlink)
            let folderLink = folder.deletingLastPathComponent().appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
            XCTAssertEqual(SkillScanner.scanSkill(at: folderLink).problem, .symlink)
        }
    }

    func testCountLimitIncludesHiddenFiles() throws {
        try withSkill { folder in
            for index in 0 ..< 199 {
                try Data().write(to: folder.appendingPathComponent(".file-\(index)"))
            }
            XCTAssertNil(SkillScanner.scanSkill(at: folder).problem)
            try Data().write(to: folder.appendingPathComponent("one-too-many"))
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .tooManyFiles)
        }
    }

    func testTotalSizeLimit() throws {
        try withSkill { folder in
            try Data(repeating: 0, count: 5 * 1024 * 1024).write(to: folder.appendingPathComponent("large.bin"))
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .folderTooLarge)
        }
    }

    func testInstructionSizeAndWarningBoundaries() throws {
        try withSkill { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            let prefix = "---\nname: sample\ndescription: yes\n---\n"
            for size in [8191, 8192, 16384, 16385] {
                try Data((prefix + String(repeating: "a", count: size - prefix.utf8.count)).utf8).write(to: file)
                let scan = SkillScanner.scanSkill(at: folder)
                XCTAssertEqual(scan.problem, size > 16384 ? .instructionsTooLarge : nil)
                XCTAssertEqual(scan.largeInstructionWarning, size >= 8192 && size <= 16384)
            }
        }
    }

    func testInvalidUTF8AndMissingSkillFile() throws {
        try withSkill { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            try Data([255, 254]).write(to: file)
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .invalidUTF8)
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .missingInstructions)
        }
    }

    func testHashChangesOnEditRenameAdditionRemoval() throws {
        try withSkill { folder in
            let first = try XCTUnwrap(SkillScanner.scanSkill(at: folder).hash)
            let file = folder.appendingPathComponent("extra")
            try Data("one".utf8).write(to: file)
            let added = try XCTUnwrap(SkillScanner.scanSkill(at: folder).hash)
            XCTAssertNotEqual(first, added)
            XCTAssertEqual(added, SkillScanner.scanSkill(at: folder).hash)
            try Data("two".utf8).write(to: file)
            let edited = try XCTUnwrap(SkillScanner.scanSkill(at: folder).hash)
            XCTAssertNotEqual(added, edited)
            let renamed = folder.appendingPathComponent("renamed")
            try FileManager.default.moveItem(at: file, to: renamed)
            XCTAssertNotEqual(edited, SkillScanner.scanSkill(at: folder).hash)
            try FileManager.default.removeItem(at: renamed)
            XCTAssertEqual(first, SkillScanner.scanSkill(at: folder).hash)
        }
    }

    func testHasherEnumerationOrderAndUnambiguousManifest() {
        let files = [SkillFile(path: "a", size: 1, digest: "abc"), SkillFile(path: "b\nx", size: 2, digest: "def")]
        XCTAssertEqual(SkillHasher.manifestHash(files), SkillHasher.manifestHash(files.reversed()))
        XCTAssertEqual(SkillHasher.digest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNotEqual(
            SkillHasher.manifestHash(files),
            SkillHasher.manifestHash([SkillFile(path: "ab\nx", size: 3, digest: "abc")])
        )
    }

    func testNestedFilesAndSpecialFiles() throws {
        try withSkill { folder in
            let directory = folder.appendingPathComponent("references")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.md"))
            XCTAssertTrue(SkillScanner.scanSkill(at: folder).files.contains { $0.path == "references/notes.md" })
            let fifo = folder.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertEqual(SkillScanner.scanSkill(at: folder).problem, .unsupportedFile)
        }
    }

    func testSymlinkIntroducedBetweenEnumerationAndReadIsRejected() throws {
        try withSkill { folder in
            let descriptor = try SkillFileIO.directory(folder.path)
            defer { close(descriptor) }
            let outside = folder.deletingLastPathComponent().appendingPathComponent("outside")
            try Data("secret".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("new-link"),
                withDestinationURL: outside
            )
            XCTAssertThrowsError(try SkillFileIO.readFile(SkillFile(path: "new-link", size: 6), root: descriptor))
            let directory = folder.appendingPathComponent("references")
            try FileManager.default.createSymbolicLink(
                at: directory,
                withDestinationURL: folder.deletingLastPathComponent()
            )
            XCTAssertThrowsError(try SkillFileIO.readFile(
                SkillFile(path: "references/outside", size: 6),
                root: descriptor
            ))
        }
    }
}
