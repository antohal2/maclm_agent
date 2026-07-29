import Foundation

struct ListDirectoryTool: Tool {
    let name = "list_dir"
    let description = "List the immediate entries in a directory. Directory names end with '/'."
    let riskLevel = RiskLevel.safe

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "path": .string(description: "Absolute or relative path to the directory."),
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
            return .failure("Directory not found: \(url.path)")
        }
        guard isDirectory.boolValue else {
            return .failure("Path is not a directory: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure("Permission denied or directory is not readable: \(url.path)")
        }

        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys)
            )
            let entries = try urls.map { entryURL in
                let values = try entryURL.resourceValues(forKeys: keys)
                return values.isDirectory == true
                    ? "\(entryURL.lastPathComponent)/"
                    : entryURL.lastPathComponent
            }
            .sorted()
            let data = try JSONEncoder.toolOutput.encode(entries)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("Unable to encode directory listing as UTF-8.")
            }
            return .success(
                content: content,
                displayContent: entries.isEmpty ? "(empty directory)" : entries.joined(separator: "\n")
            )
        } catch {
            return .failure("Unable to list \(url.path): \(error.localizedDescription)")
        }
    }
}
