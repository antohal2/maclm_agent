import AppKit
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class PetBubbleNativeTests: XCTestCase {
    func testFieldFocusNativeDispatchEscapeAndSendReleaseKey() throws {
        let panel = PetBubblePanel(
            contentRect: CGRect(x: 300, y: 300, width: 280, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 100))
        let field = PetQuickField(frame: CGRect(x: 10, y: 10, width: 250, height: 24))
        content.addSubview(field)
        panel.contentView = content
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        let previousApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try mouse(.leftMouseDown, point: CGPoint(x: 30, y: 20), panel: panel)
        try mouse(.leftMouseUp, point: CGPoint(x: 30, y: 20), panel: panel)
        XCTAssertTrue(panel.inputFocused)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousApplication)
        var sends = 0
        field.onSubmit = { false }
        try key(36, characters: "\r", panel: panel)
        XCTAssertTrue(panel.isKeyWindow)
        field.onSubmit = { sends += 1; return true }
        try key(36, characters: "\r", panel: panel)
        XCTAssertEqual(sends, 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        try mouse(.leftMouseDown, point: CGPoint(x: 30, y: 20), panel: panel)
        try mouse(.leftMouseUp, point: CGPoint(x: 30, y: 20), panel: panel)
        var dismissed = false
        panel.onDismiss = { dismissed = true; panel.finishInput(); panel.orderOut(nil) }
        try key(53, characters: "\u{1b}", panel: panel)
        XCTAssertTrue(dismissed)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testPetNativeClickToggleAndThresholdAndHide() async throws {
        let suite = "bubble-native-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.petEnabled = true
        let container = try ModelContainer(
            for: Conversation.self, Project.self, Message.self, ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let controller = PetController(
            settings: settings, viewModel: ChatViewModel(modelContext: container.mainContext),
            sceneActions: SceneActions(), defaults: defaults
        )
        let pet = try XCTUnwrap(NSApp.windows.first { $0 is PetPanel && !previous.contains($0.windowNumber) })
        defer { controller.closeBubble(); pet.orderOut(nil) }
        try click(pet)
        XCTAssertTrue(controller.bubble.isVisible)
        XCTAssertFalse(controller.bubble.isKeyWindow)
        XCTAssertFalse(pet.isKeyWindow)
        try click(pet)
        XCTAssertFalse(controller.bubble.isVisible)
        try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 20), panel: pet)
        try mouse(.leftMouseDragged, point: CGPoint(x: 23, y: 20), panel: pet)
        try mouse(.leftMouseUp, point: CGPoint(x: 23, y: 20), panel: pet)
        XCTAssertFalse(controller.bubble.isVisible)
        try click(pet)
        XCTAssertTrue(controller.bubble.isVisible)
        settings.petEnabled = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(controller.bubble.isVisible)
    }

    private func click(_ panel: NSWindow) throws {
        try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 20), panel: panel)
        try mouse(.leftMouseUp, point: CGPoint(x: 20, y: 20), panel: panel)
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, panel: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        if type == .leftMouseDown, panel is PetBubblePanel {
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: event.timestamp,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            ))
            NSApp.postEvent(up, atStart: true)
        }
        if type == .leftMouseUp, panel is PetBubblePanel {
            return
        }
        panel.sendEvent(event)
    }

    private func key(_ code: UInt16, characters: String, panel: NSWindow) throws {
        try panel.sendEvent(XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )))
    }
}
