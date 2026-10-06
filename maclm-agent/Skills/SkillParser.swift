import Foundation

struct ParsedSkill: Sendable {
    var name: String
    var description: String
    var body: String
}

enum SkillParser {
    static func parse(_ data: Data, folderName: String) throws -> ParsedSkill {
        guard var text = String(data: data, encoding: .utf8) else { throw SkillValidationError.invalidUTF8 }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let rawLines = text.components(separatedBy: "\n")
        let lines = rawLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first == "---" else { throw SkillValidationError.missingFrontmatter }
        guard let end = lines.dropFirst().firstIndex(of: "---") else {
            throw SkillValidationError.malformedFrontmatter
        }
        guard rawLines[0 ... end].joined(separator: "\n").utf8.count <= 4096 else {
            throw SkillValidationError.frontmatterTooLarge
        }
        var reader = FrontmatterReader(lines: Array(lines[1 ..< end]))
        let fields = try reader.fields()
        let (name, description) = try validated(fields, folderName: folderName)
        return ParsedSkill(name: name, description: description, body: lines.dropFirst(end + 1).joined(separator: "\n"))
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && !name.hasPrefix("-") && !name.hasSuffix("-")
            && !name.contains("--") && name.utf8.allSatisfy {
                (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45
            }
    }

    private static func validated(_ fields: [String: String], folderName: String) throws -> (String, String) {
        guard let name = fields["name"], !name.isEmpty else { throw SkillValidationError.missingName }
        guard validName(name) else { throw SkillValidationError.invalidName }
        guard name == folderName else { throw SkillValidationError.nameMismatch }
        guard let description = fields["description"],
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SkillValidationError.missingDescription }
        guard description.count <= 1024 else { throw SkillValidationError.descriptionTooLong }
        return (name, description)
    }
}

private struct FrontmatterReader {
    let lines: [String]
    var index = 0
    var ignoredKey = false

    mutating func fields() throws -> [String: String] {
        var result: [String: String] = [:]
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Only ignored keys may have nested values; known scalars are strictly single-line.
                guard ignoredKey else { throw SkillValidationError.malformedFrontmatter }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw SkillValidationError.malformedFrontmatter }
            let key = String(line[..<colon])
            ignoredKey = key != "name" && key != "description"
            if ignoredKey {
                continue
            }
            guard result[key] == nil else { throw SkillValidationError.malformedFrontmatter }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = try field(value, key: key)
        }
        return result
    }

    private mutating func field(_ value: String, key: String) throws -> String {
        if value == "|" || value == ">" {
            guard key == "description" else { throw SkillValidationError.malformedFrontmatter }
            let block = try blockLines()
            return value == "|" ? block.joined(separator: "\n") : fold(block)
        }
        return try scalar(value)
    }

    private mutating func blockLines() throws -> [String] {
        var block: [String] = []
        var indentation: Int?
        while index < lines.count {
            let next = lines[index]
            if next.isEmpty {
                block.append(""); index += 1; continue
            }
            let spaces = next.prefix { $0 == " " }.count
            guard spaces > 0 else { break }
            let width = indentation ?? spaces
            indentation = width
            guard spaces >= width else { throw SkillValidationError.malformedFrontmatter }
            block.append(String(next.dropFirst(width)))
            index += 1
        }
        return block
    }

    private func scalar(_ value: String) throws -> String {
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
            else { throw SkillValidationError.malformedFrontmatter }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { throw SkillValidationError.malformedFrontmatter }
            let inner = String(value.dropFirst().dropLast())
            guard !inner.replacingOccurrences(of: "''", with: "").contains("'") else {
                throw SkillValidationError.malformedFrontmatter
            }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        let unsupported = ["[", "{", "&", "*", "!", "|", ">"]
        guard !value.contains("\0"), !unsupported.contains(where: { value.hasPrefix($0) }) else {
            throw SkillValidationError.malformedFrontmatter
        }
        return value
    }

    private func fold(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += line.isEmpty || lines[index - 1].isEmpty ? "\n" : " "
            }
            result += line
        }
        return result
    }
}
