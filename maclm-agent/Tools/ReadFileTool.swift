import Foundation

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read the complete UTF-8 contents of a file at the given path."
    let riskLevel = RiskLevel.safe

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "path": .string(description: "Absolute or relative path to the file."),
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure("File not found: \(url.path)")
        }
        guard !isDirectory.boolValue else {
            return .failure("Path is a directory, not a file: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure("Permission denied or file is not readable: \(url.path)")
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return .success(content: content)
        } catch {
            return .failure("Unable to read \(url.path): \(error.localizedDescription)")
        }
    }
}
