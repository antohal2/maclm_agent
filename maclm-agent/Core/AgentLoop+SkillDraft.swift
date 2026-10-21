import Foundation

extension AgentLoop {
    func executeSkillDraft(
        _ call: ChatToolCall, session: SessionSkillDraft?, invocation: ToolInvocationContext,
        audit: inout AuditRecord,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws -> AgentToolCallExecution {
        audit.riskLevel = .caution
        guard let session else {
            try await recordUnrequestedDraft(call, invocation: invocation)
            audit.outcome = .notExecuted
            return AgentToolCallExecution(toolCall: call, result: .success(content: "not requested"))
        }
        let draft: SkillDraft
        do {
            guard let prepared = try await session.prepare(call.function.arguments) else {
                audit.outcome = .notExecuted
                return AgentToolCallExecution(toolCall: call, result: .success(content: "not requested"))
            }
            draft = prepared
        } catch is CancellationError { throw CancellationError() } catch {
            audit.errorDescription = SkillDraft.reason(error)
            return AgentToolCallExecution(toolCall: call, result: .failure(SkillDraft.reason(error)))
        }
        let confirmation: ToolConfirmation
        do {
            confirmation = try await confirmIfNeeded(
                toolCall: call, assessment: .init(level: .caution), invocation: invocation,
                callID: audit.toolCallID ?? UUID(),
                prepared: nil, onEvent: onEvent
            )
        } catch is CancellationError {
            _ = try? await session.store.auditDraft(
                "skill.draftRejected",
                draft: draft,
                conversationID: invocation.conversationID
            )
            throw CancellationError()
        }
        let decision = confirmation.decision ?? .rejected
        let result: ToolExecutionResult
        do {
            result = try await session.finish(draft, decision: decision)
        } catch is CancellationError { throw CancellationError() } catch {
            result = .failure(SkillDraft.reason(error))
        }
        audit.decision = decision == .approved ? .approved : .rejected
        audit.complete(result, toolName: "create_skill_draft", arguments: [:])
        return AgentToolCallExecution(
            toolCall: call, result: result, confirmationDecision: decision,
            confirmationRequestID: confirmation.requestID
        )
    }
}
