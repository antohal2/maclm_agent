import Darwin
import Foundation

struct MoveFileTool: Tool {
    let name = "move_file"
    let description = "Move a file or directory from one path to another, replacing an existing destination."
    static let baseRiskLevel = RiskLevel.caution
    static let isPolicyEnforceable = true

    func computeRisk(arguments: [String: Any], context: ToolRiskContext) -> RiskAssessment {
        if let destination = arguments["to"] as? String {
            var destinationInfo = stat()
            let destinationPath = URL(
                fileURLWithPath: destination.trimmingCharacters(in: .whitespacesAndNewlines)
            ).standardizedFileURL.path
            if lstat(destinationPath, &destinationInfo) == 0 {
                let sameObject = (arguments["from"] as? String).map {
                    Self.sameObject($0, destinationPath)
                } ?? false
                if !sameObject {
                    return RiskAssessment(level: .dangerous, reason: "Назначение существует: файл будет перезаписан")
                }
            }
        }
        let paths = ["from", "to"]
        if paths.contains(where: { !context.contains(arguments[$0] as? String) }) {
            return RiskAssessment(level: .dangerous, reason: "путь вне разрешённых директорий")
        }
        return RiskAssessment(level: Self.baseRiskLevel)
    }

    private static func sameObject(_ source: String, _ destination: String) -> Bool {
        var sourceInfo = stat()
        var destinationInfo = stat()
        let sourcePath = URL(
            fileURLWithPath: source.trimmingCharacters(in: .whitespacesAndNewlines)
        ).standardizedFileURL.path
        let destinationPath = URL(
            fileURLWithPath: destination.trimmingCharacters(in: .whitespacesAndNewlines)
        ).standardizedFileURL.path
        return lstat(sourcePath, &sourceInfo) == 0
            && lstat(destinationPath, &destinationInfo) == 0
            && sourceInfo.st_dev == destinationInfo.st_dev
            && sourceInfo.st_ino == destinationInfo.st_ino
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
        let sourceOperation = CheckpointFileState.operationPath(sourceURL.path)
        let destinationOperation = CheckpointFileState.operationPath(destinationURL.path)
        guard sourceOperation != destinationOperation,
              !destinationOperation.hasPrefix(sourceOperation + "/"),
              !sourceOperation.hasPrefix(destinationOperation + "/")
        else {
            return .failure("Source and destination must be distinct, non-nested paths.")
        }

        do {
            if sourceURL.path.lowercased() == destinationURL.path.lowercased(),
               Self.sameObject(sourceURL.path, destinationURL.path)
            {
                // Case-only rename must not unlink the source through its destination alias.
                guard rename(sourceURL.path, destinationURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return .success(content: "Moved \(sourceURL.path) to \(destinationURL.path).")
            }
            if (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)) != nil {
                try FileManager.default.removeItem(at: destinationURL)
            }
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
