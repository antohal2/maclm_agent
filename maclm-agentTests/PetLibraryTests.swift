import Foundation
@testable import maclm_agent
import XCTest

@MainActor
final class PetLibraryTests: XCTestCase {
    func testBuiltinResourceAndFallback() throws {
        let fixture = try PetStoreFixture()
        defer { fixture.cleanup() }
        let suite = "scout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = PetLibrary(settings: settings, store: fixture.store)
        let sprite = try XCTUnwrap(library.activeSprite())
        XCTAssertEqual(sprite.manifest.id, "scout")
        XCTAssertEqual(sprite.manifest.name, "Скаут")
        XCTAssertEqual(sprite.manifest.version, 1)
        XCTAssertEqual(sprite.manifest.frameSize, 64)
        XCTAssertEqual(sprite.manifest.columns, 8)
        XCTAssertEqual(sprite.manifest.reduceMotionFrame, 0)
        XCTAssertEqual(sprite.manifest.rows.count, 8)
        let states: [PetState] = [.idle, .running, .toolRunning, .needsApproval, .ready, .failed, .drag, .sleep]
        let counts = [6, 8, 8, 6, 6, 6, 4, 4]
        let rates = [6, 10, 10, 8, 8, 8, 8, 3]
        for (index, row) in sprite.manifest.rows.enumerated() {
            XCTAssertEqual(row.row, index)
            XCTAssertEqual(row.state, states[index])
            XCTAssertEqual(row.frames, counts[index])
            XCTAssertEqual(row.fps, rates[index])
            XCTAssertTrue(row.loop)
            XCTAssertEqual(sprite.frames[row.state]?.count, counts[index])
        }
        // The unchanged production loader rejects any sheet other than 512 × 512 here.
        var messages: [String] = []
        let valid = PetLibrary(settings: settings, store: fixture.store, builtinLoader: { sprite }, log: { messages.append($0) })
        XCTAssertNotNil(valid.activeSprite())
        XCTAssertTrue(messages.isEmpty)
        let corrupt = PetLibrary(settings: settings, store: fixture.store, builtinLoader: {
            try PetLoader.load(manifestData: Data("{".utf8), imageData: Data())
        }, log: { messages.append($0) })
        XCTAssertNil(corrupt.activeSprite())
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("manifestJSON"))
        var reloaded: PetSprite? = sprite
        corrupt.onReload = { reloaded = $0 }
        corrupt.select("scout")
        XCTAssertNil(reloaded)
        valid.onReload = { reloaded = $0 }
        valid.select("scout")
        XCTAssertNotNil(reloaded)
    }

    func testSelectedPetMigrationPreservesOtherIDs() throws {
        let suite = "scout-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (stored, expected) in [("bronya", "scout"), ("test-pet", "test-pet"), ("missing", "missing")] {
            defaults.set(stored, forKey: "pet.selectedID")
            XCTAssertEqual(AppSettings(defaults: defaults).petSelectedID, expected)
            XCTAssertEqual(defaults.string(forKey: "pet.selectedID"), expected)
        }
        defaults.removeObject(forKey: "pet.selectedID")
        XCTAssertEqual(AppSettings(defaults: defaults).petSelectedID, "scout")
    }

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
        XCTAssertEqual(settings.petSelectedID, "scout")
        XCTAssertFalse(try XCTUnwrap(library.entries.first).selectable)
        XCTAssertNotNil(library.entries.first?.problem)
        settings.petSelectedID = "test-pet"
        let restarted = PetLibrary(settings: settings, store: fixture.store)
        XCTAssertNotNil(restarted.activeSprite())
        XCTAssertEqual(settings.petSelectedID, "scout")
        XCTAssertEqual(defaults.string(forKey: "pet.selectedID"), "scout")
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
        XCTAssertEqual(settings.petSelectedID, "scout")
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
        XCTAssertNotNil(library.activeSprite())
        XCTAssertEqual(settings.petSelectedID, "scout")
        library.select("../outside")
        XCTAssertEqual(settings.petSelectedID, "scout")
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
