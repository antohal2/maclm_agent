import Foundation
import SwiftData

@Model
final class ClipboardAction {
    @Attribute(.unique) var id: UUID
    var name: String
    var promptTemplate: String
    var iconSystemName: String
    var sortOrder: Int
    var isEnabled: Bool
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        promptTemplate: String,
        iconSystemName: String,
        sortOrder: Int,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.promptTemplate = promptTemplate
        self.iconSystemName = iconSystemName
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
