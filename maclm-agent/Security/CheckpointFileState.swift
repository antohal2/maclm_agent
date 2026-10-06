import CryptoKit
import Foundation

struct FileFingerprint: Codable, Equatable, Sendable {
    var path: String
    var exists: Bool
    var digest: String?
    var metadata: String?
}

struct FileInspection: Sendable {
    var fingerprint: FileFingerprint
    var bytes: Int64
    var count: Int
    var isDirectory: Bool
    var modified: Date?
}

enum CheckpointError: String, Error, LocalizedError, Sendable {
    case changed = "Файл изменился после показа превью, повторите действие"
    case limit = "Превышен лимит размера чекпоинта"
    case space = "Недостаточно свободного места для чекпоинта"
    case unreadable = "Нет прав на чтение объекта"
    case blocked = "Путь запрещён правилами безопасности"
    case corrupt = "Нарушена целостность чекпоинта"
    case unavailable = "Превью недоступно"
    case busy = "Откат уже выполняется"
    case copy = "Не удалось сохранить чекпоинт; инструмент не выполнен"
    var errorDescription: String? {
        InterfaceLocalization.text(rawValue)
    }
}

enum CheckpointFileState {
    /// Resolve parents; preserve the last link for atomic replacement, move and Trash.
    static func operationPath(_ path: String, followsLeaf: Bool = false) -> String {
        if followsLeaf {
            return PathCanonicalizer.canonicalize(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = PathCanonicalizer.canonicalize(url.deletingLastPathComponent().path)
        return (parent == "/" ? "/" : parent + "/") + url.lastPathComponent
    }

    static func paths(tool: String, arguments: [String: String]) throws -> [String] {
        let keys = tool == "move_file" ? ["from", "to"] : ["path"]
        let paths = try keys.map { key in
            guard let path = arguments[key], !path.isEmpty else { throw CheckpointError.unavailable }
            return operationPath(path, followsLeaf: tool == "write_file" && arguments["mode"] == "append")
        }
        if
            tool == "move_file",
            paths[0] == paths[1] || paths[0].hasPrefix(paths[1] + "/") || paths[1].hasPrefix(paths[0] + "/")
        {
            throw CheckpointError.corrupt
        }
        return paths
    }

    static func authorize(_ path: String, policy: SecurityPolicyEngine, requireZone: Bool) throws {
        guard
            policy.decision(for: path, dimension: .path).isAllowed,
            !requireZone || policy.invocation.workingDirectory == nil || policy.isInProjectAllowedZone(path)
        else { throw CheckpointError.blocked }
    }

    static func metadata(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return [.type, .size, .posixPermissions, .systemFileNumber].map {
            String(describing: attributes[$0])
        }.joined(separator: "|") + "|" + String(modified)
    }

    // Keep the existing operation and error ordering unchanged.
    // swiftlint:disable:next function_body_length
    static func inspect(
        _ path: String,
        policy: SecurityPolicyEngine? = nil,
        requireZone: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> FileInspection {
        let fm = FileManager.default
        var hash = SHA256()
        var bytes: Int64 = 0
        var count = 0
        func check(_ value: String) throws {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline {
                throw CheckpointError.unavailable
            }
            if let policy {
                try authorize(value, policy: policy, requireZone: requireZone)
            }
        }
        func walk(_ url: URL, relative: String) throws {
            try check(url.path)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw CheckpointError.unreadable }
            // Include paths, types, metadata and contents. Directory links are never traversed.
            hash.update(data: Data((relative + "\0" + type.rawValue + "\0").utf8))
            for key in [FileAttributeKey.modificationDate, .posixPermissions, .systemFileNumber] {
                hash.update(data: Data(String(describing: attributes[key]).utf8))
            }
            if type == .typeSymbolicLink {
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                hash.update(data: Data(target.utf8))
                bytes += Int64(target.utf8.count)
            } else if type == .typeDirectory {
                guard fm.isReadableFile(atPath: url.path) else { throw CheckpointError.unreadable }
                for child in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    count += 1
                    try walk(url.appendingPathComponent(child), relative: relative + "/" + child)
                }
            } else if type == .typeRegular {
                guard fm.isReadableFile(atPath: url.path) else { throw CheckpointError.unreadable }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    try check(url.path)
                    bytes += Int64(chunk.count)
                    hash.update(data: chunk)
                }
            } else {
                throw CheckpointError.unreadable
            }
        }
        try check(path)
        let attrs: [FileAttributeKey: Any]
        do { attrs = try fm.attributesOfItem(atPath: path) } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        // SwiftFormat wraps this catch condition; preserve the existing error filter.
        // swiftlint:disable:next opening_brace
        {
            return .init(
                fingerprint: .init(path: path, exists: false, digest: nil),
                bytes: 0,
                count: 0,
                isDirectory: false,
                modified: nil
            )
        }
        try walk(URL(fileURLWithPath: path), relative: "")
        return .init(
            fingerprint: .init(path: path, exists: true, digest: hex(hash.finalize())),
            bytes: bytes,
            count: count,
            isDirectory: attrs[.type] as? FileAttributeType == .typeDirectory,
            modified: attrs[.modificationDate] as? Date
        )
    }

    /// Portable digest of a saved object, independent of inode and timestamps.
    static func contentHash(_ url: URL) throws -> String {
        var hash = SHA256()
        func walk(_ url: URL, relative: String) throws {
            try Task.checkCancellation()
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            hash.update(data: Data((relative + "\0" + (type?.rawValue ?? "") + "\0").utf8))
            if type == .typeSymbolicLink {
                try hash.update(data: Data(FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            } else if type == .typeDirectory {
                for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try walk(url.appendingPathComponent(child), relative: relative + "/" + child)
                }
            } else if type == .typeRegular {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    hash.update(data: chunk)
                }
            } else {
                throw CheckpointError.corrupt
            }
        }
        try walk(url, relative: "")
        return hex(hash.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
