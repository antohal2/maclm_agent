import Foundation

struct SearchFilesTool: Tool {
    let name = "search_files"
    let description =
        "Recursively find files whose filename contains the pattern (case-insensitive substring match)."
    let riskLevel = RiskLevel.safe

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "root": .string(description: "Root directory to search recursively."),
                "pattern": .string(
                    description: "Case-insensitive substring that must occur in the filename."
                ),
            ],
            required: ["root", "pattern"]
        )
    }

    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult {
        let root: String
        switch ToolArgument.requiredString(named: "root", in: arguments) {
        case let .value(value):
            root = value
        case let .error(result):
            return result
        }

        let pattern: String
        switch ToolArgument.requiredString(named: "pattern", in: arguments) {
        case let .value(value):
            pattern = value
        case let .error(result):
            return result
        }

        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return .failure("Search root not found: \(rootURL.path)")
        }
        guard isDirectory.boolValue else {
            return .failure("Search root is not a directory: \(rootURL.path)")
        }
        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            return .failure("Permission denied or directory is not readable: \(rootURL.path)")
        }

        do {
            let matches = try findMatches(in: rootURL, pattern: pattern)
            let data = try JSONEncoder.toolOutput.encode(matches)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("Unable to encode search results as UTF-8.")
            }
            return .success(
                content: content,
                displayContent: matches.isEmpty ? "(no matches)" : matches.joined(separator: "\n")
            )
        } catch {
            return .failure("Unable to search \(rootURL.path): \(error.localizedDescription)")
        }
    }

    private func findMatches(
        in rootURL: URL,
        pattern: String
    ) throws -> [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw SearchFilesError.unableToEnumerate(rootURL.path)
        }

        var matches: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard
                values.isRegularFile == true,
                fileURL.lastPathComponent.localizedCaseInsensitiveContains(pattern)
            else {
                continue
            }
            matches.append(fileURL.standardizedFileURL.path)
        }
        return matches.sorted()
    }
}

private enum SearchFilesError: LocalizedError {
    case unableToEnumerate(String)

    var errorDescription: String? {
        switch self {
        case let .unableToEnumerate(path):
            "Unable to enumerate search root: \(path)"
        }
    }
}

extension JSONEncoder {
    static var toolOutput: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
