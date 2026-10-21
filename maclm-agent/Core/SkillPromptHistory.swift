import Foundation

enum SkillPromptHistory {
    static func refresh(
        _ history: [ChatMessage], systemPrompt: (@MainActor @Sendable () async -> String)?
    ) async -> [ChatMessage] {
        guard let systemPrompt else { return history }
        let prompt = await systemPrompt()
        let messages = history.filter { $0.role != .system }
        return prompt.isEmpty ? messages : [ChatMessage(role: .system, content: prompt)] + messages
    }
}

struct EvaluatedToolOperation {
    let tool: any Tool
    let toolCall: ChatToolCall
    let arguments: [String: Any]
    let executionArguments: [String: Any]
    let invocation: ToolInvocationContext
    let policy: SecurityPolicyEngine
    let assessment: RiskAssessment
}
