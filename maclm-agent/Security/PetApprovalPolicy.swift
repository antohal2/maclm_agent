import Foundation

enum ApprovalSource: String, Sendable { case feed, pet }

enum PetApprovalPolicy {
    static func allows(risk: RiskLevel, source: ApprovalSource, hidden: Bool) -> Bool {
        source == .feed || (risk == .caution && !hidden)
    }
}

enum PetNotificationPolicy {
    static func suppress(approval: Bool, enabled: Bool, visible: Bool) -> Bool {
        !approval && enabled && visible
    }
}
