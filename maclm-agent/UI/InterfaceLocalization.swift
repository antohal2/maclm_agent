import Foundation

/// Rendering only: never apply this to messages, tool output or audit payloads.
enum InterfaceLocalization {
    static func text(_ value: String) -> String {
        value.components(separatedBy: "; ").map {
            NSLocalizedString($0, comment: "Interface display text")
        }.joined(separator: "; ")
    }
}

extension ClipboardAction {
    var interfaceName: String {
        guard isBuiltIn, let definition = DefaultClipboardActions.definitions.first(where: { $0.id == id }),
              name == definition.name else { return name }
        return InterfaceLocalization.text(name)
    }
}

extension Conversation {
    var interfaceTitle: String {
        title == Self.defaultTitle ? String(localized: "Новая беседа") : title
    }
}

extension AuditDecision {
    var interfaceLabel: String {
        self == .userInitiated ? String(localized: "Действие пользователя") : rawValue
    }
}
