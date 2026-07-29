import Foundation
import SwiftData

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case tool
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    private var roleRawValue: String
    var content: String
    var toolCallID: String?
    var timestamp: Date
    var conversation: Conversation?

    @Relationship(deleteRule: .cascade, inverse: \ToolCall.message)
    var toolCalls: [ToolCall]

    var role: MessageRole {
        get {
            MessageRole(rawValue: roleRawValue) ?? .system
        }
        set {
            roleRawValue = newValue.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        toolCallID: String? = nil,
        timestamp: Date = Date(),
        conversation: Conversation? = nil,
        toolCalls: [ToolCall] = []
    ) {
        self.id = id
        roleRawValue = role.rawValue
        self.content = content
        self.toolCallID = toolCallID
        self.timestamp = timestamp
        self.conversation = conversation
        self.toolCalls = toolCalls
    }
}
