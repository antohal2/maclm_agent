import Carbon
import Foundation
import Observation

struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
}

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: ShortcutModifiers

    /// Control-Shift-Space avoids the default macOS Spotlight and input-source
    /// shortcuts while remaining reachable with one hand.
    static let defaultShortcut = Self(
        keyCode: UInt32(kVK_Space),
        modifiers: [.control, .shift]
    )

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        return result + keyName
    }

    private var keyName: String {
        switch Int(keyCode) {
        case kVK_Space:
            "Space"
        case kVK_Return:
            "↩"
        case kVK_Tab:
            "⇥"
        case kVK_Delete:
            "⌫"
        case kVK_ForwardDelete:
            "⌦"
        case kVK_Escape:
            "⎋"
        case kVK_LeftArrow:
            "←"
        case kVK_RightArrow:
            "→"
        case kVK_DownArrow:
            "↓"
        case kVK_UpArrow:
            "↑"
        default:
            Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)"
        }
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A",
        kVK_ANSI_B: "B",
        kVK_ANSI_C: "C",
        kVK_ANSI_D: "D",
        kVK_ANSI_E: "E",
        kVK_ANSI_F: "F",
        kVK_ANSI_G: "G",
        kVK_ANSI_H: "H",
        kVK_ANSI_I: "I",
        kVK_ANSI_J: "J",
        kVK_ANSI_K: "K",
        kVK_ANSI_L: "L",
        kVK_ANSI_M: "M",
        kVK_ANSI_N: "N",
        kVK_ANSI_O: "O",
        kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q",
        kVK_ANSI_R: "R",
        kVK_ANSI_S: "S",
        kVK_ANSI_T: "T",
        kVK_ANSI_U: "U",
        kVK_ANSI_V: "V",
        kVK_ANSI_W: "W",
        kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0",
        kVK_ANSI_1: "1",
        kVK_ANSI_2: "2",
        kVK_ANSI_3: "3",
        kVK_ANSI_4: "4",
        kVK_ANSI_5: "5",
        kVK_ANSI_6: "6",
        kVK_ANSI_7: "7",
        kVK_ANSI_8: "8",
        kVK_ANSI_9: "9",
    ]
}

enum GlobalHotKeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            "Не удалось зарегистрировать хоткей (код \(status)). Возможно, сочетание уже занято."
        }
    }
}

private final class CarbonRegistration: @unchecked Sendable {
    var hotKeyReference: EventHotKeyRef?
    var eventHandlerReference: EventHandlerRef?

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }
}

@MainActor
@Observable
final class GlobalHotKeyController {
    private(set) var registrationError: String?
    var action: (() -> Void)?

    @ObservationIgnored
    private let carbonRegistration = CarbonRegistration()
    @ObservationIgnored
    private var registeredShortcut: GlobalShortcut?

    init() {
        installEventHandler()
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
    func update(to shortcut: GlobalShortcut) -> Bool {
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

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let controller = Unmanaged<GlobalHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.action?()
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonRegistration.eventHandlerReference
        )
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4D4C_4D41),
            id: 1
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(for: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw GlobalHotKeyError.registrationFailed(status)
        }
        carbonRegistration.hotKeyReference = reference
        registeredShortcut = shortcut
    }

    private func unregister() {
        if let hotKeyReference = carbonRegistration.hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        carbonRegistration.hotKeyReference = nil
        registeredShortcut = nil
    }

    private func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        return result
    }
}
