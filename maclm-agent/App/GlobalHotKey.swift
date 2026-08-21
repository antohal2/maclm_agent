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

    static let defaultShortcut = Self(
        keyCode: UInt32(kVK_Space),
        modifiers: [.control, .shift]
    )

    static let defaultClipboardActionShortcut = Self(
        keyCode: UInt32(kVK_Space),
        modifiers: [.command, .shift]
    )

    var displayName: String {
        var result = ""
        if modifiers.contains(.command) {
            result += "⌘"
        }
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
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
    case conflictsWithOtherShortcut

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            "Комбинация занята, выберите другую (код \(status))."
        case .conflictsWithOtherShortcut:
            "Комбинация уже назначена другому хоткею приложения."
        }
    }
}

enum HotKeyConflictValidator {
    static func validate(
        candidate: GlobalShortcut,
        conflictingWith otherShortcut: GlobalShortcut
    ) throws {
        guard candidate != otherShortcut else {
            throw GlobalHotKeyError.conflictsWithOtherShortcut
        }
    }
}

private final class CarbonResources: @unchecked Sendable {
    var eventHandlerReference: EventHandlerRef?
    var hotKeyReferences: [UInt32: EventHotKeyRef] = [:]

    deinit {
        for reference in hotKeyReferences.values {
            UnregisterEventHotKey(reference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }
}

private let carbonHotKeySignature = OSType(0x4D4C_4D41)
private let carbonHotKeyNotification = Notification.Name("maclm-agent.carbon-hotkey")

@MainActor
final class CarbonHotKeyRegistry: NSObject {
    static let shared = CarbonHotKeyRegistry()

    private let resources = CarbonResources()
    private var actions: [UInt32: () -> Void] = [:]

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeyPressed),
            name: carbonHotKeyNotification,
            object: nil
        )
        installEventHandler()
    }

    func register(
        identifier: UInt32,
        shortcut: GlobalShortcut,
        action: @escaping () -> Void
    ) throws {
        unregister(identifier: identifier)

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: carbonHotKeySignature,
            id: identifier
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
        resources.hotKeyReferences[identifier] = reference
        actions[identifier] = action
    }

    func unregister(identifier: UInt32) {
        if let reference = resources.hotKeyReferences.removeValue(forKey: identifier) {
            UnregisterEventHotKey(reference)
        }
        actions.removeValue(forKey: identifier)
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == carbonHotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            NotificationCenter.default.post(
                name: carbonHotKeyNotification,
                object: nil,
                userInfo: ["identifier": hotKeyID.id]
            )
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &resources.eventHandlerReference
        )
    }

    @objc
    private func hotKeyPressed(_ notification: Notification) {
        guard let identifier = notification.userInfo?["identifier"] as? UInt32 else {
            return
        }
        actions[identifier]?()
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

@MainActor
@Observable
final class GlobalHotKeyController {
    private static let identifier: UInt32 = 1

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
        conflictingWith otherShortcut: GlobalShortcut? = nil
    ) -> Bool {
        do {
            if let otherShortcut {
                try HotKeyConflictValidator.validate(
                    candidate: shortcut,
                    conflictingWith: otherShortcut
                )
            }
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
