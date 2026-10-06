import Darwin
import Foundation

enum PetStorageError: Error, LocalizedError {
    case symbolicLink, regularFile, missing, permission, space, io, reserved, replacementRequired, limit, mismatch

    static func posix(_ code: Int32) -> Self {
        NSLog("Pet filesystem failure errno=%d (%s)", code, strerror(code))
        return switch code {
        case ELOOP: .symbolicLink
        case ENOENT: .missing
        case EACCES, EPERM: .permission
        case ENOSPC, EDQUOT: .space
        case ENOTDIR, EISDIR: .regularFile
        default: .io
        }
    }

    var errorDescription: String? {
        switch self {
        case .symbolicLink: String(localized: "Символические ссылки в питомце запрещены")
        case .regularFile: String(localized: "Для питомца нужны обычные файлы и настоящая папка")
        case .missing: String(localized: "Папка питомца или обязательный файл отсутствует")
        case .permission: String(localized: "Нет доступа к файлам питомца")
        case .space: String(localized: "Недостаточно места для установки питомца")
        case .io: String(localized: "Не удалось прочитать или сохранить файлы питомца")
        case .reserved: String(localized: "Идентификатор bronya зарезервирован для встроенного питомца")
        case .replacementRequired: String(localized: "Питомец уже установлен. Требуется подтверждение замены")
        case .limit: String(localized: "Можно установить не больше 50 питомцев")
        case .mismatch: String(localized: "Идентификатор питомца не совпадает с именем папки")
        }
    }

    static func message(_ error: Error) -> String {
        NSLog("Pet storage rejected operation: %@", String(reflecting: error))
        return (error as? PetValidationError)?.errorDescription
            ?? (error as? Self)?.errorDescription
            ?? posix((error as NSError).code == NSFileWriteOutOfSpaceError ? ENOSPC : EIO).errorDescription!
    }
}
