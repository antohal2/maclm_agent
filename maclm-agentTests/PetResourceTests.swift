import AppKit
import Darwin
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class PetResourceTests: XCTestCase {
    func testIdleCPUWithClosedAndOpenBubble() async throws {
        // The SwiftUI test host may already own a pet from saved preferences.
        // Isolate one visible animator without writing those preferences.
        let otherPets = NSApp.windows.filter { $0 is PetPanel && $0.isVisible }
        otherPets.forEach { $0.orderOut(nil) }
        defer { otherPets.forEach { $0.orderFrontRegardless() } }
        let suite = "pet-resource-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.petEnabled = true
        settings.petScale = 2
        let container = try ModelContainer(
            for: Conversation.self, Project.self, Message.self, ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let controller = PetController(
            settings: settings, viewModel: ChatViewModel(modelContext: container.mainContext),
            sceneActions: SceneActions(), defaults: defaults
        )
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is PetPanel && !previous.contains($0.windowNumber) })
        defer { controller.closeBubble(); panel.orderOut(nil) }
        try await Task.sleep(for: .seconds(2))
        let closed = try await measureCPU()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            try panel.sendEvent(XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
        }
        XCTAssertTrue(controller.bubble.isVisible)
        try await Task.sleep(for: .seconds(1))
        let opened = try await measureCPU()
        print(
            "PET_IDLE_CPU pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "closed=\(closed)% open=\(opened)% sample=12s"
        )
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(controller.bubble.isKeyWindow)
    }

    private func measureCPU() async throws -> Double {
        let start = cpuTime()
        let clock = ContinuousClock.now
        try await Task.sleep(for: .seconds(12))
        let elapsed = clock.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return (cpuTime() - start) / seconds * 100
    }

    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
