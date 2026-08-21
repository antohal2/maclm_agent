@testable import maclm_agent
import SwiftData
import XCTest

final class ClipboardActionStoreTests: XCTestCase {
    @MainActor
    func testCreateAddsCustomActionAfterExistingActions() throws {
        let fixture = try makeFixture(seedDefaults: true)

        let action = try fixture.store.create(
            name: "Проверить стиль",
            promptTemplate: "Проверь стиль: {{input}}",
            iconSystemName: "text.badge.checkmark"
        )

        XCTAssertEqual(action.sortOrder, 700)
        XCTAssertFalse(action.isBuiltIn)
        XCTAssertEqual(try fetchActions(fixture.context).last?.id, action.id)
    }

    @MainActor
    func testCreateRejectsInvalidValues() throws {
        let fixture = try makeFixture(seedDefaults: true)

        assertStoreError(.emptyName) {
            try fixture.store.create(
                name: "",
                promptTemplate: "{{input}}",
                iconSystemName: "star"
            )
        }
        assertStoreError(.emptyName) {
            try fixture.store.create(
                name: " \n\t ",
                promptTemplate: "{{input}}",
                iconSystemName: "star"
            )
        }
        assertStoreError(.nameTooLong) {
            try fixture.store.create(
                name: String(repeating: "а", count: 61),
                promptTemplate: "{{input}}",
                iconSystemName: "star"
            )
        }
        assertStoreError(.duplicateName) {
            try fixture.store.create(
                name: "пЕрЕвЕсТи",
                promptTemplate: "{{input}}",
                iconSystemName: "star"
            )
        }
        assertStoreError(.invalidTemplate(.missingInputPlaceholder)) {
            try fixture.store.create(
                name: "Без плейсхолдера",
                promptTemplate: "Только текст",
                iconSystemName: "star"
            )
        }
        assertStoreError(.invalidIcon) {
            try fixture.store.create(
                name: "Неверная иконка",
                promptTemplate: "{{input}}",
                iconSystemName: "this.symbol.does.not.exist"
            )
        }
    }

    @MainActor
    func testUpdateAllowsOwnNameAndChangesTimestamp() throws {
        let fixture = try makeFixture(seedDefaults: true)
        let action = try XCTUnwrap(try fetchActions(fixture.context).first)
        action.updatedAt = .distantPast
        try fixture.context.save()

        try fixture.store.update(
            action,
            name: action.name.uppercased(),
            promptTemplate: "Новый шаблон: {{input}}",
            iconSystemName: "star"
        )

        XCTAssertEqual(action.name, "ПЕРЕВЕСТИ")
        XCTAssertEqual(action.promptTemplate, "Новый шаблон: {{input}}")
        XCTAssertGreaterThan(action.updatedAt, .distantPast)
    }

    @MainActor
    func testDeleteRemovesActionAndAllowsEmptyStore() throws {
        let fixture = try makeFixture(seedDefaults: false)
        let action = try fixture.store.create(
            name: "Единственное",
            promptTemplate: "{{input}}",
            iconSystemName: "star"
        )

        try fixture.store.delete(action)

        XCTAssertTrue(try fetchActions(fixture.context).isEmpty)
    }

    @MainActor
    func testSetEnabledSwitchesBothWays() throws {
        let fixture = try makeFixture(seedDefaults: true)
        let action = try XCTUnwrap(try fetchActions(fixture.context).first)

        try fixture.store.setEnabled(action, enabled: false)
        XCTAssertFalse(action.isEnabled)
        try fixture.store.setEnabled(action, enabled: true)
        XCTAssertTrue(action.isEnabled)
    }

    @MainActor
    func testMoveDownAndUpMaintainsExpectedOrder() throws {
        let fixture = try makeFixture(seedDefaults: true)

        try fixture.store.move(from: 0, to: 3)
        XCTAssertEqual(
            try fetchActions(fixture.context).map(\.name),
            ["Улучшить текст", "Саммари", "Объяснить", "Перевести", "Формальный тон", "Неформальный тон"]
        )

        try fixture.store.move(from: 3, to: 1)
        XCTAssertEqual(
            try fetchActions(fixture.context).map(\.name),
            ["Улучшить текст", "Перевести", "Саммари", "Объяснить", "Формальный тон", "Неформальный тон"]
        )
    }

    @MainActor
    func testRepeatedMovesKeepUniqueAscendingOrderAndSamePositionIsNoOp() throws {
        let fixture = try makeFixture(seedDefaults: true)

        try fixture.store.move(from: 0, to: 5)
        try fixture.store.move(from: 1, to: 4)
        let beforeNoOp = try fetchActions(fixture.context)
        let namesBeforeNoOp = beforeNoOp.map(\.name)
        let ordersBeforeNoOp = beforeNoOp.map(\.sortOrder)
        try fixture.store.move(from: 2, to: 2)
        let afterNoOp = try fetchActions(fixture.context)

        XCTAssertEqual(afterNoOp.map(\.name), namesBeforeNoOp)
        XCTAssertEqual(afterNoOp.map(\.sortOrder), ordersBeforeNoOp)
        XCTAssertEqual(Set(afterNoOp.map(\.sortOrder)).count, afterNoOp.count)
        XCTAssertEqual(afterNoOp.map(\.sortOrder), afterNoOp.map(\.sortOrder).sorted())
    }

    @MainActor
    func testResetRestoresModifiedAndDeletedBuiltInsWithoutTouchingCustomAction() throws {
        let fixture = try makeFixture(seedDefaults: true)
        let definitions = DefaultClipboardActions.definitions
        let modified = try XCTUnwrap(
            try fetchActions(fixture.context).first { $0.id == definitions[0].id }
        )
        let deleted = try XCTUnwrap(
            try fetchActions(fixture.context).first { $0.id == definitions[1].id }
        )
        modified.name = "Изменённое"
        modified.promptTemplate = "Изменено {{input}}"
        modified.iconSystemName = "star"
        modified.sortOrder = 999
        modified.isEnabled = false
        fixture.context.delete(deleted)
        let custom = ClipboardAction(
            name: "Пользовательское",
            promptTemplate: "Пользовательское {{input}}",
            iconSystemName: "bolt",
            sortOrder: 777,
            isEnabled: false
        )
        fixture.context.insert(custom)
        try fixture.context.save()

        try fixture.store.resetBuiltInsToDefaults()

        let actions = try fetchActions(fixture.context)
        XCTAssertEqual(actions.count, 7)
        for definition in definitions {
            let action = try XCTUnwrap(actions.first { $0.id == definition.id })
            assert(action: action, matches: definition)
        }
        let persistedCustom = try XCTUnwrap(actions.first { $0.id == custom.id })
        XCTAssertEqual(persistedCustom.name, "Пользовательское")
        XCTAssertEqual(persistedCustom.sortOrder, 777)
        XCTAssertFalse(persistedCustom.isEnabled)
        XCTAssertFalse(persistedCustom.isBuiltIn)
    }

    @MainActor
    func testResetIsIdempotentAndUsesSeederDefinitions() throws {
        let fixture = try makeFixture(seedDefaults: true)

        try fixture.store.resetBuiltInsToDefaults()
        let firstReset = try builtInSnapshots(context: fixture.context)
        try fixture.store.resetBuiltInsToDefaults()
        let secondReset = try builtInSnapshots(context: fixture.context)

        XCTAssertEqual(firstReset, secondReset)
        XCTAssertEqual(
            firstReset.map(\.id),
            DefaultClipboardActions.definitions.map(\.id)
        )
    }

    @MainActor
    func testSeederMigratesLegacyRandomIDsToStableDefinitionIDs() throws {
        let fixture = try makeFixture(seedDefaults: false)
        for definition in DefaultClipboardActions.definitions {
            fixture.context.insert(
                ClipboardAction(
                    name: definition.name,
                    promptTemplate: definition.promptTemplate,
                    iconSystemName: definition.iconSystemName,
                    sortOrder: definition.sortOrder,
                    isEnabled: definition.isEnabled,
                    isBuiltIn: definition.isBuiltIn
                )
            )
        }
        try fixture.context.save()

        try ClipboardActionSeeder.seedIfNeeded(context: fixture.context)

        XCTAssertEqual(
            try Set(fetchActions(fixture.context).map(\.id)),
            Set(DefaultClipboardActions.definitions.map(\.id))
        )
    }

    @MainActor
    private func makeFixture(seedDefaults: Bool) throws -> StoreFixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ClipboardAction.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        if seedDefaults {
            try ClipboardActionSeeder.seedIfNeeded(context: context)
        }
        return StoreFixture(
            container: container,
            context: context,
            store: ClipboardActionStore(context: context)
        )
    }

    @MainActor
    private func fetchActions(_ context: ModelContext) throws -> [ClipboardAction] {
        let descriptor = FetchDescriptor<ClipboardAction>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    @MainActor
    private func builtInSnapshots(context: ModelContext) throws -> [ActionSnapshot] {
        try fetchActions(context)
            .filter(\.isBuiltIn)
            .map(ActionSnapshot.init)
    }

    private func assertStoreError(
        _ expectedError: ClipboardActionStoreError,
        operation: () throws -> ClipboardAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ClipboardActionStoreError, expectedError, file: file, line: line)
        }
    }

    private func assert(
        action: ClipboardAction,
        matches definition: DefaultClipboardActions.Definition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(action.name, definition.name, file: file, line: line)
        XCTAssertEqual(action.promptTemplate, definition.promptTemplate, file: file, line: line)
        XCTAssertEqual(action.iconSystemName, definition.iconSystemName, file: file, line: line)
        XCTAssertEqual(action.sortOrder, definition.sortOrder, file: file, line: line)
        XCTAssertEqual(action.isEnabled, definition.isEnabled, file: file, line: line)
        XCTAssertEqual(action.isBuiltIn, definition.isBuiltIn, file: file, line: line)
    }
}

@MainActor
private struct StoreFixture {
    let container: ModelContainer
    let context: ModelContext
    let store: ClipboardActionStore
}

private struct ActionSnapshot: Equatable {
    let id: UUID
    let name: String
    let promptTemplate: String
    let iconSystemName: String
    let sortOrder: Int
    let isEnabled: Bool
    let isBuiltIn: Bool
    let updatedAt: Date

    init(_ action: ClipboardAction) {
        id = action.id
        name = action.name
        promptTemplate = action.promptTemplate
        iconSystemName = action.iconSystemName
        sortOrder = action.sortOrder
        isEnabled = action.isEnabled
        isBuiltIn = action.isBuiltIn
        updatedAt = action.updatedAt
    }
}
