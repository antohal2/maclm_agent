import Foundation
import SwiftData

@Model
final class Conversation {
    static let defaultTitle = "Новая беседа"

    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var project: Project?
    var hasUnreadResult: Bool = false
    var isPinned: Bool = false
    var isArchived: Bool = false
    var titleIsManual: Bool = false
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
    }

    var orderedMessages: [Message] {
        messages.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
    }

    static func generatedTitle(from content: String, limit: Int = 40) -> String {
        ConversationTitle.fallback(content, limit: limit)
    }
}
