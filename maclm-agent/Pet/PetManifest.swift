import Foundation

struct PetManifest: Codable {
    struct Row: Codable {
        let row: Int
        let state: PetState
        let frames: Int
        let fps: Int
        let loop: Bool
    }

    let version: Int
    let id: String
    let name: String
    let frameSize: Int
    let columns: Int
    let rows: [Row]
    let reduceMotionFrame: Int

    func validate() throws {
        guard version == 1 else { throw PetValidationError.version }
        guard id.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil,
              id.utf8.allSatisfy({ $0 == 45 || (48 ... 57).contains($0) || (97 ... 122).contains($0) })
        else { throw PetValidationError.identifier }
        guard (1 ... 40).contains(name.count) else { throw PetValidationError.name }
        guard frameSize == 64 else { throw PetValidationError.frameSize }
        guard (1 ... 16).contains(columns) else { throw PetValidationError.columns }
        guard Set(rows.map(\.state)).count == rows.count else { throw PetValidationError.duplicateState }
        guard Set(rows.map(\.row)).count == rows.count else { throw PetValidationError.duplicateRow }
        guard rows.contains(where: { $0.state == .idle }) else { throw PetValidationError.missingIdle }
        try validateRows()
    }

    private func validateRows() throws {
        for row in rows {
            // Reject negative indexes and arithmetic overflow before inspecting the image.
            guard (0 ..< Int.max / 64).contains(row.row) else { throw PetValidationError.rowIndex }
            guard (1 ... columns).contains(row.frames) else { throw PetValidationError.frames }
            guard (1 ... 30).contains(row.fps) else { throw PetValidationError.fps }
            guard (0 ..< row.frames).contains(reduceMotionFrame) else { throw PetValidationError.reduceMotionFrame }
        }
    }
}

enum PetValidationError: String, Error, LocalizedError {
    case manifestSize, manifestJSON, version, identifier, name, frameSize, columns
    case duplicateState, duplicateRow, missingIdle, rowIndex, frames, fps, reduceMotionFrame
    case imageSize, imageType, imageDimensions, imageDecode

    var errorDescription: String? {
        switch self {
        case .manifestSize: String(localized: "Манифест питомца превышает 64 КБ")
        case .manifestJSON: String(localized: "Некорректный JSON питомца или неизвестное состояние")
        case .version: String(localized: "Версия питомца должна быть 1")
        case .identifier: String(localized: "Некорректный идентификатор питомца")
        case .name: String(localized: "Имя питомца должно содержать от 1 до 40 символов")
        case .frameSize: String(localized: "Размер кадра питомца должен быть 64")
        case .columns: String(localized: "Число столбцов питомца должно быть от 1 до 16")
        case .duplicateState: String(localized: "Состояния питомца повторяются")
        case .duplicateRow: String(localized: "Строки питомца повторяются")
        case .missingIdle: String(localized: "У питомца отсутствует состояние idle")
        case .rowIndex: String(localized: "Некорректный индекс строки питомца")
        case .frames: String(localized: "Число кадров питомца выходит за пределы столбцов")
        case .fps: String(localized: "Частота кадров питомца должна быть от 1 до 30")
        case .reduceMotionFrame: String(localized: "Статичный кадр питомца отсутствует в одной из строк")
        case .imageSize: String(localized: "Спрайт питомца превышает 8 МБ")
        case .imageType: String(localized: "Спрайт питомца должен быть PNG по содержимому")
        case .imageDimensions: String(localized: "Размеры спрайта питомца не соответствуют манифесту")
        case .imageDecode: String(localized: "Не удалось декодировать кадры питомца")
        }
    }
}
