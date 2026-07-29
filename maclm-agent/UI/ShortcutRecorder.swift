import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let onShortcut: (GlobalShortcut) -> Void

    func makeNSView(context _: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onShortcut = onShortcut
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context _: Context) {
        button.onShortcut = onShortcut
        if !button.isRecording {
            button.shortcut = shortcut
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((GlobalShortcut) -> Void)?
    var shortcut = GlobalShortcut.defaultShortcut {
        didSet {
            if !isRecording {
                title = shortcut.displayName
            }
        }
    }

    fileprivate private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = shortcut.displayName
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        isRecording = true
        title = "Нажмите сочетание…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = shortcut.displayName
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        guard isRecording else {
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard
            modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
        else {
            NSSound.beep()
            return
        }

        let newShortcut = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
        shortcut = newShortcut
        isRecording = false
        window?.makeFirstResponder(nil)
        onShortcut?(newShortcut)
    }
}

private extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }
}
