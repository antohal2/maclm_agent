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
            "Auto"
        case .light:
            "Light"
        case .dark:
            "Dark"
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

    var allowedDirectories: [String] {
        didSet { defaults.set(allowedDirectories, forKey: Key.allowedDirectories) }
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
