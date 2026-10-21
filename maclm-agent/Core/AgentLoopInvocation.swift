import Foundation

extension AgentLoop {
    @MainActor
    static func captureInvocation(
        _ source: @MainActor @Sendable () -> ToolInvocationContext,
        permissions: SessionPermissions
    ) -> ToolInvocationContext {
        let snapshot = source()
        return ToolInvocationContext(
            conversationID: snapshot.conversationID, project: snapshot.project,
            permissionEpoch: permissions.epoch(for: snapshot.conversationID)
        )
    }
}
