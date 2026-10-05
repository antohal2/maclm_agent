import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID = UUID()
    var name: String = ""
    var workingDirectoryPath: String?
    var instructions: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Conversation.project)
    var conversations: [Conversation] = []

    init(name: String, workingDirectoryPath: String? = nil, instructions: String = "", sortOrder: Int = 0) {
        self.name = name
        self.workingDirectoryPath = workingDirectoryPath
        self.instructions = String(instructions.prefix(4000))
        self.sortOrder = sortOrder
    }
}
