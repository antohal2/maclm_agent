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
        let providerSource = StubProviderSource(provider: provider)
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = ClipboardActionRunner(
            providerSource: providerSource,
            clipboard: clipboard
        )
        let action = ClipboardAction(
            name: "Проверка",
            promptTemplate: "Обработай:\n\n{{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: 100
        )

        let task = try XCTUnwrap(runner.run(action: action))
        await task.value

        XCTAssertEqual(runner.state, .succeeded(actionName: "Проверка"))
        XCTAssertEqual(clipboard.value, "Готово")
        XCTAssertEqual(clipboard.writtenValues, ["Готово"])
        XCTAssertEqual(providerSource.makeProviderCallCount, 1)

        let invocation = try XCTUnwrap(recorder.invocation)
        XCTAssertEqual(invocation.messages.count, 1)
        XCTAssertEqual(invocation.messages.first?.role, .user)
        XCTAssertEqual(
            invocation.messages.first?.content,
            "Обработай:\n\nисходный текст"
        )
        XCTAssertTrue(invocation.tools.isEmpty)
    }

    @MainActor
    func testRunnerLeavesClipboardUnchangedWhenProviderFails() async throws {
        let provider = StubLLMProvider(
            events: [.contentDelta("частичный ответ")],
            terminalError: .providerFailed
        )
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = ClipboardActionRunner(
            providerSource: StubProviderSource(provider: provider),
            clipboard: clipboard
        )
        let action = makeAction()

        let task = try XCTUnwrap(runner.run(action: action))
        await task.value

        XCTAssertEqual(
            runner.state,
            .failed(actionName: action.name, message: "Тестовая ошибка провайдера.")
        )
        XCTAssertEqual(clipboard.value, "исходный текст")
        XCTAssertTrue(clipboard.writtenValues.isEmpty)
    }

    @MainActor
    func testRunnerFailsBeforeProviderWhenClipboardHasNoText() {
        let providerSource = StubProviderSource(provider: StubLLMProvider(events: [.done]))
        let runner = ClipboardActionRunner(
            providerSource: providerSource,
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
        let providerSource = StubProviderSource(provider: StubLLMProvider(events: [.done]))
        let runner = ClipboardActionRunner(
            providerSource: providerSource,
            clipboard: clipboard
        )
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
        XCTAssertEqual(providerSource.makeProviderCallCount, 0)
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
        let provider = StubLLMProvider(events: [.toolCallDelta(toolCall), .done])
        let clipboard = StubClipboard(value: "исходный текст")
        let runner = ClipboardActionRunner(
            providerSource: StubProviderSource(provider: provider),
            clipboard: clipboard
        )
        let action = makeAction()

        let task = try XCTUnwrap(runner.run(action: action))
        await task.value

        XCTAssertEqual(
            runner.state,
            .failed(
                actionName: action.name,
                message: "LLM попыталась вызвать инструмент вместо обработки текста."
            )
        )
        XCTAssertEqual(clipboard.value, "исходный текст")
        XCTAssertTrue(clipboard.writtenValues.isEmpty)
    }

    @MainActor
    func testRunnerDoesNotStartSecondActionWhileFirstIsRunning() async throws {
        let provider = StubLLMProvider(events: [.contentDelta("результат"), .done])
        let runner = ClipboardActionRunner(
            providerSource: StubProviderSource(provider: provider),
            clipboard: StubClipboard(value: "исходный текст")
        )
        let firstAction = makeAction(name: "Первое")
        let secondAction = makeAction(name: "Второе")

        let firstTask = try XCTUnwrap(runner.run(action: firstAction))
        XCTAssertNil(runner.run(action: secondAction))
        await firstTask.value

        XCTAssertEqual(runner.state, .succeeded(actionName: "Первое"))
    }

    @MainActor
    func testDismissStatusKeepsRunningStateAndClearsCompletedState() async throws {
        let runner = ClipboardActionRunner(
            providerSource: StubProviderSource(
                provider: StubLLMProvider(events: [.contentDelta("результат"), .done])
            ),
            clipboard: StubClipboard(value: "исходный текст")
        )
        let action = makeAction()

        let task = try XCTUnwrap(runner.run(action: action))
        runner.dismissStatus()
        XCTAssertTrue(runner.state.isRunning)

        await task.value
        runner.dismissStatus()
        XCTAssertEqual(runner.state, .idle)
    }

    @MainActor
    private func makeAction(name: String = "Проверка") -> ClipboardAction {
        ClipboardAction(
            name: name,
            promptTemplate: "Обработай {{input}}",
            iconSystemName: "wand.and.stars",
            sortOrder: 100
        )
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

    init(value: String?) {
        self.value = value
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
    }
}
