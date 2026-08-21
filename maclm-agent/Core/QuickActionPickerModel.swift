import Foundation
import Observation

@MainActor
@Observable
final class QuickActionPickerModel {
    enum NavigationDirection {
        case previous
        case next
    }

    private static let previewLimit = 80

    var query = "" {
        didSet {
            resetSelection()
        }
    }

    private(set) var actions: [ClipboardAction] = []
    private(set) var clipboardText = ""
    private(set) var selectedIndex: Int?
    private(set) var presentationID = UUID()

    var filteredActions: [ClipboardAction] {
        let enabledActions = actions
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
        guard !query.isEmpty else {
            return enabledActions
        }
        return enabledActions.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedAction: ClipboardAction? {
        guard let selectedIndex, filteredActions.indices.contains(selectedIndex) else {
            return nil
        }
        return filteredActions[selectedIndex]
    }

    var isClipboardEmpty: Bool {
        Self.normalizedClipboardText(clipboardText).isEmpty
    }

    var clipboardPreview: String {
        let normalized = Self.normalizedClipboardText(clipboardText)
        guard normalized.count > Self.previewLimit else {
            return normalized
        }
        return String(normalized.prefix(Self.previewLimit)) + "…"
    }

    func present(clipboardText: String?, actions: [ClipboardAction]) {
        self.clipboardText = clipboardText ?? ""
        self.actions = actions
        query = ""
        resetSelection()
        presentationID = UUID()
    }

    func moveSelection(_ direction: NavigationDirection) {
        let count = filteredActions.count
        guard count > 0 else {
            selectedIndex = nil
            return
        }

        switch direction {
        case .next:
            selectedIndex = ((selectedIndex ?? -1) + 1) % count
        case .previous:
            selectedIndex = ((selectedIndex ?? 0) - 1 + count) % count
        }
    }

    func action(forDigit digit: Int) -> ClipboardAction? {
        guard (1 ... 9).contains(digit) else {
            return nil
        }
        let index = digit - 1
        guard filteredActions.indices.contains(index) else {
            return nil
        }
        return filteredActions[index]
    }

    func select(action: ClipboardAction) {
        selectedIndex = filteredActions.firstIndex { $0.id == action.id }
    }

    private func resetSelection() {
        selectedIndex = filteredActions.isEmpty ? nil : 0
    }

    private static func normalizedClipboardText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
