import Foundation
import Observation

struct SessionPermission: Hashable, Identifiable, Sendable {
    let toolName: String
    let riskLevel: RiskLevel
    var id: Self { self }
}

@MainActor
@Observable
final class SessionPermissions {
    private(set) var permissions: Set<SessionPermission> = []

    nonisolated init() {}

    var sortedPermissions: [SessionPermission] {
        permissions.sorted {
            if $0.toolName != $1.toolName { return $0.toolName < $1.toolName }
            return $0.riskLevel < $1.riskLevel
        }
    }

    func allows(toolName: String, riskLevel: RiskLevel) -> Bool {
        riskLevel.canBeRemembered && permissions.contains(.init(toolName: toolName, riskLevel: riskLevel))
    }

    func remember(toolName: String, riskLevel: RiskLevel) {
        guard riskLevel.canBeRemembered else { return }
        permissions.insert(.init(toolName: toolName, riskLevel: riskLevel))
    }

    func reset() { permissions.removeAll() }
}
