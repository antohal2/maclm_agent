import Foundation

@MainActor
enum SessionOrdering {
    static func sorted(_ conversations: [Conversation], showingArchive: Bool = false) -> [Conversation] {
        conversations.filter { showingArchive || !$0.isArchived }.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum SystemPromptBuilder {
    /// The ordinary chat previously had no base system prompt.
    static func build(base: String = "", projectName: String? = nil, instructions: String = "") -> String {
        guard let projectName, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        let block = "Инструкции проекта «\(projectName)»:\n\(instructions)"
        return base.isEmpty ? block : base + "\n\n" + block
    }
}

enum ConversationTitle {
    static let prompt = "Придумай заголовок из 3–5 слов для этого диалога на языке диалога. "
        + "Ответь только заголовком, без кавычек и точки."

    static func clean(_ response: String) -> String {
        let withoutThinking = response.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "(?is)<think>.*$", with: "", options: .regularExpression)
        let lines = withoutThinking.split(whereSeparator: \.isNewline).map { raw in
            String(raw).replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "[*_`#\"'«»“”‘’]", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
        }
        let plain = lines.first(where: { !$0.isEmpty }) ?? ""
        return String(plain.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
    }

    static func fallback(_ content: String, limit: Int = 40) -> String {
        let normalized = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return Conversation.defaultTitle }
        guard normalized.count > limit else { return normalized }
        let prefix = String(normalized.prefix(limit))
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        if normalized[end].isWhitespace {
            return prefix + "…"
        }
        if let space = prefix.lastIndex(of: " ") {
            return String(prefix[..<space]) + "…"
        }
        return prefix + "…"
    }
}
