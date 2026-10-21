import Darwin
import Foundation

/// All writes stay in a private sibling directory until an exclusive atomic rename.
enum SkillDraftIO {
    static func write(
        _ draft: SkillDraft, root: URL, staging: URL,
        afterFile: (Int) throws -> Void = { _ in }, beforeRename: () throws -> Void = {}
    ) throws {
        guard SkillParser.validName(draft.name) else { throw SkillValidationError.invalidName }
        try SkillSnapshotIO.withRoot(root) { destination in
            try SkillSnapshotIO.withRoot(staging) { parent in
                let temporary = UUID().uuidString
                guard mkdirat(parent, temporary, 0o700) == 0 else { throw SkillValidationError.unreadable }
                var committed = false
                defer {
                    if !committed {
                        do { try SkillSnapshotIO.remove(temporary, parent: parent) } catch {
                            NSLog("Skill staging cleanup failed: %@", String(describing: error))
                        }
                    }
                }
                let folder = try SkillFileIO.childDirectory(temporary, parent: parent)
                defer { close(folder) }
                for (index, file) in draft.files.enumerated() {
                    try Task.checkCancellation()
                    try write(file, root: folder)
                    try afterFile(index)
                }
                guard fsync(folder) == 0 else { throw SkillValidationError.unreadable }
                try beforeRename()
                try Task.checkCancellation()
                guard renameatx_np(parent, temporary, destination, draft.name, UInt32(RENAME_EXCL)) == 0 else {
                    throw SkillDraftError(reason: errno == EEXIST ? "skill name already exists; nothing replaced"
                        : "exclusive skill rename failed")
                }
                committed = true
                guard fsync(destination) == 0, fsync(parent) == 0 else {
                    // Only our just-created folder can be removed here; never replace another name.
                    try SkillSnapshotIO.remove(draft.name, parent: destination)
                    throw SkillValidationError.unreadable
                }
            }
        }
    }

    private static func write(_ file: SkillDraftFile, root: Int32) throws {
        try SkillFileIO.validateModelPath(file.path)
        let parts = file.path.components(separatedBy: "/")
        guard let name = parts.last else { throw SkillValidationError.unreadable }
        var parent = dup(root)
        guard parent >= 0 else { throw SkillValidationError.unreadable }
        defer { close(parent) }
        for part in parts.dropLast() {
            guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw SkillValidationError.unreadable }
            let child = try SkillFileIO.childDirectory(part, parent: parent)
            guard fsync(parent) == 0 else { close(child); throw SkillValidationError.unreadable }
            close(parent)
            parent = child
        }
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SkillValidationError.unreadable }
        defer { close(descriptor) }
        try file.data.withUnsafeBytes { buffer in
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
        guard fsync(descriptor) == 0, fsync(parent) == 0 else { throw SkillValidationError.unreadable }
    }

    static func cleanup(_ staging: URL) throws {
        // Do not create directories at startup when there is nothing to clean.
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        let parent = try SkillFileIO.directory(staging.path)
        defer { close(parent) }
        for name in try SkillFileIO.names(parent) {
            try SkillSnapshotIO.remove(name, parent: parent)
        }
    }
}
