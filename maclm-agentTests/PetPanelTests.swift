import AppKit
@testable import maclm_agent
import SwiftData
import XCTest

final class PetPanelTests: XCTestCase {
    @MainActor func testControllerVisibilityScaleResetAndNonactivation() async throws {
        let suite = "pet-panel-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999_999, forKey: "pet.x")
        defaults.set(999_999, forKey: "pet.y")
        let settings = AppSettings(defaults: defaults)
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = ChatViewModel(modelContext: container.mainContext)
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let actions = SceneActions()
        var opened = false
        actions.openMainWindowAction = { opened = true }
        let controller = PetController(
            settings: settings,
            viewModel: model,
            sceneActions: actions,
            defaults: defaults
        )
        defer { controller.closeBubble() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is PetPanel && !previous.contains($0.windowNumber) })
        defer { panel.orderOut(nil) }
        XCTAssertFalse(panel.isVisible)
        settings.petEnabled = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(panel.isVisible)
        checkPanelConfiguration(panel)
        settings.petScale = 3
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(panel.frame.size, CGSize(width: 192, height: 192))
        settings.resetPetPosition?()
        XCTAssertEqual(defaults.double(forKey: "pet.x"), panel.frame.origin.x)
        XCTAssertEqual(defaults.double(forKey: "pet.y"), panel.frame.origin.y)
        checkReadyClick(panel, model: model)
        XCTAssertFalse(opened)
        XCTAssertTrue(controller.bubble.isVisible)
        settings.petEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible)
        settings.petScale = 0
        XCTAssertEqual(settings.petScale, 1)
        settings.petScale = 8
        XCTAssertEqual(settings.petScale, 3)
        withExtendedLifetime(controller) {}
    }

    @MainActor private func checkReadyClick(_ panel: NSWindow, model: ChatViewModel) {
        let ready = model.createConversation()
        let idle = model.createConversation()
        ready.hasUnreadResult = true
        XCTAssertEqual(model.selectedConversationID, idle.id)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                panel.sendEvent(event)
            }
        }
        XCTAssertEqual(model.selectedConversationID, idle.id)
        XCTAssertTrue(ready.hasUnreadResult)
    }

    @MainActor private func checkPanelConfiguration(_ panel: NSWindow) {
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
    }
}
