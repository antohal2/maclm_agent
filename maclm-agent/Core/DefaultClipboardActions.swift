import Foundation

enum DefaultClipboardActions {
    struct Definition: Equatable, Sendable {
        let id: UUID
        let name: String
        let promptTemplate: String
        let iconSystemName: String
        let sortOrder: Int
        let isEnabled: Bool
        let isBuiltIn: Bool

        init(
            id: UUID,
            name: String,
            promptTemplate: String,
            iconSystemName: String,
            sortOrder: Int,
            isEnabled: Bool = true,
            isBuiltIn: Bool = true
        ) {
            self.id = id
            self.name = name
            self.promptTemplate = promptTemplate
            self.iconSystemName = iconSystemName
            self.sortOrder = sortOrder
            self.isEnabled = isEnabled
            self.isBuiltIn = isBuiltIn
        }
    }

    static let definitions: [Definition] = [
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            name: "Перевести",
            promptTemplate: "Определи язык текста. Если текст на русском — переведи на английский. "
                + "Если на любом другом языке — переведи на русский. Верни ТОЛЬКО перевод, "
                + "без пояснений, без кавычек, без вступлений.\n\n{{input}}",
            iconSystemName: "globe",
            sortOrder: 100
        ),
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
            name: "Улучшить текст",
            promptTemplate: "Исправь грамматику, орфографию и пунктуацию, улучши формулировки. "
                + "Сохрани исходный смысл, язык и регистр общения. Верни ТОЛЬКО исправленный текст, "
                + "без пояснений и без списка правок.\n\n{{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: 200
        ),
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)),
            name: "Саммари",
            promptTemplate: "Сожми текст до не более 30% исходного объёма, сохранив все ключевые факты "
                + "и выводы. Пиши на языке оригинала. Верни ТОЛЬКО саммари.\n\n{{input}}",
            iconSystemName: "text.append",
            sortOrder: 300
        ),
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4)),
            name: "Объяснить",
            promptTemplate: "Объясни простым языком, что это. Это может быть код, технический термин, "
                + "регулярное выражение или фрагмент текста. Будь краток и конкретен. "
                + "Отвечай на языке оригинала.\n\n{{input}}",
            iconSystemName: "questionmark.circle",
            sortOrder: 400
        ),
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5)),
            name: "Формальный тон",
            promptTemplate: "Перепиши текст в формальном деловом стиле, пригодном для рабочей переписки. "
                + "Сохрани смысл и язык оригинала. Верни ТОЛЬКО переписанный текст.\n\n{{input}}",
            iconSystemName: "briefcase",
            sortOrder: 500
        ),
        Definition(
            id: UUID(uuid: (0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6)),
            name: "Неформальный тон",
            promptTemplate: "Перепиши текст в дружелюбном разговорном стиле. Сохрани смысл и язык оригинала. "
                + "Верни ТОЛЬКО переписанный текст.\n\n{{input}}",
            iconSystemName: "bubble.left.and.bubble.right",
            sortOrder: 600
        ),
    ]
}
