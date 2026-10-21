import Darwin
import Foundation

/// Every child is opened relative to a pinned directory descriptor, without following links.
/// This also rejects links introduced after enumeration, including intermediate directories.
enum SkillFileIO {
    static func directory(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        return descriptor
    }

    static func childDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        return descriptor
    }

    static func names(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw SkillValidationError.unreadable }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw SkillValidationError.unreadable
        }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer
                    .withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw SkillValidationError.unreadable }
            if name != ".", name != ".." {
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw SkillValidationError.unreadable }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func info(_ name: String, parent: Int32) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        return value
    }

    static func kind(_ value: stat) -> mode_t {
        value.st_mode & S_IFMT
    }

    static func readFile(_ file: SkillFile, root: Int32) throws -> Data {
        let parts = file.path.components(separatedBy: "/")
        guard let last = parts.last, !parts.contains(".."), !parts.contains(""),
              !parts.contains(where: SkillFilePolicy.isIgnored)
        else {
            throw SkillValidationError.unreadable
        }
        var parent = dup(root)
        guard parent >= 0 else { throw SkillValidationError.unreadable }
        defer { close(parent) }
        for component in parts.dropLast() {
            let next = try childDirectory(component, parent: parent)
            close(parent)
            parent = next
        }
        let descriptor = openat(parent, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, kind(before) == S_IFREG else {
            throw SkillValidationError.unsupportedFile
        }
        guard before.st_size == file.size else { throw SkillValidationError.changedDuringScan }
        let data = try readBytes(descriptor, expectedSize: file.size)
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == file.size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw SkillValidationError.changedDuringScan
        }
        return data
    }

    private static func readBytes(_ descriptor: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw SkillValidationError.unreadable }
            if count == 0 {
                break
            }
            guard data.count + count <= expectedSize else { throw SkillValidationError.changedDuringScan }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func failure() -> SkillValidationError {
        errno == ELOOP ? .symlink : .unreadable
    }
}
