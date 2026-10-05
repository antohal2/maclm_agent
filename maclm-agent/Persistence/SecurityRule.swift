import Foundation
import SwiftData

enum RuleDimension: String, Codable, CaseIterable, Sendable {
    case path, command, application, host
}

enum RuleAction: String, Codable, Sendable {
    case allow, block
}

@Model
final class SecurityRule {
    var dimension: RuleDimension
    var pattern: String
    var action: RuleAction
    var isEnabled: Bool
    var order: Int
    var isBuiltIn: Bool
    var ruleDescription: String
    var createdAt: Date

    init(dimension: RuleDimension, pattern: String, action: RuleAction,
         isEnabled: Bool = true, order: Int = 0, isBuiltIn: Bool = false,
         ruleDescription: String = "", createdAt: Date = .now) {
        self.dimension = dimension
        self.pattern = pattern
        self.action = action
        self.isEnabled = isEnabled
        self.order = order
        self.isBuiltIn = isBuiltIn
        self.ruleDescription = ruleDescription
        self.createdAt = createdAt
    }

    var snapshot: SecurityRuleSnapshot {
        .init(dimension: dimension, pattern: pattern, action: action,
              isEnabled: isEnabled, order: order, isBuiltIn: isBuiltIn,
              ruleDescription: ruleDescription, createdAt: createdAt)
    }
}

struct SecurityRuleSnapshot: Equatable, Sendable {
    var dimension: RuleDimension = .path
    var pattern: String
    var action: RuleAction
    var isEnabled: Bool = true
    var order: Int = 0
    var isBuiltIn: Bool = false
    var ruleDescription: String = ""
    var createdAt: Date = .distantPast
}
