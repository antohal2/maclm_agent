import Foundation
import Observation

@MainActor
protocol LLMProviderProviding: AnyObject {
    func makeProvider() throws -> any LLMProvider
}

extension ProviderCoordinator: LLMProviderProviding {}

@MainActor
protocol ClipboardActionPreferences: AnyObject {
    var automaticallyPasteClipboardActionResults: Bool { get }
}

enum ClipboardActionPasteResult: Equatable {
    case pasted
    case disabled
    case accessibilityDenied
    case targetApplicationUnavailable
    case failed(message: String)

    var wasAutoPasted: Bool {
        self == .pasted
    }
}

struct ClipboardActionOutcome: Equatable {
    let pasteResult: ClipboardActionPasteResult

    var wasAutoPasted: Bool {
        pasteResult.wasAutoPasted
    }
}

enum ClipboardActionRunState: Equatable {
    case idle
    case running(actionID: UUID, actionName: String)
    case succeeded(actionName: String, outcome: ClipboardActionOutcome)
    case failed(actionName: String, message: String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum ClipboardActionRunnerError: Error, Equatable, LocalizedError {
    case invalidTemplate(ClipboardActionTemplate.TemplateError)
    case emptyResponse
    case unexpectedToolCall

    var errorDescription: String? {
        switch self {
        case let .invalidTemplate(error):
            switch error {
            case .emptyTemplate:
                String(localized: "У действия пустой шаблон промпта.")
            case .missingInputPlaceholder:
                String(localized: "В шаблоне действия отсутствует {{input}}.")
            }
        case .emptyResponse:
            String(localized: "LLM-сервер вернул пустой ответ.")
        case .unexpectedToolCall:
            String(localized: "LLM попыталась вызвать инструмент вместо обработки текста.")
        }
    }
}

@MainActor
@Observable
final class ClipboardActionRunner {
    private(set) var state: ClipboardActionRunState = .idle

    private let providerSource: any LLMProviderProviding
    private let clipboard: any ClipboardAccess
    private let preferences: any ClipboardActionPreferences
    private let accessibilityPermissionService: any AccessibilityPermissionService
    private let pasteService: any PasteService
    private let frontmostApplicationService: any FrontmostApplicationService

    init(
        providerSource: any LLMProviderProviding,
        preferences: any ClipboardActionPreferences,
        accessibilityPermissionService: any AccessibilityPermissionService,
        pasteService: any PasteService,
        frontmostApplicationService: any FrontmostApplicationService,
        clipboard: any ClipboardAccess = SystemClipboard()
    ) {
        self.providerSource = providerSource
        self.preferences = preferences
        self.accessibilityPermissionService = accessibilityPermissionService
        self.pasteService = pasteService
        self.frontmostApplicationService = frontmostApplicationService
        self.clipboard = clipboard
    }

    func captureTargetApplication() {
        frontmostApplicationService.captureTargetApplication()
    }

    @discardableResult
    func run(action: ClipboardAction) -> Task<Void, Never>? {
        guard !state.isRunning else {
            return nil
        }

        let actionID = action.id
        let actionName = action.name

        do {
            let promptTemplate = try validatedTemplate(action.promptTemplate)
            let input = try clipboard.readString()
            let provider = try providerSource.makeProvider()
            let prompt = ClipboardActionTemplate.render(promptTemplate, input: input)

            state = .running(actionID: actionID, actionName: actionName)
            return Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    let output = try await Self.generateResponse(
                        prompt: prompt,
                        provider: provider
                    )
                    try clipboard.writeString(output)
                    let outcome = ClipboardActionOutcome(
                        pasteResult: performAutoPasteIfNeeded()
                    )
                    state = .succeeded(actionName: actionName, outcome: outcome)
                } catch is CancellationError {
                    state = .idle
                } catch {
                    state = .failed(
                        actionName: actionName,
                        message: error.localizedDescription
                    )
                }
            }
        } catch {
            state = .failed(
                actionName: actionName,
                message: error.localizedDescription
            )
            return nil
        }
    }

    func dismissStatus() {
        guard !state.isRunning else {
            return
        }
        state = .idle
    }

    private func performAutoPasteIfNeeded() -> ClipboardActionPasteResult {
        guard preferences.automaticallyPasteClipboardActionResults else {
            return .disabled
        }
        guard accessibilityPermissionService.isTrusted else {
            return .accessibilityDenied
        }
        guard frontmostApplicationService.activateTargetApplication() else {
            return .targetApplicationUnavailable
        }

        do {
            try pasteService.paste()
            return .pasted
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func validatedTemplate(_ template: String) throws -> String {
        switch ClipboardActionTemplate.validate(template) {
        case .success:
            return template
        case let .failure(error):
            throw ClipboardActionRunnerError.invalidTemplate(error)
        }
    }

    private static func generateResponse(
        prompt: String,
        provider: any LLMProvider
    ) async throws -> String {
        var response = ""
        var receivedDone = false

        stream: for try await event in provider.streamChat(
            messages: [ChatMessage(role: .user, content: prompt)],
            tools: []
        ) {
            switch event {
            case let .contentDelta(delta):
                response += delta
            case .toolCallDelta:
                throw ClipboardActionRunnerError.unexpectedToolCall
            case .usage: break
            case .done:
                receivedDone = true
                break stream
            }
        }

        guard receivedDone else {
            throw LLMProviderError.streamEndedWithoutDone
        }
        guard !response.isEmpty else {
            throw ClipboardActionRunnerError.emptyResponse
        }
        return response
    }
}
