import Foundation

struct ListSkillFilesTool: Tool {
    let name = "list_skill_files"
    let description = "List relative file paths and byte sizes of an enabled skill attached to the current session. "
        + "Hidden files and symbolic links are excluded."
    static let baseRiskLevel: RiskLevel = .safe
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: ["skill": .string(description: "Attached skill id (folder name)")], required: ["skill"])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .failure("unavailable: no skill session")
    }
}

struct ReadSkillFileTool: Tool {
    let name = "read_skill_file"
    let description = "Read one UTF-8 text file (at most 32 KB) of an enabled skill attached to the current session. "
        + "Use a relative path; defaults to SKILL.md. Hidden paths and symbolic links are forbidden."
    static let baseRiskLevel: RiskLevel = .safe
    static let isPolicyEnforceable = true
    var parametersSchema: JSONSchema {
        .object(properties: [
            "skill": .string(description: "Attached skill id (folder name)"),
            "path": .string(description: "Relative file path, defaults to SKILL.md"),
        ], required: ["skill"])
    }

    func execute(arguments _: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        .failure("unavailable: no skill session")
    }
}
