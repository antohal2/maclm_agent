import Foundation

struct MoveFileTool: Tool {
    let name = "move_file"
    let description = "Move a file or directory from one path to another."
    static let baseRiskLevel = RiskLevel.caution
    static let isPolicyEnforceable = true

    func computeRisk(arguments: [String: Any], context: ToolRiskContext) -> RiskAssessment {
        let paths = ["from", "to"]
        if paths.contains(where: { !context.contains(arguments[$0] as? String) }) {
            return RiskAssessment(level: .dangerous, reason: "путь вне разрешённых директорий")
        }
        return RiskAssessment(level: Self.baseRiskLevel)
    }

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "from": .string(description: "Existing source path."),
                "to": .string(description: "Destination path."),
            ],
            required: ["from", "to"]
        )
    }

    func execute(arguments: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        let sourcePath: String
        switch ToolArgument.requiredString(named: "from", in: arguments) {
        case let .value(value):
            sourcePath = value
        case let .error(result):
            return result
        }

        let destinationPath: String
        switch ToolArgument.requiredString(named: "to", in: arguments) {
        case let .value(value):
            destinationPath = value
        case let .error(result):
            return result
        }

        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .failure("Source not found: \(sourceURL.path)")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return .failure("Destination already exists: \(destinationURL.path)")
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return .success(
                content: "Moved \(sourceURL.path) to \(destinationURL.path)."
            )
        } catch {
            return .failure(
                "Unable to move \(sourceURL.path) to \(destinationURL.path): "
                    + error.localizedDescription
            )
        }
    }
}
