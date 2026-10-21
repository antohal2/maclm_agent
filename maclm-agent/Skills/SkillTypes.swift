import Foundation
import SwiftData

enum SkillState: String, Sendable, CaseIterable {
    case invalid, disabled, enabled, needsReconfirm

    var displayName: String {
        switch self {
        case .invalid: String(localized: "Невалидный навык")
        case .disabled: String(localized: "Навык выключен")
        case .enabled: String(localized: "Навык включён")
        case .needsReconfirm: String(localized: "Нужно подтвердить навык заново")
        }
    }
}

@Model final class SkillRecord {
    @Attribute(.unique) var skillID: String = ""
    var source: String = "appFolder"
    var stateRaw: String = SkillState.disabled.rawValue
    var enabledHash: String?
    var enabledAt: Date?
    var lastUsedAt: Date?
    var origin: String = "manual"

    init(skillID: String) {
        self.skillID = skillID
    }

    var state: SkillState {
        get { SkillState(rawValue: stateRaw) ?? .invalid }
        set { stateRaw = newValue.rawValue }
    }
}

struct SkillFile: Sendable, Equatable, Identifiable {
    var path: String
    var size: Int
    var digest: String = ""
    var id: String {
        path
    }
}

struct SkillSnapshot: Sendable, Identifiable {
    var id: String
    var description = ""
    var text = ""
    var body = ""
    var files: [SkillFile] = []
    var size = 0
    var hash: String?
    var state: SkillState = .disabled
    var enabledHash: String?
    var source = "appFolder"
    var problem: SkillValidationError?
    var largeInstructionWarning = false
    var lastUsedAt: Date?
    var catalogDescription: String {
        description.count > 250 ? String(description.prefix(250)) + "…" : description
    }
}

enum SkillValidationError: Error, Sendable, LocalizedError, Equatable {
    case missingFrontmatter, malformedFrontmatter, frontmatterTooLarge, missingName, missingDescription
    case invalidName, nameMismatch, descriptionTooLong, invalidUTF8, symlink, unsupportedFile
    case tooManyFiles, folderTooLarge, instructionsTooLarge, missingInstructions, unreadable
    case changedDuringScan, unavailable, reconfirmRequired, changedSincePreview

    var errorDescription: String? {
        switch self {
        case .missingFrontmatter: String(localized: "SKILL.md должен начинаться с frontmatter между строками ---.")
        case .malformedFrontmatter: String(localized: "Некорректный frontmatter навыка.")
        case .frontmatterTooLarge: String(localized: "Frontmatter превышает 4 КиБ.")
        case .missingName: String(localized: "В frontmatter отсутствует name.")
        case .missingDescription: String(localized: "В frontmatter отсутствует description.")
        case .invalidName:
            String(localized:
                "Имя навыка не соответствует формату a-z, 0-9 и одиночных дефисов (1–64 символа)."
            )
        case .nameMismatch: String(localized: "Имя навыка должно совпадать с именем папки.")
        case .descriptionTooLong: String(localized: "Описание навыка превышает 1024 символа.")
        case .invalidUTF8: String(localized: "SKILL.md должен содержать корректный текст UTF-8.")
        case .symlink: String(localized: "Символические ссылки в папке навыка запрещены.")
        case .unsupportedFile: String(localized: "В навыке разрешены только папки и обычные файлы.")
        case .tooManyFiles: String(localized: "Папка навыка содержит больше 200 файлов.")
        case .folderTooLarge: String(localized: "Размер папки навыка превышает 5 МиБ.")
        case .instructionsTooLarge: String(localized: "SKILL.md превышает 16 КиБ.")
        case .missingInstructions: String(localized: "В папке навыка отсутствует SKILL.md.")
        case .unreadable: String(localized: "Не удалось прочитать папку навыка. Проверьте доступ к файлам.")
        case .changedDuringScan: String(localized: "Файлы изменились во время сканирования. Повторите проверку.")
        case .unavailable: String(localized: "Навык недоступен.")
        case .reconfirmRequired: String(localized: "Изменённый навык требует отдельного подтверждения.")
        case .changedSincePreview:
            String(localized:
                "Навык изменился после предпросмотра. Пересканируйте и подтвердите заново."
            )
        }
    }
}
