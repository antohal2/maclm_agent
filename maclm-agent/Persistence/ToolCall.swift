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
    var providerCallID: String?
    var toolName: String
    var argumentsJSON: String
    var resultJSON: String?
    // Effective risk snapshot for confirmation display; session grants are never persisted.
    var confirmationRiskRawValue: Int? = nil
    var confirmationRiskReason: String? = nil
    var filePreview: FilePreview? = nil
    private var statusRawValue: String
    var timestamp: Date
    var message: Message?

    var confirmationRiskLevel: RiskLevel {
        // Legacy pending records have no snapshot: display them conservatively.
        RiskLevel(rawValue: confirmationRiskRawValue ?? RiskLevel.dangerous.rawValue) ?? .dangerous
    }

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
        providerCallID: String? = nil,
        toolName: String,
        argumentsJSON: String,
        resultJSON: String? = nil,
        status: ToolCallStatus = .pending,
        timestamp: Date = Date(),
        message: Message? = nil
    ) {
        self.id = id
        self.providerCallID = providerCallID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
        statusRawValue = status.rawValue
        self.timestamp = timestamp
        self.message = message
    }
}
