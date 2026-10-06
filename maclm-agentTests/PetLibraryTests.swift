import Foundation
@testable import maclm_agent
import XCTest

@MainActor
final class PetLibraryTests: XCTestCase {
    func testActiveCorruptionFallsBackOnStartupAndRefresh() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try fixture.store.install(fixture.store.prepare(source: fixture.source))
        let suite = "pet-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.petSelectedID = "test-pet"
        let library = PetLibrary(settings: settings, store: fixture.store)
        XCTAssertNotNil(library.activeSprite())
        let file = fixture.store.root.appendingPathComponent("test-pet/pet.json")
        try Data("corrupt".utf8).write(to: file)
        library.refresh()
        XCTAssertEqual(settings.petSelectedID, "bronya")
        XCTAssertFalse(try XCTUnwrap(library.entries.first).selectable)
        XCTAssertNotNil(library.entries.first?.problem)
        settings.petSelectedID = "test-pet"
        let restarted = PetLibrary(settings: settings, store: fixture.store)
        XCTAssertNil(restarted.activeSprite())
        XCTAssertEqual(settings.petSelectedID, "bronya")
        XCTAssertEqual(defaults.string(forKey: "pet.selectedID"), "bronya")
    }

    func testSelectionReloadsOnceAndPreservesScaleAndDeletingActiveResets() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        try fixture.store.install(fixture.store.prepare(source: fixture.source))
        let suite = "pet-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.petScale = 3
        defaults.set(123.0, forKey: "pet.x")
        let library = PetLibrary(settings: settings, store: fixture.store)
        var reloads = 0
        library.onReload = { _ in reloads += 1 }
        library.select("test-pet")
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(settings.petScale, 3)
        XCTAssertEqual(defaults.double(forKey: "pet.x"), 123)
        library.delete("test-pet")
        XCTAssertEqual(settings.petSelectedID, "bronya")
        XCTAssertEqual(reloads, 2)
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testMissingActiveAndInvalidSelection() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let suite = "pet-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.petSelectedID = "missing"
        let library = PetLibrary(settings: settings, store: fixture.store)
        XCTAssertNil(library.activeSprite())
        XCTAssertEqual(settings.petSelectedID, "bronya")
        library.select("../outside")
        XCTAssertEqual(settings.petSelectedID, "bronya")
        XCTAssertNotNil(library.errorMessage)
    }

    func testPetsRemainBlockedByMandatoryApplicationRule() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let protected = fixture.root.appendingPathComponent("Library/Application Support/local.test/Pets/pet/pet.json")
        let rules = ApplicationProtection.rules(
            storeURL: fixture.root.appendingPathComponent("store.sqlite"), bundleID: "local.test", home: fixture.root
        )
        let policy = SecurityPolicyEngine(rules: rules)
        for tool: any Tool in [ReadFileTool(), WriteFileTool(), DeleteFileTool()] {
            XCTAssertFalse(policy.decision(for: tool, arguments: ["path": protected.path]).isAllowed)
        }
        XCTAssertTrue(rules.contains { $0.isMandatory && $0.pattern.hasSuffix("local.test/**") })
    }
}
