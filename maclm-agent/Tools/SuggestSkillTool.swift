import Foundation

struct SuggestSkillTool: Tool {
    let name = "suggest_skill"
    let description = "Propose an enabled skill for this task. Requires the user's click; never attaches automatically."
    static let baseRiskLevel: RiskLevel = .safe
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [
            "name": .string(description: "Enabled skill name from the catalog"),
            "reason": .string(description: "Why this skill helps the current task"),
        ], required: ["name", "reason"])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .success(content: "unavailable: no skill session")
    }
}
