import Foundation

struct CreateSkillDraftTool: Tool {
    let name = "create_skill_draft"
    let description = """
    Draft a reusable skill only after an explicit user request. Requires full review; creates a disabled skill.
    Put the SKILL.md body in instructions; the app adds name/description frontmatter.
    files is an array of supporting files only, normally []. Never put SKILL.md in files.
    """
    static let baseRiskLevel: RiskLevel = .caution
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [
            "name": .string(description: "Skill folder name: a-z, 0-9, single hyphens; 1–64 bytes"),
            "description": .string(description: "When to use this skill; 1–1024 characters"),
            "instructions": .string(
                description: "Complete SKILL.md body, without frontmatter; required even if files is empty"
            ),
            "files": .array(
                items: .object(properties: [
                    "path": .string(description: "Relative non-hidden supporting file path; must not be SKILL.md"),
                    "content": .string(description: "Complete UTF-8 text"),
                ], required: ["path", "content"]),
                description: "Optional supporting text files only. Use [] when unnecessary; never include SKILL.md."
            ),
        ], required: ["name", "description", "instructions", "files"])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .success(content: "not requested")
    }
}
