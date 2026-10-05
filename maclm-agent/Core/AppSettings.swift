import Foundation
import Observation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .automatic:
            String(localized: "Auto")
        case .light:
            String(localized: "Light")
        case .dark:
            String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let allowedDirectories = "allowed_dirs"
        static let theme = "appearance.theme"
        static let shortcut = "shortcuts.toggleMenuBar"
        static let clipboardActionShortcut = "shortcuts.clipboardActions"
        static let automaticallyPasteClipboardActionResults =
            "clipboardActions.automaticallyPasteResults"
    }

    var notifySessionCompletion: Bool {
        didSet {
            defaults.set(notifySessionCompletion, forKey: "notifications.completion")
            if notifySessionCompletion, !oldValue {
                SessionNotifications.requestPermission()
            }
        }
    }

    var notifySessionApproval: Bool {
        didSet {
            defaults.set(notifySessionApproval, forKey: "notifications.approval")
            if notifySessionApproval, !oldValue {
                SessionNotifications.requestPermission()
            }
        }
    }

    var interfaceLanguage: String {
        didSet {
            defaults.set(interfaceLanguage, forKey: "interface.language")
            if interfaceLanguage == "system" {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([interfaceLanguage], forKey: "AppleLanguages")
            }
        }
    }

    var auditRetentionDays: Int {
        didSet { defaults.set(auditRetentionDays, forKey: "security.auditRetentionDays") }
    }

    var allowedDirectories: [String] {
        didSet { defaults.set(allowedDirectories, forKey: Key.allowedDirectories) }
    }

    @discardableResult
    func addAllowedDirectory(_ path: String) -> Bool {
        let canonical = PathCanonicalizer.canonicalize(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let caseSensitive = PathCanonicalizer.isCaseSensitive(canonical)
        guard !allowedDirectories.contains(where: {
            let existing = PathCanonicalizer.canonicalize($0)
            return caseSensitive ? existing == canonical : existing.lowercased() == canonical.lowercased()
        }) else { return false }
        allowedDirectories.append(canonical)
        return true
    }

    func removeAllowedDirectory(at index: Int) {
        guard allowedDirectories.indices.contains(index) else { return }
        allowedDirectories.remove(at: index)
    }

    static func isBroadDirectory(_ path: String) -> Bool {
        let canonical = PathCanonicalizer.canonicalize(path)
        return canonical == "/" || canonical == PathCanonicalizer.canonicalize(NSHomeDirectory())
    }

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
        }
    }

    var shortcut: GlobalShortcut {
        didSet {
            guard let data = try? JSONEncoder().encode(shortcut) else {
                return
            }
            defaults.set(data, forKey: Key.shortcut)
        }
    }

    var clipboardActionShortcut: GlobalShortcut {
        didSet {
            guard let data = try? JSONEncoder().encode(clipboardActionShortcut) else {
                return
            }
            defaults.set(data, forKey: Key.clipboardActionShortcut)
        }
    }

    var automaticallyPasteClipboardActionResults: Bool {
        didSet {
            defaults.set(
                automaticallyPasteClipboardActionResults,
                forKey: Key.automaticallyPasteClipboardActionResults
            )
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifySessionCompletion = defaults.object(forKey: "notifications.completion") as? Bool ?? true
        notifySessionApproval = defaults.object(forKey: "notifications.approval") as? Bool ?? true
        interfaceLanguage = defaults.string(forKey: "interface.language") ?? "system"
        auditRetentionDays = defaults.object(forKey: "security.auditRetentionDays") as? Int ?? 90
        allowedDirectories = defaults.stringArray(forKey: Key.allowedDirectories) ?? []
        theme = defaults
            .string(forKey: Key.theme)
            .flatMap(AppTheme.init(rawValue:))
            ?? .automatic
        shortcut = defaults
            .data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) }
            ?? .defaultShortcut
        clipboardActionShortcut = defaults
            .data(forKey: Key.clipboardActionShortcut)
            .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) }
            ?? .defaultClipboardActionShortcut
        automaticallyPasteClipboardActionResults = defaults.object(
            forKey: Key.automaticallyPasteClipboardActionResults
        ) as? Bool ?? true
    }
}

extension AppSettings: ClipboardActionPreferences {}
