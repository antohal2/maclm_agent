import Darwin
import Foundation

enum SkillFileAccessError: String, Error {
    case invalidPath = "invalid or hidden relative path"
    case tooLarge = "file exceeds 32 KB"
    case invalidText = "file must be UTF-8 text, not binary"
    case enumerationLimit = "skill listing limit exceeded"
}

struct SkillFileRequest: Sendable {
    enum Action: Sendable { case list, read }
    let action: Action
    let skill: String?
    let path: String?
    let argumentError: String?

    init(action: Action, arguments: [String: Any]) {
        self.action = action
        skill = arguments["skill"] as? String
        path = action == .read ? (arguments["path"] as? String ?? "SKILL.md") : nil
        argumentError = action == .read && arguments["path"] != nil && !(arguments["path"] is String)
            ? "path must be a string" : nil
    }

    var event: String {
        action == .list ? "skill.fileList" : "skill.fileRead"
    }
}

/// Uses the same descriptor resolver for listing and reading. No trust/hash checks here.
enum SkillFileAccess {
    static let maximumReadSize = 32 * 1024

    static func read(_ path: String, root: Int32) throws -> String {
        try SkillFileIO.withResolvedPath(path, root: root) { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SkillValidationError.unreadable }
            guard info.st_size >= 0, info.st_size <= maximumReadSize else { throw SkillFileAccessError.tooLarge }
            let data = try SkillFileIO.readOpenedFile(descriptor, expectedSize: Int(info.st_size))
            guard let text = String(data: data, encoding: .utf8),
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
                  })
            else { throw SkillFileAccessError.invalidText }
            return text
        }
    }

    static func list(root: Int32) throws -> [SkillFile] {
        var files: [SkillFile] = []
        var entries = 0
        try enumerate(nil, root: root, files: &files, entries: &entries, depth: 0)
        return files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func enumerate(
        _ path: String?, root: Int32, files: inout [SkillFile], entries: inout Int, depth: Int
    ) throws {
        guard depth < 64 else { throw SkillFileAccessError.enumerationLimit }
        try SkillFileIO.withResolvedPath(path, root: root, directory: true) { descriptor in
            for name in try SkillFileIO.names(descriptor) {
                entries += 1
                guard entries <= 2000 else { throw SkillFileAccessError.enumerationLimit }
                let child = path.map { $0 + "/" + name } ?? name
                // Hidden and lexically unsafe names cannot be exposed through listing either.
                guard (try? SkillFileIO.validateModelPath(child)) != nil else { continue }
                let info = try SkillFileIO.info(name, parent: descriptor)
                switch SkillFileIO.kind(info) {
                case S_IFDIR:
                    try enumerate(child, root: root, files: &files, entries: &entries, depth: depth + 1)
                case S_IFREG:
                    try SkillFileIO.withResolvedPath(child, root: root) { opened in
                        var current = stat()
                        guard fstat(opened, &current) == 0, current.st_size >= 0 else {
                            throw SkillValidationError.unreadable
                        }
                        guard files.count < SkillScanner.maximumFiles else {
                            throw SkillFileAccessError.enumerationLimit
                        }
                        files.append(SkillFile(path: child, size: Int(current.st_size)))
                    }
                default: continue // Never open a link or a special file.
                }
            }
        }
    }

    static func reason(_ error: Error) -> String {
        if let access = error as? SkillFileAccessError {
            return access.rawValue
        }
        switch error {
        case SkillValidationError.symlink: return "symbolic links are forbidden"
        case SkillValidationError.unsupportedFile: return "target must be a regular file"
        case SkillValidationError.changedDuringScan: return "file changed during read"
        default: return "file or skill folder missing, unreadable, or a symbolic link"
        }
    }
}
