@testable import maclm_agent
import XCTest

final class QuickActionPickerModelTests: XCTestCase {
    @MainActor
    func testFilteringIncludesEnabledActionsInSortOrder() {
        let model = QuickActionPickerModel()
        let actions = [
            makeAction(name: "Саммари", order: 300),
            makeAction(name: "Скрытое саммари", order: 50, isEnabled: false),
            makeAction(name: "Перевести", order: 100),
            makeAction(name: "Улучшить текст", order: 200),
        ]

        model.present(clipboardText: "Текст", actions: actions)
        XCTAssertEqual(
            model.filteredActions.map(\.name),
            ["Перевести", "Улучшить текст", "Саммари"]
        )

        model.query = "ТЕКСТ"
        XCTAssertEqual(model.filteredActions.map(\.name), ["Улучшить текст"])

        model.query = "нет совпадений"
        XCTAssertTrue(model.filteredActions.isEmpty)
    }

    @MainActor
    func testDisabledActionsNeverAppearInSearch() {
        let model = QuickActionPickerModel()
        model.present(
            clipboardText: "Текст",
            actions: [makeAction(name: "Секретное", order: 100, isEnabled: false)]
        )

        XCTAssertTrue(model.filteredActions.isEmpty)
        model.query = "Секрет"
        XCTAssertTrue(model.filteredActions.isEmpty)
    }

    @MainActor
    func testNavigationWrapsAndDoesNothingForEmptyList() {
        let model = QuickActionPickerModel()
        let actions = [
            makeAction(name: "Первое", order: 100),
            makeAction(name: "Второе", order: 200),
        ]
        model.present(clipboardText: "Текст", actions: actions)

        XCTAssertEqual(model.selectedAction?.name, "Первое")
        model.moveSelection(.previous)
        XCTAssertEqual(model.selectedAction?.name, "Второе")
        model.moveSelection(.next)
        XCTAssertEqual(model.selectedAction?.name, "Первое")
        model.moveSelection(.next)
        model.moveSelection(.next)
        XCTAssertEqual(model.selectedAction?.name, "Первое")

        model.query = "нет"
        model.moveSelection(.next)
        model.moveSelection(.previous)
        XCTAssertNil(model.selectedAction)
    }

    @MainActor
    func testFilteringResetsSelectionToFirstMatch() {
        let model = QuickActionPickerModel()
        model.present(
            clipboardText: "Текст",
            actions: [
                makeAction(name: "Перевести", order: 100),
                makeAction(name: "Формальный тон", order: 200),
                makeAction(name: "Неформальный тон", order: 300),
            ]
        )
        model.moveSelection(.next)
        XCTAssertEqual(model.selectedAction?.name, "Формальный тон")

        model.query = "тон"

        XCTAssertEqual(model.selectedAction?.name, "Формальный тон")
        XCTAssertEqual(model.selectedIndex, 0)
    }

    @MainActor
    func testDigitSelectsCurrentFilteredItemAndIgnoresOutOfRange() {
        let model = QuickActionPickerModel()
        model.present(
            clipboardText: "Текст",
            actions: [
                makeAction(name: "Перевести", order: 100),
                makeAction(name: "Формальный тон", order: 200),
                makeAction(name: "Неформальный тон", order: 300),
            ]
        )
        model.query = "тон"

        XCTAssertEqual(model.action(forDigit: 1)?.name, "Формальный тон")
        XCTAssertEqual(model.action(forDigit: 2)?.name, "Неформальный тон")
        XCTAssertNil(model.action(forDigit: 3))
        XCTAssertNil(model.action(forDigit: 0))
        XCTAssertNil(model.action(forDigit: 10))
    }

    @MainActor
    func testClipboardPreviewNormalizesAndTruncatesText() {
        let model = QuickActionPickerModel()
        let longText = String(repeating: "a", count: 81) + "\nnext\tline"

        model.present(clipboardText: longText, actions: [])

        XCTAssertEqual(model.clipboardPreview, String(repeating: "a", count: 80) + "…")
        XCTAssertFalse(model.isClipboardEmpty)

        model.present(clipboardText: "first\nsecond\tthird", actions: [])
        XCTAssertEqual(model.clipboardPreview, "first second third")

        model.present(clipboardText: " \n\t ", actions: [])
        XCTAssertTrue(model.isClipboardEmpty)
        XCTAssertEqual(model.clipboardPreview, "")
    }

    @MainActor
    private func makeAction(
        name: String,
        order: Int,
        isEnabled: Bool = true
    ) -> ClipboardAction {
        ClipboardAction(
            name: name,
            promptTemplate: "Обработай {{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: order,
            isEnabled: isEnabled
        )
    }
}
