import Foundation
@testable import maclm_agent

let legacyConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!

extension SecurityPolicyEngine {
    init(rules: [SecurityRuleSnapshot]) {
        self.init(rules: rules, invocation: .init(conversationID: legacyConversationID))
    }
}

extension ToolRiskEvaluator {
    static func evaluate(_ tool: any Tool, arguments: [String: Any], context: ToolRiskContext) -> RiskAssessment {
        evaluate(tool, arguments: arguments, context: context, invocation: .init(conversationID: legacyConversationID))
    }
}

extension AgentLoop {
    func streamResponse(
        to messages: [ChatMessage],
        using provider: any LLMProvider,
        conversationID: UUID = legacyConversationID,
        onEvent: @escaping @Sendable (AgentLoopEvent) async -> Void
    ) async throws {
        try await streamResponse(
            to: messages,
            using: provider,
            invocationContext: { .init(conversationID: conversationID) },
            onEvent: onEvent
        )
    }
}

@MainActor extension SessionPermissions {
    func remember(toolName: String, riskLevel: RiskLevel) {
        remember(conversationID: legacyConversationID, toolName: toolName, riskLevel: riskLevel)
    }

    func allows(toolName: String, riskLevel: RiskLevel) -> Bool {
        allows(conversationID: legacyConversationID, toolName: toolName, riskLevel: riskLevel)
    }
}

extension SessionPermission {
    init(toolName: String, riskLevel: RiskLevel) {
        self.init(conversationID: legacyConversationID, toolName: toolName, riskLevel: riskLevel)
    }
}

/// Legacy tests have an explicit fixture context; no context-free API ships in the app.
extension Tool {
    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult {
        try await execute(arguments: arguments, invocation: .init(conversationID: legacyConversationID))
    }

    func execute(arguments: [String: Any], policy: SecurityPolicyEngine) async throws -> ToolExecutionResult {
        try await execute(arguments: arguments, invocation: policy.invocation, policy: policy)
    }
}
