import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class PetStateTests: XCTestCase {
    func testMappingSleepAndDrag() {
        var time: TimeInterval = 0
        var machine = PetStateMachine(now: { time })
        XCTAssertEqual(machine.update(kind: .idle, dragging: false), .idle)
        time = 299
        XCTAssertEqual(machine.update(kind: .idle, dragging: false), .idle)
        time = 300
        XCTAssertEqual(machine.update(kind: .idle, dragging: false), .sleep)
        XCTAssertEqual(machine.update(kind: .idle, dragging: true), .drag)
        XCTAssertEqual(machine.update(kind: .running, dragging: false), .running)
        time = 600
        XCTAssertEqual(machine.update(kind: .idle, dragging: false), .idle)
        let mappings: [(AggregateStatus.Kind, PetState)] = [
            (.needsApproval, .needsApproval), (.failed, .failed), (.toolRunning, .toolRunning),
            (.running, .running), (.ready, .ready), (.idle, .idle),
        ]
        for (kind, state) in mappings {
            XCTAssertEqual(PetState.mapped(kind), state)
            XCTAssertEqual(machine.update(kind: kind, dragging: true), .drag)
            XCTAssertEqual(PetStateMachine.available(state, in: [.idle]), .idle)
        }
    }

    func testClickPriorityAndDeterministicSelection() {
        let ids = (0 ..< 6).map { _ in UUID() }
        var statuses: [UUID: SessionStatus] = [
            ids[0]: .needsApproval(risk: .caution), ids[1]: .failed(message: "private"),
            ids[2]: .toolRunning(toolName: "private"), ids[3]: .running, ids[5]: .idle,
        ]
        for expected in ids.prefix(5) {
            let aggregate = AggregateStatus(statuses: statuses, unread: [ids[4]])
            XCTAssertEqual(PetState.conversationID(for: aggregate), expected)
            statuses.removeValue(forKey: expected)
        }
        XCTAssertNil(PetState.conversationID(for: AggregateStatus(statuses: [:], unread: [])))
        let aggregate = AggregateStatus(statuses: [ids[0]: .running, ids[1]: .running], unread: [])
        XCTAssertEqual(PetState.conversationID(for: aggregate), [ids[0], ids[1]].min {
            $0.uuidString < $1.uuidString
        })
    }

    func testPositionRestoration() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let size = CGSize(width: 128, height: 128)
        let valid = CGPoint(x: -500, y: 200)
        XCTAssertEqual(PetPosition.restored(valid, size: size, screens: [main, second], main: main), valid)
        for point in [CGPoint(x: 5000, y: 5000), CGPoint(x: 1400, y: 850), CGPoint(x: CGFloat.nan, y: 0)] {
            XCTAssertEqual(
                PetPosition.restored(point, size: size, screens: [main, second], main: main),
                CGPoint(x: 1288, y: 24)
            )
        }
    }

    @MainActor func testCommandNeverCreatesMessagesAndSettingsPersist() throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = ChatViewModel(modelContext: container.mainContext)
        let suite = "pet-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.petEnabled)
        XCTAssertEqual(settings.petScale, 2)
        model.togglePet = { settings.petEnabled.toggle() }
        let before = try container.mainContext.fetchCount(FetchDescriptor<Message>())
        for input in ["/pet", " /pet ", "\n/pet\t"] {
            model.input = input
            XCTAssertTrue(model.canSend)
            model.send()
            XCTAssertEqual(model.input, "")
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Message>()), before)
        }
        XCTAssertFalse(PetCommand.matches("/pet please"))
        XCTAssertFalse(PetCommand.matches("/PET"))
        XCTAssertTrue(AppSettings(defaults: defaults).petEnabled)
        settings.petScale = 3
        XCTAssertEqual(AppSettings(defaults: defaults).petScale, 3)
    }
}
