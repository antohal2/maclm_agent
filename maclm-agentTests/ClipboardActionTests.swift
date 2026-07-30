@testable import maclm_agent
import SwiftData
import XCTest

final class ClipboardActionTests: XCTestCase {
    func testTemplateValidationAcceptsValidTemplate() {
        assertValidationSucceeds("До {{input}} после")
    }

    func testTemplateValidationRejectsEmptyTemplate() {
        assertValidationFails(" \n\t", expectedError: .emptyTemplate)
    }

    func testTemplateValidationRejectsMissingPlaceholder() {
        assertValidationFails("Текст без плейсхолдера", expectedError: .missingInputPlaceholder)
    }

    func testTemplateRenderReplacesOneOccurrence() {
        XCTAssertEqual(
            ClipboardActionTemplate.render("До {{input}} после", input: "текст"),
            "До текст после"
        )
    }

    func testTemplateRenderReplacesEveryOccurrence() {
        XCTAssertEqual(
            ClipboardActionTemplate.render("{{input}} + {{input}}", input: "текст"),
            "текст + текст"
        )
    }

    func testTemplateRenderSupportsEmptyInput() {
        XCTAssertEqual(
            ClipboardActionTemplate.render("До {{input}} после", input: ""),
            "До  после"
        )
    }

    func testTemplateRenderDoesNotRecursivelyReplaceInput() {
        XCTAssertEqual(
            ClipboardActionTemplate.render("До {{input}} после", input: "{{input}}"),
            "До {{input}} после"
        )
    }

    func testAllDefaultTemplatesAreValid() {
        XCTAssertEqual(DefaultClipboardActions.definitions.count, 6)
        for definition in DefaultClipboardActions.definitions {
            assertValidationSucceeds(definition.promptTemplate)
        }
    }

    func testDefaultDefinitionsUseExpectedIconsAndFlags() {
        XCTAssertEqual(
            DefaultClipboardActions.definitions.map(\.iconSystemName),
            [
                "globe",
                "wand.and.stars",
                "text.append",
                "questionmark.circle",
                "briefcase",
                "bubble.left.and.bubble.right",
            ]
        )
        XCTAssertTrue(DefaultClipboardActions.definitions.allSatisfy(\.isEnabled))
        XCTAssertTrue(DefaultClipboardActions.definitions.allSatisfy(\.isBuiltIn))
    }

    @MainActor
    func testSeederCreatesSixOrderedDefaultActions() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)

        try ClipboardActionSeeder.seedIfNeeded(context: context)

        let actions = try fetchActions(context: context)
        XCTAssertEqual(actions.count, 6)
        XCTAssertEqual(
            actions.map(\.name),
            ["Перевести", "Улучшить текст", "Саммари", "Объяснить", "Формальный тон", "Неформальный тон"]
        )
        XCTAssertEqual(actions.map(\.sortOrder), [100, 200, 300, 400, 500, 600])
        XCTAssertTrue(actions.allSatisfy(\.isEnabled))
        XCTAssertTrue(actions.allSatisfy(\.isBuiltIn))
    }

    @MainActor
    func testSeederDoesNotCreateDuplicates() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)

        try ClipboardActionSeeder.seedIfNeeded(context: context)
        try ClipboardActionSeeder.seedIfNeeded(context: context)

        XCTAssertEqual(try fetchActions(context: context).count, 6)
    }

    @MainActor
    func testSeederDoesNothingWhenCustomActionExists() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        context.insert(
            ClipboardAction(
                name: "Пользовательское",
                promptTemplate: "Обработай: {{input}}",
                iconSystemName: "star",
                sortOrder: 1000
            )
        )
        try context.save()

        try ClipboardActionSeeder.seedIfNeeded(context: context)

        let actions = try fetchActions(context: context)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.name, "Пользовательское")
        XCTAssertEqual(actions.first?.isBuiltIn, false)
    }

    private func assertValidationSucceeds(
        _ template: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .success = ClipboardActionTemplate.validate(template) else {
            return XCTFail("Expected a valid template", file: file, line: line)
        }
    }

    private func assertValidationFails(
        _ template: String,
        expectedError: ClipboardActionTemplate.TemplateError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = ClipboardActionTemplate.validate(template) else {
            return XCTFail("Expected template validation to fail", file: file, line: line)
        }
        XCTAssertEqual(error, expectedError, file: file, line: line)
    }

    @MainActor
    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ClipboardAction.self,
            configurations: configuration
        )
    }

    @MainActor
    private func fetchActions(context: ModelContext) throws -> [ClipboardAction] {
        let descriptor = FetchDescriptor<ClipboardAction>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return try context.fetch(descriptor)
    }
}
