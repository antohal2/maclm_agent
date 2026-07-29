import Foundation

protocol LLMProvider: Sendable {
    var name: String { get }

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case lmStudio
    case ollama

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .lmStudio:
            "LM Studio"
        case .ollama:
            "Ollama"
        }
    }

    var defaultBaseURL: URL {
        switch self {
        case .lmStudio:
            URL(string: "http://localhost:1234")!
        case .ollama:
            URL(string: "http://localhost:11434")!
        }
    }
}

enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    var toolCalls: [ChatToolCall]?
    var toolCallID: String?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

struct ChatToolCall: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let function: ChatToolFunction
}

struct ChatToolFunction: Codable, Equatable, Sendable {
    let name: String
    let arguments: String
}

struct ToolDefinition: Codable, Equatable, Sendable {
    let type: String
    let function: ToolFunctionDefinition

    init(function: ToolFunctionDefinition, type: String = "function") {
        self.type = type
        self.function = function
    }
}

struct ToolFunctionDefinition: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let parameters: JSONSchema
}

enum ChatStreamEvent: Equatable, Sendable {
    case contentDelta(String)
    case toolCallDelta(ToolCallDelta)
    case done
}

struct ToolCallDelta: Equatable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let functionName: String?
    let argumentsDelta: String?
}

enum LLMProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case invalidSSEPayload(String)
    case invalidNDJSONPayload(String)
    case providerResponse(String)
    case streamEndedWithoutDone
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Некорректный базовый URL LLM-сервера."
        case .invalidResponse:
            "LLM-сервер вернул некорректный HTTP-ответ."
        case let .httpError(statusCode, message):
            "LLM-сервер вернул HTTP \(statusCode): \(message)"
        case let .invalidSSEPayload(payload):
            "Не удалось разобрать поток LM Studio: \(payload)"
        case let .invalidNDJSONPayload(payload):
            "Не удалось разобрать поток Ollama: \(payload)"
        case let .providerResponse(message):
            "LLM-сервер вернул ошибку: \(message)"
        case .streamEndedWithoutDone:
            "Соединение с LLM-сервером закрылось до завершения ответа."
        case let .transport(message):
            "LLM-сервер недоступен: \(message)"
        }
    }
}
