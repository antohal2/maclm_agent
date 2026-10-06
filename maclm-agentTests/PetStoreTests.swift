import Darwin
import Foundation
@testable import maclm_agent
import XCTest

final class PetStoreTests: XCTestCase {
    func testImportOnlyValidatedBytesAndTwoFiles() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try Data("ignored".utf8).write(to: fixture.source.appendingPathComponent("extra.sh"))
        let imported = try fixture.store.prepare(source: fixture.source)
        try fixture.write(name: "Changed after validation")
        try fixture.store.install(imported)
        XCTAssertEqual(try fixture.store.load("test-pet").manifest.name, "Test")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.store.root.appendingPathComponent("test-pet").path
        ).sorted(), ["pet.json", "spritesheet.png"])
        XCTAssertEqual(try fixture.contents(), ["test-pet"])
    }

    func testDuplicateRequiresConfirmationThenReplaces() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try fixture.store.install(fixture.store.prepare(source: fixture.source))
        try fixture.write(name: "Replacement")
        let imported = try fixture.store.prepare(source: fixture.source)
        XCTAssertEqual(try fixture.store.existingID(for: "test-pet"), "test-pet")
        XCTAssertThrowsError(try fixture.store.install(imported)) {
            XCTAssertEqual($0 as? PetStorageError, .replacementRequired)
        }
        try fixture.store.install(imported, replacing: true)
        XCTAssertEqual(try fixture.store.load("test-pet").manifest.name, "Replacement")
        XCTAssertEqual(try fixture.contents(), ["test-pet"])
    }

    func testSymlinksAndNonRegularFilesRejected() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        for name in ["pet.json", "spritesheet.png"] {
            let file = fixture.source.appendingPathComponent(name)
            let original = fixture.root.appendingPathComponent("original")
            try FileManager.default.moveItem(at: file, to: original)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
            XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: original, to: file)
        }
    }

    func testIdentifiersAndInvalidContentsRejected() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        for id in ["bronya", "Bronya", "..", "a/b", "a\\b", "a\n", " pet", "a..b", "a\u{00}"] {
            try fixture.write(id: id)
            XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source), id)
            XCTAssertThrowsError(try fixture.store.delete(id), id)
        }
        try Data("{".utf8).write(to: fixture.source.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
        try fixture.write()
        try Data("bad image".utf8).write(to: fixture.source.appendingPathComponent("spritesheet.png"))
        XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
    }

    func testOversizedFilesRejected() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        for (name, size) in [("pet.json", 64 * 1024 + 1), ("spritesheet.png", 8 * 1024 * 1024 + 1)] {
            try fixture.write()
            try Data(repeating: 0, count: size).write(to: fixture.source.appendingPathComponent(name))
            XCTAssertThrowsError(try fixture.store.prepare(source: fixture.source))
        }
    }

    func testReadUsesSameDescriptorAfterPathSubstitution() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let directory = try PetFileAccess.directory(fixture.source)
        defer { close(directory) }
        let file = fixture.source.appendingPathComponent("pet.json")
        let expected = try Data(contentsOf: file)
        let result = try PetFileAccess.read(
            "pet.json", parent: directory, limit: 64 * 1024, oversized: .manifestSize
        ) { _ in
            try FileManager.default.moveItem(at: file, to: fixture.source.appendingPathComponent("saved.json"))
            try FileManager.default.createSymbolicLink(
                at: file, withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
            )
        }
        XCTAssertEqual(result, expected)
    }

    func testGrowthAfterFstatStillBounded() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let directory = try PetFileAccess.directory(fixture.source)
        defer { close(directory) }
        XCTAssertThrowsError(try PetFileAccess.read(
            "pet.json", parent: directory, limit: 64 * 1024, oversized: .manifestSize
        ) { _ in
            let handle = try FileHandle(forWritingTo: fixture.source.appendingPathComponent("pet.json"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 32, count: 64 * 1024))
        }) { XCTAssertEqual($0 as? PetValidationError, .manifestSize) }
    }

    func testRevalidationFailurePreservesOldAndCleansNew() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let imported = try fixture.store.prepare(source: fixture.source)
        for replacing in [false, true] {
            if replacing {
                try fixture.store.install(imported)
            }
            XCTAssertThrowsError(try fixture.store.install(imported, replacing: replacing) { staging in
                try Data("bad".utf8).write(to: staging.appendingPathComponent("pet.json"))
            })
            XCTAssertEqual(try fixture.contents(), replacing ? ["test-pet"] : [])
            if replacing {
                XCTAssertEqual(try fixture.store.load("test-pet").manifest.name, "Test")
            }
        }
    }

    func testInjectedFilesystemFailureCleansStagingAndPreservesOld() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let imported = try fixture.store.prepare(source: fixture.source)
        try fixture.store.install(imported)
        XCTAssertThrowsError(try fixture.store.install(imported, replacing: true) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try fixture.contents(), ["test-pet"])
        XCTAssertEqual(try fixture.store.load("test-pet").manifest.name, "Test")
    }

    func testDeleteDirectoryWithHiddenAndLinkedChildrenPreservesTargets() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try fixture.store.install(fixture.store.prepare(source: fixture.source))
        let installed = fixture.store.root.appendingPathComponent("test-pet")
        try Data("hidden".utf8).write(to: installed.appendingPathComponent(".extra"))
        try FileManager.default.createSymbolicLink(
            at: installed.appendingPathComponent("linked"), withDestinationURL: fixture.source
        )
        try fixture.store.delete("test-pet")
        XCTAssertEqual(try fixture.contents(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("pet.json").path))
    }

    func testStorageRootSymlinkRejectedWithoutWritingTarget() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(at: fixture.store.root, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try fixture.store.install(fixture.store.prepare(source: fixture.source)))
        XCTAssertThrowsError(try fixture.store.delete("test-pet"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).sorted(),
            ["pet.json", "spritesheet.png"]
        )
    }

    func testLimitCountsBrokenDirectoriesAndAllowsReplacement() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let imported = try fixture.store.prepare(source: fixture.source)
        try fixture.store.install(imported)
        for index in 0 ..< 49 {
            try FileManager.default.createDirectory(
                at: fixture.store.root.appendingPathComponent("broken-\(index)"), withIntermediateDirectories: false
            )
        }
        try fixture.write(id: "another")
        XCTAssertThrowsError(try fixture.store.install(fixture.store.prepare(source: fixture.source))) {
            XCTAssertEqual($0 as? PetStorageError, .limit)
        }
        XCTAssertNoThrow(try fixture.store.install(imported, replacing: true))
        XCTAssertEqual(try fixture.contents().count, 50)
    }

    func testListAndDeleteDoNotFollowDirectoryLinks() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.store.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.store.root.appendingPathComponent("linked"), withDestinationURL: fixture.source
        )
        try Data().write(to: fixture.store.root.appendingPathComponent("file"))
        try FileManager.default.createDirectory(
            at: fixture.store.root.appendingPathComponent(".hidden"), withIntermediateDirectories: false
        )
        let entry = try XCTUnwrap(fixture.store.entries().first)
        XCTAssertEqual(entry.id, "linked")
        XCTAssertFalse(entry.selectable)
        XCTAssertNotNil(entry.problem)
        try fixture.store.delete("linked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("pet.json").path))
    }

    func testCaseInsensitiveCollisionCannotInstallSecondDirectory() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.store.root.appendingPathComponent("TEST-PET"), withIntermediateDirectories: true
        )
        XCTAssertEqual(try fixture.store.existingID(for: "test-pet"), "TEST-PET")
        XCTAssertThrowsError(try fixture.store.install(fixture.store.prepare(source: fixture.source))) {
            XCTAssertEqual($0 as? PetStorageError, .replacementRequired)
        }
        XCTAssertEqual(try fixture.contents(), ["TEST-PET"])
    }
}
