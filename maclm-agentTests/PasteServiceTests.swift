@testable import maclm_agent
import XCTest

final class PasteServiceTests: XCTestCase {
    @MainActor
    func testDeniedAccessibilityThrowsWithoutPostingEvent() {
        let permissionService = PastePermissionStub(trusted: false)
        let eventPoster = PasteEventPosterStub()
        let pasteService = SystemPasteService(
            accessibilityPermissionService: permissionService,
            eventPoster: eventPoster
        )

        XCTAssertThrowsError(try pasteService.paste()) { error in
            XCTAssertEqual(error as? PasteError, .accessibilityDenied)
        }
        XCTAssertEqual(eventPoster.callCount, 0)
    }
}

@MainActor
private final class PastePermissionStub: AccessibilityPermissionService {
    let isTrusted: Bool

    init(trusted: Bool) {
        isTrusted = trusted
    }

    func requestAccess() {}
    func openSystemSettings() {}
}

@MainActor
private final class PasteEventPosterStub: PasteEventPosting {
    private(set) var callCount = 0

    func postCommandV() throws {
        callCount += 1
    }
}
