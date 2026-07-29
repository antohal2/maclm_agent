import Foundation

struct DeleteFileTool: Tool {
    let name = "delete_file"
    let description = "Move a file or directory to the macOS Trash. Never deletes permanently."
    let riskLevel = RiskLevel.confirm

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "path": .string(description: "Path to move to the macOS Trash."),
            ],
            required: ["path"]
        )
    }

    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult {
        let path: String
        switch ToolArgument.requiredString(named: "path", in: arguments) {
        case let .value(value):
            path = value
        case let .error(result):
            return result
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("File or directory not found: \(url.path)")
        }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: url,
                resultingItemURL: &resultingURL
            )
            let trashedPath = (resultingURL as URL?)?.path
            return .success(
                content: trashedPath.map {
                    "Moved \(url.path) to Trash at \($0)."
                } ?? "Moved \(url.path) to Trash."
            )
        } catch {
            return .failure("Unable to move \(url.path) to Trash: \(error.localizedDescription)")
        }
    }
}
