@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class SessionNotificationTests: XCTestCase {
    func testContentExposesOnlyTitleBodyAndConversationID() {
        let conversation = Conversation(title: "Ops")
        let content = SessionNotifications.content(conversation, body: "Approval required: run_shell")
        XCTAssertEqual(content.title, "Ops")
        XCTAssertEqual(content.body, "Approval required: run_shell")
        XCTAssertEqual(content.userInfo.count, 1)
        XCTAssertEqual(content.userInfo["conversationID"] as? String, conversation.id.uuidString)
    }

    func testNotificationRouteSelectsConversationAndOpensWindow() throws {
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = ChatViewModel(modelContext: container.mainContext)
        let first = try XCTUnwrap(model.selectedConversation)
        first.hasUnreadResult = true
        model.createConversation()
        var opened = false
        let scenes = SceneActions()
        scenes.openMainWindowAction = { opened = true }
        let notifications = SessionNotifications(settings: AppSettings(), viewModel: model, sceneActions: scenes)
        notifications.openConversation(id: first.id.uuidString)
        XCTAssertEqual(model.selectedConversationID, first.id)
        XCTAssertFalse(first.hasUnreadResult)
        XCTAssertTrue(opened)
        opened = false
        notifications.openConversation(id: UUID().uuidString)
        XCTAssertFalse(opened)
    }
}
