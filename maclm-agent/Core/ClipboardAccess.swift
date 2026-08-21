import AppKit
import Foundation

@MainActor
protocol ClipboardAccess: AnyObject {
    func readString() throws -> String
    func writeString(_ string: String) throws
}

enum ClipboardAccessError: Error, Equatable, LocalizedError {
    case noText
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noText:
            "В буфере обмена нет текста."
        case .writeFailed:
            "Не удалось записать результат в буфер обмена."
        }
    }
}

@MainActor
final class SystemClipboard: ClipboardAccess {
    func readString() throws -> String {
        guard
            let string = NSPasteboard.general.string(forType: .string),
            !string.isEmpty
        else {
            throw ClipboardAccessError.noText
        }
        return string
    }

    func writeString(_ string: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else {
            throw ClipboardAccessError.writeFailed
        }
    }
}
