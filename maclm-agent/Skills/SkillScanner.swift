import CryptoKit
import Darwin
import Foundation

enum SkillHasher {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func manifestHash(_ files: [SkillFile]) -> String {
        var manifest = Data()
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            // Byte length makes paths containing newlines or separators unambiguous.
            manifest.append(contentsOf: "\(file.path.utf8.count):\(file.path)\0\(file.digest)\n".utf8)
        }
        return digest(manifest)
    }
}

enum SkillScanner {
    static let maximumFiles = 200
    static let maximumSize = 5 * 1024 * 1024
    static let maximumInstructions = 16 * 1024

    static func scan(root: URL) throws -> [SkillSnapshot] {
        let descriptor = try SkillFileIO.directory(root.path)
        defer { close(descriptor) }
        return try SkillFileIO.names(descriptor).compactMap { name in
            let info = try SkillFileIO.info(name, parent: descriptor)
            let kind = SkillFileIO.kind(info)
            guard kind == S_IFDIR || kind == S_IFLNK else { return nil }
            return scan(name: name, parent: descriptor)
        }
    }

    static func scanSkill(at url: URL) -> SkillSnapshot {
        do {
            let parent = try SkillFileIO.directory(url.deletingLastPathComponent().path)
            defer { close(parent) }
            return scan(name: url.lastPathComponent, parent: parent)
        } catch {
            return SkillSnapshot(id: url.lastPathComponent, state: .invalid, problem: .unreadable)
        }
    }

    private static func scan(name: String, parent: Int32) -> SkillSnapshot {
        var snapshot = SkillSnapshot(id: name)
        do {
            guard try SkillFileIO.kind(SkillFileIO.info(name, parent: parent)) != S_IFLNK else {
                throw SkillValidationError.symlink
            }
            let descriptor = try SkillFileIO.childDirectory(name, parent: parent)
            defer { close(descriptor) }
            var files: [SkillFile] = []
            var total = 0
            try enumerate(descriptor, prefix: "", files: &files, total: &total)
            snapshot.files = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            snapshot.size = total
            guard let instruction = files.first(where: { $0.path == "SKILL.md" }) else {
                throw SkillValidationError.missingInstructions
            }
            guard instruction.size <= maximumInstructions else { throw SkillValidationError.instructionsTooLarge }
            var skillData = Data()
            for index in snapshot.files.indices {
                let data = try SkillFileIO.readFile(snapshot.files[index], root: descriptor)
                snapshot.files[index].digest = SkillHasher.digest(data)
                if snapshot.files[index].path == "SKILL.md" {
                    skillData = data
                }
            }
            snapshot.text = String(data: skillData, encoding: .utf8) ?? ""
            let parsed = try SkillParser.parse(skillData, folderName: name)
            snapshot.description = parsed.description
            snapshot.hash = SkillHasher.manifestHash(snapshot.files)
            snapshot.largeInstructionWarning = instruction.size >= 8 * 1024
        } catch {
            snapshot.state = .invalid
            snapshot.problem = error as? SkillValidationError ?? .unreadable
        }
        return snapshot
    }

    private static func enumerate(
        _ directory: Int32, prefix: String, files: inout [SkillFile], total: inout Int
    ) throws {
        for name in try SkillFileIO.names(directory) {
            let info = try SkillFileIO.info(name, parent: directory)
            let path = prefix + name
            switch SkillFileIO.kind(info) {
            case S_IFLNK: throw SkillValidationError.symlink
            case S_IFDIR:
                let child = try SkillFileIO.childDirectory(name, parent: directory)
                defer { close(child) }
                try enumerate(child, prefix: path + "/", files: &files, total: &total)
            case S_IFREG:
                guard files.count < maximumFiles else { throw SkillValidationError.tooManyFiles }
                guard info.st_size >= 0, info.st_size <= maximumSize - total else {
                    throw SkillValidationError.folderTooLarge
                }
                let size = Int(info.st_size)
                total += size
                files.append(SkillFile(path: path, size: size))
            default: throw SkillValidationError.unsupportedFile
            }
        }
    }
}
