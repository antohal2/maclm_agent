import AppKit
@testable import maclm_agent
import SwiftUI
import XCTest

@MainActor
final class PetNativeEventTests: XCTestCase {
    func testNativeClickBelowThresholdOpensAndDragDoesNot() throws {
        let panel = PetPanel(
            contentRect: CGRect(x: 300, y: 300, width: 128, height: 128),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let host = PetHostingView(rootView: Color.clear)
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertTrue(host.hitTest(CGPoint(x: 64, y: 64)) === host)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertFalse(host.acceptsFirstResponder)
        let actions = SceneActions()
        var opened = 0
        actions.openMainWindowAction = { opened += 1 }
        panel.onClick = { actions.openMainWindow() }
        let origin = panel.frame.origin
        try send(.leftMouseDown, point: CGPoint(x: 64, y: 64), to: panel)
        try send(.leftMouseDragged, point: CGPoint(x: 66, y: 64), to: panel)
        try send(.leftMouseUp, point: CGPoint(x: 66, y: 64), to: panel)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(panel.frame.origin, origin)
        var dragged = false
        panel.onDrag = { dragged = dragged || $0 }
        try send(.leftMouseDown, point: CGPoint(x: 64, y: 64), to: panel)
        try send(.leftMouseDragged, point: CGPoint(x: 67, y: 64), to: panel)
        try send(.leftMouseUp, point: CGPoint(x: 67, y: 64), to: panel)
        XCTAssertTrue(dragged)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
    }

    private func send(_ type: NSEvent.EventType, point: CGPoint, to panel: PetPanel) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        panel.sendEvent(event)
    }

    func testStateRetentionExplainsOldAppControllerMismatch() async throws {
        let first = PetOwnerToken()
        let second = PetOwnerToken()
        var observedState: PetOwnerToken?
        var observedController: PetOwnerToken?
        let capture: (PetOwnerToken, PetOwnerToken) -> Void = {
            observedState = $0
            observedController = $1
        }
        let host = NSHostingView(rootView: PetOldOwnerProbe(candidate: first, capture: capture))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(observedState === first)
        host.rootView = PetOldOwnerProbe(candidate: second, capture: capture)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(observedState === first)
        XCTAssertTrue(observedController === second)
    }
}

@MainActor private final class PetOwnerToken {
    let id = UUID()
}

/// Reproduces v0.4.8's mix of retained State and separately constructed controller references.
private struct PetOldOwnerProbe: View {
    @State private var stored: PetOwnerToken
    let candidate: PetOwnerToken
    let capture: (PetOwnerToken, PetOwnerToken) -> Void
    init(candidate: PetOwnerToken, capture: @escaping (PetOwnerToken, PetOwnerToken) -> Void) {
        _stored = State(initialValue: candidate)
        self.candidate = candidate
        self.capture = capture
    }

    var body: some View {
        Color.clear.onChange(of: candidate.id, initial: true) { capture(stored, candidate) }
    }
}
