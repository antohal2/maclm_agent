import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHotkeyService {
    private static let identifier: UInt32 = 2

    private(set) var registrationError: String?
    var action: (() -> Void)?

    @ObservationIgnored
    private let registry: CarbonHotKeyRegistry
    @ObservationIgnored
    private var registeredShortcut: GlobalShortcut?

    init(registry: CarbonHotKeyRegistry = .shared) {
        self.registry = registry
    }

    func start(with shortcut: GlobalShortcut) {
        do {
            try register(shortcut)
            registrationError = nil
        } catch {
            registrationError = error.localizedDescription
        }
    }

    @discardableResult
    func update(
        to shortcut: GlobalShortcut,
        conflictingWith otherShortcut: GlobalShortcut
    ) -> Bool {
        do {
            try HotKeyConflictValidator.validate(
                candidate: shortcut,
                conflictingWith: otherShortcut
            )
        } catch {
            registrationError = error.localizedDescription
            return false
        }

        let previousShortcut = registeredShortcut
        unregister()

        do {
            try register(shortcut)
            registrationError = nil
            return true
        } catch {
            registrationError = error.localizedDescription
            if let previousShortcut {
                try? register(previousShortcut)
            }
            return false
        }
    }

    func stop() {
        unregister()
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        try registry.register(
            identifier: Self.identifier,
            shortcut: shortcut
        ) { [weak self] in
            self?.action?()
        }
        registeredShortcut = shortcut
    }

    private func unregister() {
        registry.unregister(identifier: Self.identifier)
        registeredShortcut = nil
    }
}
