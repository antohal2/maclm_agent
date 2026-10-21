import Foundation

@MainActor final class SessionSkillDraft {
    static let instruction = """
    Create a reusable skill from the work we just did. Call create_skill_draft once. \
    Write `description` so that it says when the skill should be used. \
    Generalize the instructions: no secrets, no personal absolute paths, \
    no executable scripts (scripts are not run), no one-off details. \
    Keep SKILL.md under 8 KB. Use supporting files only if they are really needed.
    """
    let store: SkillStore
    let conversationID: UUID
    private(set) var requested = false

    init(store: SkillStore, conversationID: UUID) {
        self.store = store
        self.conversationID = conversationID
    }

    func request() {
        requested = true
    }

    func clear() {
        requested = false
    }

    func prepare(_ raw: String) async throws -> SkillDraft? {
        guard requested else {
            try await store.persistDraftAudit(SkillStore.draftAudit(
                "skill.draftUnrequested", hash: SkillHasher.digest(Data(raw.utf8)), conversationID: conversationID
            ))
            return nil
        }
        let draft = try SkillDraft.parse(Data(raw.utf8))
        try await store.checkDraftName(draft.name)
        try Task.checkCancellation()
        guard requested else { throw CancellationError() }
        try await store.auditDraft("skill.draftShown", draft: draft, conversationID: conversationID)
        try Task.checkCancellation()
        guard requested else { throw CancellationError() }
        requested = false
        return draft
    }

    func finish(_ draft: SkillDraft, decision: ConfirmationDecision) async throws -> ToolExecutionResult {
        try Task.checkCancellation()
        if decision == .approved {
            return try await store.saveDraft(draft, conversationID: conversationID)
        }
        try await store.auditDraft("skill.draftRejected", draft: draft, conversationID: conversationID)
        return .success(content: "rejected")
    }
}
