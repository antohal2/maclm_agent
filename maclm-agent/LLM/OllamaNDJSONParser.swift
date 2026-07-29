import Foundation

struct OllamaNDJSONParser {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [ChatStreamEvent] {
        buffer.append(data)

        var events: [ChatStreamEvent] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            try events.append(contentsOf: parseLine(line))
        }
        return events
    }

    mutating func finish() throws -> [ChatStreamEvent] {
        guard !buffer.isEmpty else {
            return []
        }

        defer { buffer.removeAll(keepingCapacity: false) }
        return try parseLine(buffer)
    }

    private func parseLine(_ data: Data) throws -> [ChatStreamEvent] {
        let line = data.last == 0x0D ? data.dropLast() : data[...]
        guard !line.isEmpty else {
            return []
        }

        let chunk: OllamaChatChunk
        do {
            chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: Data(line))
        } catch {
            let payload = String(data: line, encoding: .utf8) ?? "данные не являются UTF-8"
            throw LLMProviderError.invalidNDJSONPayload(payload)
        }

        if let error = chunk.error, !error.isEmpty {
            throw LLMProviderError.providerResponse(error)
        }

        var events: [ChatStreamEvent] = []
        if let content = chunk.message?.content, !content.isEmpty {
            events.append(.contentDelta(content))
        }
        if let toolCalls = chunk.message?.toolCalls {
            events.append(contentsOf: toolCalls.enumerated().map { offset, toolCall in
                .toolCallDelta(
                    ToolCallDelta(
                        index: toolCall.function.index ?? offset,
                        id: nil,
                        type: "function",
                        functionName: toolCall.function.name,
                        argumentsDelta: toolCall.function.arguments.jsonString
                    )
                )
            })
        }
        if chunk.done == true {
            events.append(.done)
        }
        return events
    }
}

private struct OllamaChatChunk: Decodable {
    let message: OllamaResponseMessage?
    let done: Bool?
    let error: String?
}

private struct OllamaResponseMessage: Decodable {
    let content: String?
    let toolCalls: [OllamaResponseToolCall]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private struct OllamaResponseToolCall: Decodable {
    let function: OllamaResponseFunction
}

private struct OllamaResponseFunction: Decodable {
    let index: Int?
    let name: String
    let arguments: JSONValue
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    init(argumentsJSON: String) {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else {
            self = .string(argumentsJSON)
            return
        }
        self = decoded
    }
}
