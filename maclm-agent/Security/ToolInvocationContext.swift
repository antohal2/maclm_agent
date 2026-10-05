import Foundation

struct ProjectSecuritySnapshot: Equatable, Sendable {
    let id: UUID
    let workingDirectoryPath: String?
}

struct ToolInvocationContext: Equatable, Sendable {
    let conversationID: UUID
    let project: ProjectSecuritySnapshot?
    let permissionEpoch: Int

    init(conversationID: UUID, project: ProjectSecuritySnapshot? = nil, permissionEpoch: Int = 0) {
        self.conversationID = conversationID
        self.project = project
        self.permissionEpoch = permissionEpoch
    }

    var workingDirectory: String? {
        guard let path = project?.workingDirectoryPath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return path
    }
}
