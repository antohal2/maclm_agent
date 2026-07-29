import Foundation

struct WriteFileTool: Tool {
    let name = "write_file"
    let description =
        "Write UTF-8 content to a file by overwriting, appending, or exclusively creating it."
    let riskLevel = RiskLevel.confirm

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "path": .string(description: "Absolute or relative path to the file."),
                "content": .string(description: "Exact UTF-8 content to write."),
                "mode": .string(
                    description: "overwrite replaces or creates; append appends or creates; "
                        + "create fails if the file exists.",
                    enumValues: WriteMode.allCases.map(\.rawValue)
                ),
            ],
            required: ["path", "content", "mode"]
        )
    }

    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult {
        do {
            let request = try WriteFileRequest(arguments: arguments)
            try request.execute()
            return .success(
                content: "Wrote \(request.data.count) bytes to \(request.url.path) "
                    + "using mode '\(request.mode.rawValue)'."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private struct WriteFileRequest {
    let url: URL
    let data: Data
    let mode: WriteMode
    private let targetExists: Bool

    init(arguments: [String: Any]) throws {
        let path = try Self.stringArgument("path", in: arguments, allowEmpty: false)
        let content = try Self.stringArgument("content", in: arguments, allowEmpty: true)
        let modeValue = try Self.stringArgument("mode", in: arguments, allowEmpty: false)
        guard let mode = WriteMode(rawValue: modeValue) else {
            throw WriteFileError.invalidMode
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        try Self.validateParent(of: url)
        var targetIsDirectory: ObjCBool = false
        let targetExists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &targetIsDirectory
        )
        guard !targetIsDirectory.boolValue else {
            throw WriteFileError.targetIsDirectory(url.path)
        }
        guard mode != .create || !targetExists else {
            throw WriteFileError.fileAlreadyExists(url.path)
        }

        self.url = url
        data = Data(content.utf8)
        self.mode = mode
        self.targetExists = targetExists
    }

    func execute() throws {
        switch mode {
        case .overwrite:
            try data.write(to: url, options: .atomic)
        case .append where targetExists:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        case .append:
            try data.write(to: url, options: .atomic)
        case .create:
            try data.write(to: url, options: .withoutOverwriting)
        }
    }

    private static func stringArgument(
        _ name: String,
        in arguments: [String: Any],
        allowEmpty: Bool
    ) throws -> String {
        guard let value = arguments[name] as? String else {
            throw WriteFileError.invalidStringArgument(name)
        }
        let normalized = allowEmpty
            ? value
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !normalized.isEmpty else {
            throw WriteFileError.emptyArgument(name)
        }
        return normalized
    }

    private static func validateParent(of url: URL) throws {
        let parentURL = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: parentURL.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw WriteFileError.parentNotFound(parentURL.path)
        }
    }
}

private enum WriteMode: String, CaseIterable {
    case overwrite
    case append
    case create
}

private enum WriteFileError: LocalizedError {
    case invalidStringArgument(String)
    case emptyArgument(String)
    case invalidMode
    case parentNotFound(String)
    case targetIsDirectory(String)
    case fileAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case let .invalidStringArgument(name):
            "Argument '\(name)' must be a string."
        case let .emptyArgument(name):
            "Argument '\(name)' must not be empty."
        case .invalidMode:
            "Argument 'mode' must be one of: "
                + WriteMode.allCases.map(\.rawValue).joined(separator: ", ")
                + "."
        case let .parentNotFound(path):
            "Parent directory not found: \(path)"
        case let .targetIsDirectory(path):
            "Path is a directory, not a file: \(path)"
        case let .fileAlreadyExists(path):
            "File already exists: \(path)"
        }
    }
}
