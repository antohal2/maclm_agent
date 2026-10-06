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

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = screenPoint(event)
        panelOrigin = frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = screenPoint(event)
        let delta = CGPoint(x: mouse.x - mouseOrigin.x, y: mouse.y - mouseOrigin.y)
        if !dragging, hypot(delta.x, delta.y) >= 3 {
            dragging = true
            onDrag?(true)
        }
        if dragging {
            setFrameOrigin(CGPoint(x: panelOrigin.x + delta.x, y: panelOrigin.y + delta.y))
        }
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        convertPoint(toScreen: event.locationInWindow)
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

/// Route native events explicitly; a nil hit target drops clicks before NSPanel receives them.
final class PetHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        (window as? PetPanel)?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        (window as? PetPanel)?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        (window as? PetPanel)?.mouseUp(with: event)
    }
}
