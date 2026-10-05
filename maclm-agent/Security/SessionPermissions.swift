import Foundation
import Observation

struct SessionPermission: Hashable, Identifiable, Sendable {
    let conversationID: UUID
    let toolName: String
    let riskLevel: RiskLevel
    var id: Self {
        self
    }
}

@MainActor @Observable
final class SessionPermissions {
    private(set) var permissions: Set<SessionPermission> = []
    private var epochs: [UUID: Int] = [:]
    nonisolated init() {}
    var sortedPermissions: [SessionPermission] {
        permissions.sorted {
            if $0.toolName != $1.toolName {
                return $0.toolName < $1.toolName
            }
            return $0.conversationID.uuidString < $1.conversationID.uuidString
        }
    }

    func permissions(for id: UUID) -> [SessionPermission] {
        sortedPermissions.filter { $0.conversationID == id }
    }

    func epoch(for id: UUID) -> Int {
        if epochs[id] == nil {
            epochs[id] = 0
        }
        return epochs[id, default: 0]
    }

    func allows(
        conversationID: UUID,
        toolName: String,
        riskLevel: RiskLevel,
        expectedEpoch: Int? = nil
    ) -> Bool {
        guard expectedEpoch == nil || expectedEpoch == epoch(for: conversationID) else { return false }
        return riskLevel.canBeRemembered && permissions.contains(.init(
            conversationID: conversationID,
            toolName: toolName,
            riskLevel: riskLevel
        ))
    }

    func remember(conversationID: UUID, toolName: String, riskLevel: RiskLevel, expectedEpoch: Int? = nil) {
        guard riskLevel.canBeRemembered,
              expectedEpoch == nil || expectedEpoch == epoch(for: conversationID) else { return }
        permissions.insert(.init(conversationID: conversationID, toolName: toolName, riskLevel: riskLevel))
    }

    func revoke(_ permission: SessionPermission) {
        permissions.remove(permission)
    }

    func reset(conversationID: UUID) {
        permissions = permissions.filter { $0.conversationID != conversationID }
        epochs[conversationID, default: 0] += 1
    }

    func reset() {
        for id in Set(permissions.map(\.conversationID)).union(epochs.keys) {
            reset(conversationID: id)
        }
    }
}
