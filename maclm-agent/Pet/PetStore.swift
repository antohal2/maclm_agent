import Darwin
import Foundation

struct PetImport {
    let sprite: PetSprite
    fileprivate let json: Data
    fileprivate let png: Data
}

struct PetEntry: Identifiable {
    let id: String
    let sprite: PetSprite?
    let problem: String?
    var name: String {
        sprite?.manifest.name ?? id
    }

    var selectable: Bool {
        sprite != nil && problem == nil
    }
}

struct PetStore {
    let root: URL

    func prepare(source: URL) throws -> PetImport {
        let directory = try PetFileAccess.directory(source)
        defer { close(directory) }
        let json = try PetFileAccess.read("pet.json", parent: directory, limit: 64 * 1024, oversized: .manifestSize)
        let png = try PetFileAccess.read(
            "spritesheet.png", parent: directory, limit: 8 * 1024 * 1024, oversized: .imageSize
        )
        let sprite = try PetLoader.load(manifestData: json, imageData: png)
        try customIdentifier(sprite.manifest.id)
        return PetImport(sprite: sprite, json: json, png: png)
    }

    func entries() throws -> [PetEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directory = try PetFileAccess.directory(root)
        defer { close(directory) }
        return try PetFileAccess.names(parent: directory).compactMap { name in
            let metadata = try PetFileAccess.metadata(name, parent: directory)
            guard metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_mode & S_IFMT == S_IFLNK else { return nil }
            do {
                let sprite = try load(name, parent: directory)
                return PetEntry(id: name, sprite: sprite, problem: nil)
            } catch {
                return PetEntry(id: name, sprite: nil, problem: PetStorageError.message(error))
            }
        }
    }

    func load(_ id: String) throws -> PetSprite {
        try customIdentifier(id)
        let directory = try PetFileAccess.directory(root)
        defer { close(directory) }
        return try load(id, parent: directory)
    }

    func existingID(for id: String) throws -> String? {
        try customIdentifier(id)
        return try entries().first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.id
    }

    /// RENAME_SWAP makes replacement one atomic operation: old data remains installed until validation succeeds.
    func install(
        _ imported: PetImport, replacing: Bool = false,
        beforeValidation: ((URL) throws -> Void)? = nil
    ) throws {
        let id = imported.sprite.manifest.id
        try customIdentifier(id)
        let directory = try PetFileAccess.directory(root, create: true)
        defer { close(directory) }
        let names = try PetFileAccess.names(parent: directory)
        let existing = names.first { $0.caseInsensitiveCompare(id) == .orderedSame }
        if existing != nil, !replacing {
            throw PetStorageError.replacementRequired
        }
        let count = try names.filter {
            let mode = try PetFileAccess.metadata($0, parent: directory).st_mode & S_IFMT
            return mode == S_IFDIR || mode == S_IFLNK
        }.count
        guard existing != nil || count < 50 else { throw PetStorageError.limit }
        let temporary = ".import-" + UUID().uuidString
        guard mkdirat(directory, temporary, 0o700) == 0 else { throw PetStorageError.posix(errno) }
        defer {
            do { try PetFileAccess.remove(temporary, parent: directory) } catch {
                if error as? PetStorageError != .missing {
                    NSLog("Pet staging cleanup failed: %@", String(reflecting: error))
                }
            }
        }
        let staging = try PetFileAccess.childDirectory(temporary, parent: directory)
        defer { close(staging) }
        try PetFileAccess.write(imported.json, name: "pet.json", parent: staging)
        try PetFileAccess.write(imported.png, name: "spritesheet.png", parent: staging)
        try beforeValidation?(root.appendingPathComponent(temporary))
        let copy = try loadFiles(parent: staging)
        guard copy.manifest.id == id else { throw PetStorageError.mismatch }
        let target = existing ?? id
        try customIdentifier(target)
        let flags = existing == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(directory, temporary, directory, target, flags) == 0 else {
            throw PetStorageError.posix(errno)
        }
    }

    func delete(_ id: String) throws {
        try customIdentifier(id)
        let directory = try PetFileAccess.directory(root)
        defer { close(directory) }
        try PetFileAccess.remove(id, parent: directory)
    }

    private func customIdentifier(_ id: String) throws {
        if id.caseInsensitiveCompare("bronya") == .orderedSame {
            throw PetStorageError.reserved
        }
        try PetManifest.validateIdentifier(id)
    }

    private func load(_ id: String, parent: Int32) throws -> PetSprite {
        try customIdentifier(id)
        let directory = try PetFileAccess.childDirectory(id, parent: parent)
        defer { close(directory) }
        let sprite = try loadFiles(parent: directory)
        guard sprite.manifest.id == id else { throw PetStorageError.mismatch }
        return sprite
    }

    private func loadFiles(parent: Int32) throws -> PetSprite {
        try PetLoader.load(
            manifestData: PetFileAccess.read("pet.json", parent: parent, limit: 64 * 1024, oversized: .manifestSize),
            imageData: PetFileAccess.read(
                "spritesheet.png", parent: parent, limit: 8 * 1024 * 1024, oversized: .imageSize
            )
        )
    }
}
