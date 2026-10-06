import Darwin
import Foundation

enum PetFileAccess {
    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PetStorageError.posix(errno) }
        return descriptor
    }

    static func childDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PetStorageError.posix(errno) }
        return descriptor
    }

    static func read(
        _ name: String, parent: Int32, limit: Int, oversized: PetValidationError,
        afterOpen: ((Int32) throws -> Void)? = nil
    ) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PetStorageError.posix(errno) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw PetStorageError.posix(errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw PetStorageError.regularFile }
        guard metadata.st_size <= limit else { throw oversized }
        try afterOpen?(descriptor)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while result.count <= limit {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw PetStorageError.posix(errno)
            }
            if count == 0 {
                return result
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw oversized
    }

    static func names(parent: Int32) throws -> [String] {
        let duplicate = dup(parent)
        guard duplicate >= 0 else { throw PetStorageError.posix(errno) }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw PetStorageError.posix(errno)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if !name.hasPrefix(".") {
                names.append(name)
            }
        }
        return names.sorted()
    }

    static func metadata(_ name: String, parent: Int32) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PetStorageError.posix(errno)
        }
        return value
    }

    static func write(_ data: Data, name: String, parent: Int32) throws {
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PetStorageError.posix(errno) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw PetStorageError.posix(errno)
                }
                guard count > 0 else { throw PetStorageError.io }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw PetStorageError.posix(errno) }
    }

    /// Unlinks links themselves; recursion is anchored to opened directories, never link targets.
    static func remove(_ name: String, parent: Int32) throws {
        let metadata = try metadata(name, parent: parent)
        if metadata.st_mode & S_IFMT == S_IFDIR {
            let child = try childDirectory(name, parent: parent)
            defer { close(child) }
            // Include hidden children when removing an installed folder.
            let streamFD = dup(child)
            guard let stream = fdopendir(streamFD) else {
                close(streamFD)
                throw PetStorageError.posix(errno)
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let nested = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if nested != ".", nested != ".." {
                    try remove(nested, parent: child)
                }
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw PetStorageError.posix(errno) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw PetStorageError.posix(errno) }
        }
    }
}
