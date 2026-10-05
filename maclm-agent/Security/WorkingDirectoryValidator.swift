import Foundation

enum WorkingDirectoryValidation: Equatable {
    case valid(String)
    case requiresConfirmation(String)
    case invalid(String)
}

enum WorkingDirectoryValidator {
    static func validate(_ path: String, home: String = NSHomeDirectory()) -> WorkingDirectoryValidation {
        guard path.hasPrefix("/"), !path.contains("\u{0000}") else {
            return .invalid("Укажите абсолютный путь к папке.")
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard canonical != "/" else { return .invalid("Корневая папка запрещена.") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            return .invalid("Папка не существует или путь указывает на файл.")
        }
        let sensitive = [home, "/System", "/Library", "/usr", "/bin", "/sbin", "/private"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return sensitive.contains(canonical) ? .requiresConfirmation(canonical) : .valid(canonical)
    }
}
