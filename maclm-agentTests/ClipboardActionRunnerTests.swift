import Foundation
@testable import maclm_agent
import XCTest

final class ClipboardActionRunnerTests: XCTestCase {
    @MainActor
    func testRunnerRendersPromptStreamsResponseAndWritesClipboard() async throws {
        let recorder = ProviderInvocationRecorder()
        let provider = StubLLMProvider(
            events: [.contentDelta("Го"), .contentDelta("тово"), .done],
            recorder: recorder
        )
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = makeRunner(
            provider: provider,
            clipboard: clipboard,
            automaticallyPaste: false
        )
        let action = makeAction()

        let task = try XCTUnwrap(runner.run(action: action))
        await task.value

        XCTAssertEqual(
            runner.state,
            .succeeded(
                actionName: "Проверка",
                outcome: ClipboardActionOutcome(pasteResult: .disabled)
            )
        )
        XCTAssertEqual(clipboard.value, "Готово")
        XCTAssertEqual(clipboard.writtenValues, ["Готово"])
        let invocation = try XCTUnwrap(recorder.invocation)
        XCTAssertEqual(invocation.messages.count, 1)
        XCTAssertEqual(invocation.messages.first?.role, .user)
        XCTAssertEqual(invocation.messages.first?.content, "Обработай:\n\nисходный текст")
        XCTAssertTrue(invocation.tools.isEmpty)
    }

    @MainActor
    func testAutoPasteDisabledDoesNotPasteAndKeepsResultInClipboard() async throws {
        let clipboard = StubClipboard(value: "исходный текст")
        let paste = StubPasteService()
        let runner = makeRunner(
            clipboard: clipboard,
            automaticallyPaste: false,
            trusted: true,
            pasteService: paste
        )

        await try XCTUnwrap(runner.run(action: makeAction())).value

        XCTAssertEqual(clipboard.value, "результат")
        XCTAssertEqual(paste.callCount, 0)
        XCTAssertEqual(successOutcome(from: runner).pasteResult, .disabled)
    }

    @MainActor
    func testAutoPasteWithoutAccessibilityDoesNotPasteAndKeepsResult() async throws {
        let clipboard = StubClipboard(value: "исходный текст")
        let paste = StubPasteService()
        let frontmostApplication = StubFrontmostApplicationService(activationSucceeds: true)
        let runner = makeRunner(
            clipboard: clipboard,
            automaticallyPaste: true,
            trusted: false,
            pasteService: paste,
            frontmostApplicationService: frontmostApplication
        )

        await try XCTUnwrap(runner.run(action: makeAction())).value

        XCTAssertEqual(clipboard.value, "результат")
        XCTAssertEqual(paste.callCount, 0)
        XCTAssertEqual(frontmostApplication.activateCallCount, 0)
        XCTAssertEqual(successOutcome(from: runner).pasteResult, .accessibilityDenied)
    }

    @MainActor
    func testAutoPasteWritesClipboardBeforeActivatingAndPastingOnce() async throws {
        let events = InvocationLog()
        let clipboard = StubClipboard(value: "исходный текст", log: events)
        let paste = StubPasteService(log: events)
        let frontmostApplication = StubFrontmostApplicationService(
            activationSucceeds: true,
            log: events
        )
        let runner = makeRunner(
            clipboard: clipboard,
            automaticallyPaste: true,
            trusted: true,
            pasteService: paste,
            frontmostApplicationService: frontmostApplication
        )

        await try XCTUnwrap(runner.run(action: makeAction())).value

        XCTAssertEqual(events.entries, ["clipboard.write", "application.activate", "paste"])
        XCTAssertEqual(paste.callCount, 1)
        XCTAssertTrue(successOutcome(from: runner).wasAutoPasted)
    }

    @MainActor
    func testPasteFailureLeavesOverallOutcomeSuccessful() async throws {
        let clipboard = StubClipboard(value: "исходный текст")
        let paste = StubPasteService(error: PasteError.eventCreationFailed)
        let runner = makeRunner(
            clipboard: clipboard,
            automaticallyPaste: true,
            trusted: true,
            pasteService: paste,
            frontmostApplicationService: StubFrontmostApplicationService(
                activationSucceeds: true
            )
        )

        await try XCTUnwrap(runner.run(action: makeAction())).value

        XCTAssertEqual(clipboard.value, "результат")
        XCTAssertEqual(paste.callCount, 1)
        XCTAssertEqual(
            successOutcome(from: runner).pasteResult,
            .failed(message: "Не удалось создать событие вставки.")
        )
    }

    @MainActor
    func testMissingFrontmostApplicationDoesNotPaste() async throws {
        let paste = StubPasteService()
        let runner = makeRunner(
            automaticallyPaste: true,
            trusted: true,
            pasteService: paste,
            frontmostApplicationService: StubFrontmostApplicationService(
                activationSucceeds: false
            )
        )

        await try XCTUnwrap(runner.run(action: makeAction())).value

        XCTAssertEqual(paste.callCount, 0)
        XCTAssertEqual(
            successOutcome(from: runner).pasteResult,
            .targetApplicationUnavailable
        )
    }

    @MainActor
    func testRunnerLeavesClipboardUnchangedAndDoesNotPasteWhenProviderFails() async throws {
        let provider = StubLLMProvider(
            events: [.contentDelta("частичный ответ")],
            terminalError: .providerFailed
        )
        let clipboard = StubClipboard(value: "исходный текст")
        let paste = StubPasteService()
        let runner = makeRunner(
            provider: provider,
            clipboard: clipboard,
            automaticallyPaste: true,
            trusted: true,
            pasteService: paste
        )
        let action = makeAction()

        await try XCTUnwrap(runner.run(action: action)).value

        XCTAssertEqual(
            runner.state,
            .failed(actionName: action.name, message: "Тестовая ошибка провайдера.")
        )
        XCTAssertEqual(clipboard.value, "исходный текст")
        XCTAssertTrue(clipboard.writtenValues.isEmpty)
        XCTAssertEqual(paste.callCount, 0)
    }

    @MainActor
    func testRunnerFailsBeforeProviderWhenClipboardHasNoText() {
        let providerSource = StubProviderSource(provider: StubLLMProvider(events: [.done]))
        let runner = ClipboardActionRunner(
            providerSource: providerSource,
            preferences: StubClipboardActionPreferences(automaticallyPaste: false),
            accessibilityPermissionService: StubAccessibilityPermissionService(),
            pasteService: StubPasteService(),
            frontmostApplicationService: StubFrontmostApplicationService(),
            clipboard: StubClipboard(value: nil)
        )
        let action = makeAction()

        XCTAssertNil(runner.run(action: action))
        XCTAssertEqual(
            runner.state,
            .failed(actionName: action.name, message: "В буфере обмена нет текста.")
        )
        XCTAssertEqual(providerSource.makeProviderCallCount, 0)
    }

    @MainActor
    func testRunnerRejectsInvalidTemplateBeforeReadingClipboard() {
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = makeRunner(clipboard: clipboard, automaticallyPaste: false)
        let action = ClipboardAction(
            name: "Некорректное действие",
            promptTemplate: "Без плейсхолдера",
            iconSystemName: "exclamationmark.triangle",
            sortOrder: 100
        )

        XCTAssertNil(runner.run(action: action))
        XCTAssertEqual(
            runner.state,
            .failed(
                actionName: action.name,
                message: "В шаблоне действия отсутствует {{input}}."
            )
        )
        XCTAssertEqual(clipboard.readCallCount, 0)
    }

    @MainActor
    func testRunnerRejectsToolCallAndDoesNotOverwriteClipboard() async throws {
        let toolCall = ToolCallDelta(
            index: 0,
            id: "call-1",
            type: "function",
            functionName: "read_file",
            argumentsDelta: "{}"
        )
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = makeRunner(
            provider: StubLLMProvider(events: [.toolCallDelta(toolCall), .done]),
            clipboard: clipboard,
            automaticallyPaste: false
        )
        let action = makeAction()

        await try XCTUnwrap(runner.run(action: action)).value

        XCTAssertEqual(
            runner.state,
            .failed(
                actionName: action.name,
                message: "LLM попыталась вызвать инструмент вместо обработки текста."
            )
        )
        XCTAssertEqual(clipboard.value, "исходный текст")
    }

    @MainActor
    func testRunnerDoesNotStartSecondActionWhileFirstIsRunning() async throws {
        let runner = makeRunner(automaticallyPaste: false)
        let firstAction = makeAction(name: "Первое")

        let firstTask = try XCTUnwrap(runner.run(action: firstAction))
        XCTAssertNil(runner.run(action: makeAction(name: "Второе")))
        await firstTask.value

        XCTAssertEqual(
            runner.state,
            .succeeded(
                actionName: "Первое",
                outcome: ClipboardActionOutcome(pasteResult: .disabled)
            )
        )
    }

    @MainActor
    func testDismissStatusKeepsRunningStateAndClearsCompletedState() async throws {
        let runner = makeRunner(automaticallyPaste: false)
        let task = try XCTUnwrap(runner.run(action: makeAction()))
        runner.dismissStatus()
        XCTAssertTrue(runner.state.isRunning)
        await task.value
        runner.dismissStatus()
        XCTAssertEqual(runner.state, .idle)
    }

    @MainActor
    private func makeRunner(
        provider: StubLLMProvider = StubLLMProvider(
            events: [.contentDelta("результат"), .done]
        ),
        clipboard: StubClipboard = StubClipboard(value: "исходный текст"),
        automaticallyPaste: Bool,
        trusted: Bool = false,
        pasteService: StubPasteService = StubPasteService(),
        frontmostApplicationService: StubFrontmostApplicationService =
            StubFrontmostApplicationService()
    ) -> ClipboardActionRunner {
        ClipboardActionRunner(
            providerSource: StubProviderSource(provider: provider),
            preferences: StubClipboardActionPreferences(
                automaticallyPaste: automaticallyPaste
            ),
            accessibilityPermissionService: StubAccessibilityPermissionService(
                trusted: trusted
            ),
            pasteService: pasteService,
            frontmostApplicationService: frontmostApplicationService,
            clipboard: clipboard
        )
    }

    @MainActor
    private func makeAction(name: String = "Проверка") -> ClipboardAction {
        ClipboardAction(
            name: name,
            promptTemplate: "Обработай:\n\n{{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: 100
        )
    }

    @MainActor
    private func successOutcome(from runner: ClipboardActionRunner) -> ClipboardActionOutcome {
        guard case let .succeeded(_, outcome) = runner.state else {
            XCTFail("Expected a successful clipboard action outcome")
            return ClipboardActionOutcome(pasteResult: .disabled)
        }
        return outcome
    }
}

private enum StubProviderError: Error, LocalizedError, Sendable {
    case providerFailed

    var errorDescription: String? {
        "Тестовая ошибка провайдера."
    }
}

private struct StubLLMProvider: LLMProvider {
    let name = "Stub"
    let events: [ChatStreamEvent]
    var terminalError: StubProviderError?
    var recorder: ProviderInvocationRecorder?

    init(
        events: [ChatStreamEvent],
        terminalError: StubProviderError? = nil,
        recorder: ProviderInvocationRecorder? = nil
    ) {
        self.events = events
        self.terminalError = terminalError
        self.recorder = recorder
    }

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        recorder?.record(messages: messages, tools: tools)
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }
}

private final class ProviderInvocationRecorder: @unchecked Sendable {
    struct Invocation {
        let messages: [ChatMessage]
        let tools: [ToolDefinition]
    }

    private let lock = NSLock()
    private var storedInvocation: Invocation?

    var invocation: Invocation? {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocation
    }

    func record(messages: [ChatMessage], tools: [ToolDefinition]) {
        lock.lock()
        defer { lock.unlock() }
        storedInvocation = Invocation(messages: messages, tools: tools)
    }
}

@MainActor
private final class StubProviderSource: LLMProviderProviding {
    private(set) var makeProviderCallCount = 0
    private let provider: any LLMProvider

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    func makeProvider() throws -> any LLMProvider {
        makeProviderCallCount += 1
        return provider
    }
}

@MainActor
private final class StubClipboard: ClipboardAccess {
    var value: String?
    private(set) var readCallCount = 0
    private(set) var writtenValues: [String] = []
    private let log: InvocationLog?

    init(value: String?, log: InvocationLog? = nil) {
        self.value = value
        self.log = log
    }

    func readString() throws -> String {
        readCallCount += 1
        guard let value, !value.isEmpty else {
            throw ClipboardAccessError.noText
        }
        return value
    }

    func writeString(_ string: String) throws {
        value = string
        writtenValues.append(string)
        log?.entries.append("clipboard.write")
    }
}

@MainActor
private final class StubClipboardActionPreferences: ClipboardActionPreferences {
    var automaticallyPasteClipboardActionResults: Bool

    init(automaticallyPaste: Bool) {
        automaticallyPasteClipboardActionResults = automaticallyPaste
    }
}

@MainActor
private final class StubAccessibilityPermissionService: AccessibilityPermissionService {
    var trusted: Bool

    var isTrusted: Bool {
        trusted
    }

    init(trusted: Bool = false) {
        self.trusted = trusted
    }

    func requestAccess() {}
    func openSystemSettings() {}
}

@MainActor
private final class StubPasteService: PasteService {
    private(set) var callCount = 0
    private let error: PasteError?
    private let log: InvocationLog?

    init(error: PasteError? = nil, log: InvocationLog? = nil) {
        self.error = error
        self.log = log
    }

    func paste() throws {
        callCount += 1
        log?.entries.append("paste")
        if let error {
            throw error
        }
    }
}

@MainActor
private final class StubFrontmostApplicationService: FrontmostApplicationService {
    private(set) var captureCallCount = 0
    private(set) var activateCallCount = 0
    private let activationSucceeds: Bool
    private let log: InvocationLog?

    init(activationSucceeds: Bool = false, log: InvocationLog? = nil) {
        self.activationSucceeds = activationSucceeds
        self.log = log
    }

    func captureTargetApplication() {
        captureCallCount += 1
    }

    func activateTargetApplication() -> Bool {
        activateCallCount += 1
        log?.entries.append("application.activate")
        return activationSucceeds
    }
}

@MainActor
private final class InvocationLog {
    var entries: [String] = []
}
