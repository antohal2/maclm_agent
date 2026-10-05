import CoreGraphics
import Foundation

@MainActor
protocol PasteService: AnyObject {
    func paste() throws
}

enum PasteError: Error, Equatable, LocalizedError {
    case accessibilityDenied
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            String(localized: "Нет доступа к Универсальному доступу.")
        case .eventCreationFailed:
            String(localized: "Не удалось создать событие вставки.")
        }
    }
}

@MainActor
protocol PasteEventPosting: AnyObject {
    func postCommandV() throws
}

@MainActor
final class SystemPasteService: PasteService {
    /// Gives the reactivated target application time to accept keyboard input.
    private static let focusSettlingDelay: TimeInterval = 0.1

    private let accessibilityPermissionService: any AccessibilityPermissionService
    private let eventPoster: any PasteEventPosting

    init(
        accessibilityPermissionService: any AccessibilityPermissionService,
        eventPoster: any PasteEventPosting = SystemPasteEventPoster()
    ) {
        self.accessibilityPermissionService = accessibilityPermissionService
        self.eventPoster = eventPoster
    }

    func paste() throws {
        guard accessibilityPermissionService.isTrusted else {
            throw PasteError.accessibilityDenied
        }

        Thread.sleep(forTimeInterval: Self.focusSettlingDelay)
        try eventPoster.postCommandV()
    }
}

@MainActor
final class SystemPasteEventPoster: PasteEventPosting {
    private static let vKeyCode: CGKeyCode = 9

    func postCommandV() throws {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.vKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.vKeyCode,
                keyDown: false
            )
        else {
            throw PasteError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
