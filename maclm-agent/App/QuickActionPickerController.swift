import AppKit
import Carbon
import SwiftData
import SwiftUI

private final class QuickActionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class QuickActionPickerController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 420
    private static let rowHeight: CGFloat = 46

    private let panel: QuickActionPanel
    private let model = QuickActionPickerModel()
    private let modelContext: ModelContext
    private let clipboardActionRunner: ClipboardActionRunner
    private let clipboard: any ClipboardAccess
    private var keyboardMonitor: Any?
    private var isClosing = false

    init(
        modelContainer: ModelContainer,
        clipboardActionRunner: ClipboardActionRunner,
        clipboard: any ClipboardAccess = SystemClipboard()
    ) {
        modelContext = modelContainer.mainContext
        self.clipboardActionRunner = clipboardActionRunner
        self.clipboard = clipboard
        panel = QuickActionPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: QuickActionPickerView(
                model: model,
                onSelect: { [weak self] action in
                    self?.perform(action)
                },
                onCancel: { [weak self] in
                    self?.close()
                }
            )
        )
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func close() {
        guard panel.isVisible, !isClosing else {
            removeKeyboardMonitor()
            return
        }
        isClosing = true
        removeKeyboardMonitor()
        panel.orderOut(nil)
        isClosing = false
    }

    func windowDidResignKey(_: Notification) {
        close()
    }

    private func show() {
        clipboardActionRunner.captureTargetApplication()
        let clipboardText = try? clipboard.readString()
        let descriptor = FetchDescriptor<ClipboardAction>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let actions = (try? modelContext.fetch(descriptor)) ?? []
        model.present(clipboardText: clipboardText, actions: actions)

        let rowCount = min(max(model.filteredActions.count, 1), 9)
        let height = model.isClipboardEmpty
            ? CGFloat(150)
            : CGFloat(112) + CGFloat(rowCount) * Self.rowHeight
        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
        centerPanelOnPointerScreen()
        installKeyboardMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    private func centerPanelOnPointerScreen() {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointerLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags.rawValue
            let characters = event.charactersIgnoringModifiers
            let wasHandled = MainActor.assumeIsolated {
                self?.handleKeyDown(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    characters: characters
                ) ?? false
            }
            return wasHandled ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    private func handleKeyDown(
        keyCode: UInt16,
        modifierFlags: UInt,
        characters: String?
    ) -> Bool {
        guard panel.isKeyWindow else {
            return false
        }

        switch Int(keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_UpArrow:
            model.moveSelection(.previous)
            return true
        case kVK_DownArrow:
            model.moveSelection(.next)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let action = model.selectedAction {
                perform(action)
            }
            return true
        default:
            break
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let eventModifiers = NSEvent.ModifierFlags(rawValue: modifierFlags)
        guard
            model.query.isEmpty,
            eventModifiers.isDisjoint(with: disallowedModifiers),
            let character = characters,
            let digit = Int(character),
            let action = model.action(forDigit: digit)
        else {
            return false
        }
        perform(action)
        return true
    }

    private func perform(_ action: ClipboardAction) {
        close()
        clipboardActionRunner.run(action: action)
    }
}
