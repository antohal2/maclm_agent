import Foundation
@testable import maclm_agent
import XCTest

final class SettingsAndKeychainTests: XCTestCase {
    @MainActor
    func testAppSettingsUsesDefaultsAndPersistsChanges() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(initialSettings.theme, .automatic)
        XCTAssertEqual(initialSettings.shortcut, .defaultShortcut)

        let shortcut = GlobalShortcut(
            keyCode: 0,
            modifiers: [.command, .option]
        )
        initialSettings.theme = .dark
        initialSettings.shortcut = shortcut

        let restoredSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(restoredSettings.theme, .dark)
        XCTAssertEqual(restoredSettings.shortcut, shortcut)
    }

    func testKeychainServiceSaveReadUpdateAndDelete() throws {
        let service = KeychainService(
            service: "local.maclm-agent.tests.\(UUID().uuidString)"
        )
        let key = "secret-\(UUID().uuidString)"
        defer { try? service.delete(key: key) }

        XCTAssertNil(try service.read(key: key))

        try service.save(key: key, value: "first")
        XCTAssertEqual(try service.read(key: key), "first")

        try service.save(key: key, value: "updated")
        XCTAssertEqual(try service.read(key: key), "updated")

        try service.delete(key: key)
        XCTAssertNil(try service.read(key: key))
        XCTAssertNoThrow(try service.delete(key: key))
    }
}
