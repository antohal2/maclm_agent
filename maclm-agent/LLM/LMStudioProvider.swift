import Foundation

struct LMStudioProvider: LLMProvider {
    let name = "LM Studio"
    let baseURL: URL
    let model: String

    private let session: URLSession

    init(
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        model: String = "local-model",
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
        var parser = SSEParser()
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

    private func makeRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) throws -> URLRequest {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased()) else {
            throw LLMProviderError.invalidBaseURL
        }

        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages.map(RequestMessage.init),
                stream: true,
                tools: tools.isEmpty ? nil : tools
            )
        )
        return request
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
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let stream: Bool
    let tools: [ToolDefinition]?
}

private struct RequestMessage: Encodable {
    let role: ChatRole
    let content: String
    let toolCalls: [ChatToolCall]?
    let toolCallID: String?

    init(_ message: ChatMessage) {
        role = message.role
        content = message.content
        toolCalls = message.toolCalls
        toolCallID = message.toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}
