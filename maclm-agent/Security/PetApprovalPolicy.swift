import Foundation

enum ApprovalSource: String, Sendable { case feed, pet }

enum PetApprovalPolicy {
    static func allows(risk: RiskLevel, source: ApprovalSource, hidden: Bool, toolName: String? = nil) -> Bool {
        source == .feed || (risk == .caution && !hidden && toolName != "create_skill_draft")
    }
}

enum PetNotificationPolicy {
    static func suppress(approval: Bool, enabled: Bool, visible: Bool) -> Bool {
        !approval && enabled && visible
    }
}

/// Narrow exception: ordinary caution tools keep their existing session memory behavior.
enum ToolApprovalPolicy {
    static func neverRemember(_ toolName: String) -> Bool {
        toolName == "create_skill_draft"
    }
}
