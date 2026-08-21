@testable import maclm_agent
import SwiftData
import XCTest

final class ClipboardActionDeletionDuringRunTests: XCTestCase {
    @MainActor
    func testDeletingActionWhileItRunsDoesNotCrash() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ClipboardAction.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let action = ClipboardAction(
            name: "Проверка",
            promptTemplate: "Обработай {{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: 100
        )
        context.insert(action)
        try context.save()
        let clipboard = DeletionTestClipboard()
        let runner = ClipboardActionRunner(
            providerSource: DeletionTestProviderSource(),
            preferences: DeletionTestPreferences(),
            accessibilityPermissionService: DeletionTestAccessibilityService(),
            pasteService: DeletionTestPasteService(),
            frontmostApplicationService: DeletionTestFrontmostApplicationService(),
            clipboard: clipboard
        )

        let task = try XCTUnwrap(runner.run(action: action))
        context.delete(action)
        try context.save()
        await task.value

        XCTAssertEqual(clipboard.value, "готово")
        XCTAssertEqual(
            runner.state,
            .succeeded(
                actionName: "Проверка",
                outcome: ClipboardActionOutcome(pasteResult: .disabled)
            )
        )
    }
}

private struct DeletionTestProvider: LLMProvider {
    let name = "Deletion test"

    func streamChat(
        messages _: [ChatMessage],
        tools _: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("готово"))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

@MainActor
private final class DeletionTestProviderSource: LLMProviderProviding {
    func makeProvider() throws -> any LLMProvider {
        DeletionTestProvider()
    }
}

@MainActor
private final class DeletionTestClipboard: ClipboardAccess {
    var value = "исходный текст"

    func readString() throws -> String {
        value
    }

    func writeString(_ string: String) throws {
        value = string
    }
}

@MainActor
private final class DeletionTestPreferences: ClipboardActionPreferences {
    let automaticallyPasteClipboardActionResults = false
}

@MainActor
private final class DeletionTestAccessibilityService: AccessibilityPermissionService {
    var isTrusted: Bool {
        false
    }

    func requestAccess() {}
    func openSystemSettings() {}
}

@MainActor
private final class DeletionTestPasteService: PasteService {
    func paste() throws {}
}

@MainActor
private final class DeletionTestFrontmostApplicationService: FrontmostApplicationService {
    func captureTargetApplication() {}

    func activateTargetApplication() -> Bool {
        true
    }
}
