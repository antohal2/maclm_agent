import Darwin
import Foundation

/// Snapshot IO never traverses skills/. All children stay relative to no-follow descriptors.
enum SkillSnapshotIO {
    static func withRoot<T>(_ root: URL, body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = try SkillFileIO.directory(root.path)
        defer { close(descriptor) }
        return try body(descriptor)
    }

    static func withFolder<T>(
        _ id: String, hash: String, root: Int32, create: Bool, body: (Int32) throws -> T
    ) throws -> T {
        guard SkillParser.validName(id), hash.count == 64,
              hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SkillValidationError.unreadable }
        if create {
            try mkdir(id, parent: root)
        }
        let skill = try SkillFileIO.childDirectory(id, parent: root)
        defer { close(skill) }
        if create {
            try mkdir(hash, parent: skill)
        }
        let version = try SkillFileIO.childDirectory(hash, parent: skill)
        defer { close(version) }
        return try body(version)
    }

    static func write(_ data: Data, folder: Int32) throws {
        let temporary = UUID().uuidString
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SkillValidationError.unreadable }
        defer { close(descriptor); unlinkat(folder, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw SkillValidationError.unreadable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(folder, temporary, folder, "SKILL.md") == 0 else {
            throw SkillValidationError.unreadable
        }
    }

    static func remove(_ name: String, parent: Int32) throws {
        let info = try SkillFileIO.info(name, parent: parent)
        if SkillFileIO.kind(info) == S_IFDIR {
            let child = try SkillFileIO.childDirectory(name, parent: parent)
            defer { close(child) }
            for entry in try SkillFileIO.names(child) {
                try remove(entry, parent: child)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw SkillValidationError.unreadable }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw SkillValidationError.unreadable }
        }
    }

    private static func mkdir(_ name: String, parent: Int32) throws {
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw SkillValidationError.unreadable }
    }
}
