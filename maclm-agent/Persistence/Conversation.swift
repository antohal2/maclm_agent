import Foundation
import SwiftData

@Model
final class Conversation {
    static let defaultTitle = "Новая беседа"

    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
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
        let normalized = content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else {
            return defaultTitle
        }

        let prefix = String(normalized.prefix(limit))
        return normalized.count > limit ? "\(prefix)…" : prefix
    }
}
