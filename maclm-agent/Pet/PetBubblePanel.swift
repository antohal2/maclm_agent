import AppKit

final class PetBubblePanel: NSPanel {
    var inputFocused = false
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool {
        inputFocused
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_: Any?) {
        onDismiss?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, isKeyWindow {
            onDismiss?()
            return
        }
        super.sendEvent(event)
    }

    func finishInput() {
        inputFocused = false
        makeFirstResponder(nil)
        if isKeyWindow {
            resignKey()
        }
    }
}

enum PetBubblePosition {
    static func frame(pet: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        guard !screen.isEmpty, screen.origin.x.isFinite, screen.origin.y.isFinite,
              screen.width.isFinite, screen.height.isFinite else { return .zero }
        let width = min(size.width.isFinite ? max(0, size.width) : 280, screen.width)
        let height = min(size.height.isFinite ? max(0, size.height) : 180, screen.height)
        let anchor = pet.origin.x.isFinite && pet.origin.y.isFinite ? pet : screen
        let right = screen.maxX - anchor.maxX
        let left = anchor.minX - screen.minX
        let originX = right >= width + 8 || right >= left ? anchor.maxX + 8 : anchor.minX - width - 8
        return CGRect(
            x: min(max(originX, screen.minX), screen.maxX - width),
            y: min(max(anchor.minY, screen.minY), screen.maxY - height),
            width: width, height: height
        )
    }
}
