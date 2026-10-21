import Foundation

struct SkillDraftFile: Sendable, Equatable, Identifiable {
    let path: String
    let content: String
    var id: String {
        path
    }

    var data: Data {
        Data(content.utf8)
    }

    var warnings: [SkillDraftWarning] {
        SkillDraftWarning.matches(content)
    }
}

enum SkillDraftWarning: String, Sendable, CaseIterable {
    case aws, openAI, github, slack, privateKey, jwt, assignment, personalPath

    private var pattern: String {
        switch self {
        case .aws: #"AKIA[0-9A-Z]{16}"#
        case .openAI: #"sk-[A-Za-z0-9]{20,}"#
        case .github: #"ghp_[A-Za-z0-9]{30,}"#
        case .slack: #"xox[baprs]-[A-Za-z0-9-]{10,}"#
        case .privateKey: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#
        case .jwt: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#
        case .assignment: #"(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{8,}"#
        case .personalPath: #"/Users/[^/\s]+/"#
        }
    }

    static func matches(_ text: String) -> [Self] {
        allCases.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }
    }

    var title: String {
        self == .personalPath ? String(localized: "Личный абсолютный путь")
            : String(localized: "Возможный секрет")
    }
}

struct SkillDraft: Sendable, Equatable {
    let name: String
    /// Includes the assembled SKILL.md as the first file; bytes here are the approved bytes.
    let files: [SkillDraftFile]
    var hash: String {
        SkillHasher.manifestHash(files.map {
            SkillFile(path: $0.path, size: $0.data.count, digest: SkillHasher.digest($0.data))
        })
    }

    var warningCount: Int {
        files.reduce(0) { $0 + $1.warnings.count }
    }

    static func parse(_ data: Data) throws -> Self {
        guard String(data: data, encoding: .utf8) != nil else {
            throw SkillDraftError(reason: "draft must be valid UTF-8")
        }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data) } catch {
            throw SkillDraftError(reason: "invalid JSON arguments for create_skill_draft")
        }
        guard let object = decoded as? [String: Any] else {
            throw SkillDraftError(reason: "draft arguments must be an object")
        }
        let name = try string("name", in: object)
        let description = try string("description", in: object)
        let instructions = try string("instructions", in: object)
        guard let extra = object["files"] as? [[String: Any]] else {
            throw SkillDraftError(
                reason: "files must be an array of {path, content} objects; use [] if none are needed"
            )
        }
        let text = try instructionText(name: name, description: description, instructions: instructions)
        let files = try supportingFiles(extra, instructions: text)
        return Self(name: name, files: files)
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw SkillDraftError(
                reason: "missing or non-string field: \(key). SKILL.md body belongs in instructions, not files"
            )
        }
        return value
    }

    private static func instructionText(name: String, description: String, instructions: String) throws -> String {
        guard SkillParser.validName(name)
        else { throw SkillDraftError(reason: "invalid skill name (a-z, 0-9, single hyphens; 1–64 bytes)") }
        guard
            (1 ... 1024).contains(description.count),
            !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SkillDraftError(reason: "description must contain 1–1024 characters")
        }
        try validateText(Data(description.utf8))
        // JSON-quoted scalars are supported by the existing strict parser.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = try encoder.encode(description)
        guard let scalar = String(data: encoded, encoding: .utf8) else {
            throw SkillDraftError(reason: "description must be UTF-8")
        }
        let text = "---\nname: \(name)\ndescription: \(scalar)\n---\n\(instructions)"
        guard text.utf8.count <= SkillScanner.maximumInstructions else {
            throw SkillDraftError(reason: "assembled SKILL.md exceeds 16 KB")
        }
        try validateText(Data(text.utf8))
        do { _ = try SkillParser.parse(Data(text.utf8), folderName: name) } catch {
            throw SkillDraftError(reason: "assembled SKILL.md violates parser rules: \(error)")
        }
        return text
    }

    private static func supportingFiles(
        _ extra: [[String: Any]],
        instructions text: String
    ) throws -> [SkillDraftFile] {
        guard extra.count <= 10 else { throw SkillDraftError(reason: "at most 10 supporting files are allowed") }
        var files = [SkillDraftFile(path: "SKILL.md", content: text)]
        var paths: Set = ["skill.md"]
        for file in extra {
            guard let path = file["path"] as? String, let content = file["content"] as? String else {
                throw SkillDraftError(reason: "each file needs string path and content")
            }
            do { try SkillFileIO.validateModelPath(path) } catch {
                throw SkillDraftError(reason: "invalid or hidden relative path: \(path)")
            }
            // Case/Unicode aliases are rejected on all volumes, including case-insensitive APFS.
            let key = path.precomposedStringWithCompatibilityMapping.lowercased()
            guard key != "skill.md" else {
                throw SkillDraftError(
                    reason: "files must not contain SKILL.md; put its body in instructions without frontmatter"
                )
            }
            guard paths.insert(key).inserted else { throw SkillDraftError(reason: "duplicate path: \(path)") }
            guard content.utf8.count <= SkillFileAccess.maximumReadSize else {
                throw SkillDraftError(reason: "supporting file exceeds 32 KB: \(path)")
            }
            try validateText(Data(content.utf8))
            files.append(.init(path: path, content: content))
        }
        try validateConflicts(files, paths: paths)
        guard
            files.count <= SkillScanner.maximumFiles,
            files.reduce(0, { $0 + $1.data.count }) <= SkillScanner.maximumSize
        else {
            throw SkillDraftError(reason: "skill exceeds scanner limits")
        }
        return files
    }

    private static func validateConflicts(_ files: [SkillDraftFile], paths: Set<String>) throws {
        for file in files {
            let parts = file.path.split(separator: "/")
            for length in 1 ..< parts.count {
                let parent = parts.prefix(length).joined(separator: "/").precomposedStringWithCompatibilityMapping
                    .lowercased()
                guard !paths.contains(parent)
                else { throw SkillDraftError(reason: "file/directory path conflict: \(file.path)") }
            }
        }
    }

    /// Model-facing failures are stable English text, independent of the UI locale.
    static func reason(_ error: Error) -> String {
        if let draft = error as? SkillDraftError {
            return draft.reason
        }
        if let access = error as? SkillFileAccessError {
            return access.rawValue
        }
        return "skill storage or audit persistence failed"
    }

    static func validateText(_ data: Data) throws {
        guard
            let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
            })
        else {
            throw SkillDraftError(reason: "files must be UTF-8 text, not binary (CR, LF and tab are allowed)")
        }
    }
}

struct SkillDraftError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? {
        reason
    }
}
