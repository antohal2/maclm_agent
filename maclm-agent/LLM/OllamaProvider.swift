import Foundation

struct OllamaProvider: LLMProvider {
    let name = "Ollama"
    let baseURL: URL
    let model: String

    private let session: URLSession

    init(
        baseURL: URL = LLMProviderKind.ollama.defaultBaseURL,
        model: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    func streamChat(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await receiveEvents(
                        messages: messages,
                        tools: tools,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mappedError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func receiveEvents(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let request = try makeRequest(messages: messages, tools: tools)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = try await readErrorMessage(from: bytes)
            throw LLMProviderError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        try await parseStream(bytes, continuation: continuation)
    }

    private func parseStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var parser = OllamaNDJSONParser()
        var lineBuffer = Data()

        for try await byte in bytes {
            try Task.checkCancellation()
            lineBuffer.append(byte)

            guard byte == 0x0A else {
                continue
            }
            if try yield(parser.append(lineBuffer), to: continuation) {
                return
            }
            lineBuffer.removeAll(keepingCapacity: true)
        }

        let receivedDone = try yield(parser.append(lineBuffer), to: continuation)
            || yield(parser.finish(), to: continuation)
        if receivedDone {
            return
        }
        throw LLMProviderError.streamEndedWithoutDone
    }

    private func yield(
        _ events: [ChatStreamEvent],
        to continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) -> Bool {
        for event in events {
            continuation.yield(event)
            if event == .done {
                return true
            }
        }
        return false
    }

    private func makeRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) throws -> URLRequest {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased()) else {
            throw LLMProviderError.invalidBaseURL
        }

        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: makeRequestMessages(messages),
                stream: true,
                tools: tools.isEmpty ? nil : tools
            )
        )
        return request
    }

    private func makeRequestMessages(_ messages: [ChatMessage]) -> [OllamaRequestMessage] {
        var toolNamesByID: [String: String] = [:]

        return messages.map { message in
            let toolCalls = message.toolCalls?.enumerated().map { index, call in
                toolNamesByID[call.id] = call.function.name
                return OllamaRequestToolCall(
                    type: call.type,
                    function: OllamaRequestFunction(
                        index: index,
                        name: call.function.name,
                        arguments: JSONValue(argumentsJSON: call.function.arguments)
                    )
                )
            }
            let toolName = message.toolCallID.flatMap { toolNamesByID[$0] ?? $0 }
            return OllamaRequestMessage(
                role: message.role,
                content: message.content,
                toolCalls: toolCalls,
                toolName: toolName
            )
        }
    }

    private func readErrorMessage(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 4096 {
                break
            }
        }

        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else {
            return "пустое тело ответа"
        }
        return message
    }

    private func mappedError(_ error: Error) -> Error {
        switch error {
        case is CancellationError:
            CancellationError()
        case let providerError as LLMProviderError:
            providerError
        case let urlError as URLError:
            LLMProviderError.transport(urlError.localizedDescription)
        default:
            LLMProviderError.transport(error.localizedDescription)
        }
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaRequestMessage]
    let stream: Bool
    let tools: [ToolDefinition]?
}

private struct OllamaRequestMessage: Encodable {
    let role: ChatRole
    let content: String
    let toolCalls: [OllamaRequestToolCall]?
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }
}

private struct OllamaRequestToolCall: Encodable {
    let type: String
    let function: OllamaRequestFunction
}

private struct OllamaRequestFunction: Encodable {
    let index: Int
    let name: String
    let arguments: JSONValue
}
