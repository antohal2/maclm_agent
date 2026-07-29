import Foundation
import SwiftData

enum ToolCallStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case rejected
    case completed
    case failed
}

@Model
final class ToolCall {
    @Attribute(.unique) var id: UUID
    var toolName: String
    var argumentsJSON: String
    var resultJSON: String?
    private var statusRawValue: String
    var timestamp: Date
    var message: Message?

    var status: ToolCallStatus {
        get {
            ToolCallStatus(rawValue: statusRawValue) ?? .pending
        }
        set {
            statusRawValue = newValue.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        toolName: String,
        argumentsJSON: String,
        resultJSON: String? = nil,
        status: ToolCallStatus = .pending,
        timestamp: Date = Date(),
        message: Message? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
        statusRawValue = status.rawValue
        self.timestamp = timestamp
        self.message = message
    }
}
