import Foundation

protocol LLMProvider: Sendable {
    var name: String { get }

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>
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
    let parameters: ToolParameters
}

struct ToolParameters: Codable, Equatable, Sendable {
    let type: String
    let properties: [String: ToolPropertyDefinition]
    let required: [String]

    init(
        type: String = "object",
        properties: [String: ToolPropertyDefinition] = [:],
        required: [String] = []
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

struct ToolPropertyDefinition: Codable, Equatable, Sendable {
    let type: String
    let description: String
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
    case streamEndedWithoutDone
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Некорректный базовый URL LM Studio."
        case .invalidResponse:
            "LM Studio вернул некорректный HTTP-ответ."
        case let .httpError(statusCode, message):
            "LM Studio вернул HTTP \(statusCode): \(message)"
        case let .invalidSSEPayload(payload):
            "Не удалось разобрать поток LM Studio: \(payload)"
        case .streamEndedWithoutDone:
            "Соединение с LM Studio закрылось до завершения ответа."
        case let .transport(message):
            "LM Studio недоступен: \(message)"
        }
    }
}
