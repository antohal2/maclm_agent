import AppKit
import SwiftUI

final class PetPanel: NSPanel {
    var onDrag: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onPosition: ((CGPoint) -> Void)?
    private var mouseOrigin = CGPoint.zero
    private var panelOrigin = CGPoint.zero
    private var dragging = false

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func mouseDown(with _: NSEvent) {
        mouseOrigin = NSEvent.mouseLocation
        panelOrigin = frame.origin
        dragging = false
    }

    override func mouseDragged(with _: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - mouseOrigin.x, y: mouse.y - mouseOrigin.y)
        if !dragging, hypot(delta.x, delta.y) >= 3 {
            dragging = true
            onDrag?(true)
        }
        if dragging {
            setFrameOrigin(CGPoint(x: panelOrigin.x + delta.x, y: panelOrigin.y + delta.y))
        }
    }

    override func mouseUp(with _: NSEvent) {
        if dragging {
            onPosition?(frame.origin)
            dragging = false
            onDrag?(false)
        } else {
            onClick?()
        }
    }
}

/// Keep hit testing in the panel so a click cannot focus the hosting view.
final class PetHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
