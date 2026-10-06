import Foundation
import SwiftData

struct CheckpointItem: Codable, Equatable, Sendable {
    var originalPath: String
    var existedBefore: Bool
    var isDirectory: Bool
    var storedRelativePath: String?
    var sha256: String?
}

struct CheckpointSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var conversationID: UUID?
    var toolName: String
    var items: [CheckpointItem]
    var totalBytes: Int64
    var isRestored = false
    var postOperation: [FileFingerprint]?
}

@Model final class Checkpoint {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var conversationID: UUID?
    var toolName: String = ""
    var items: [CheckpointItem] = []
    var totalBytes: Int64 = 0
    var isRestored: Bool = false
    var postOperation: [FileFingerprint]?

    init(_ value: CheckpointSnapshot) {
        update(value)
    }

    func update(_ value: CheckpointSnapshot) {
        id = value.id
        createdAt = value.createdAt
        conversationID = value.conversationID
        toolName = value.toolName
        items = value.items
        totalBytes = value.totalBytes
        isRestored = value.isRestored
        postOperation = value.postOperation
    }

    var snapshot: CheckpointSnapshot {
        .init(
            id: id,
            createdAt: createdAt,
            conversationID: conversationID,
            toolName: toolName,
            items: items,
            totalBytes: totalBytes,
            isRestored: isRestored,
            postOperation: postOperation
        )
    }
}
