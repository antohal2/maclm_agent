import Foundation

struct SSEParser {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [ChatStreamEvent] {
        buffer.append(data)

        var events: [ChatStreamEvent] = []
        while let delimiter = nextDelimiterRange() {
            let eventData = buffer[..<delimiter.lowerBound]
            buffer.removeSubrange(..<delimiter.upperBound)
            try events.append(contentsOf: parseEvent(Data(eventData)))
        }

        return events
    }

    mutating func finish() throws -> [ChatStreamEvent] {
        guard !buffer.isEmpty else {
            return []
        }

        defer { buffer.removeAll(keepingCapacity: false) }
        return try parseEvent(buffer)
    }

    private func nextDelimiterRange() -> Range<Data.Index>? {
        let lineFeedDelimiter = Data([0x0A, 0x0A])
        let carriageReturnDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lineFeedRange = buffer.range(of: lineFeedDelimiter)
        let carriageReturnRange = buffer.range(of: carriageReturnDelimiter)

        switch (lineFeedRange, carriageReturnRange) {
        case let (lineFeed?, carriageReturn?):
            return lineFeed.lowerBound < carriageReturn.lowerBound ? lineFeed : carriageReturn
        case let (lineFeed?, nil):
            return lineFeed
        case let (nil, carriageReturn?):
            return carriageReturn
        case (nil, nil):
            return nil
        }
    }

    private func parseEvent(_ data: Data) throws -> [ChatStreamEvent] {
        guard let event = String(data: data, encoding: .utf8) else {
            throw LLMProviderError.invalidSSEPayload("данные не являются UTF-8")
        }

        let payload = event
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                var line = String(rawLine)
                if line.last == "\r" {
                    line.removeLast()
                }
                guard line.hasPrefix("data:") else {
                    return nil
                }
                return String(line.dropFirst(5)).trimmingPrefix(" ")
            }
            .joined(separator: "\n")

        guard !payload.isEmpty else {
            return []
        }
        guard payload != "[DONE]" else {
            return [.done]
        }

        do {
            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(payload.utf8))
            return chunk.choices.flatMap { choice in
                var events: [ChatStreamEvent] = []
                if let content = choice.delta.content, !content.isEmpty {
                    events.append(.contentDelta(content))
                }
                events.append(contentsOf: choice.delta.toolCalls?.map { toolCall in
                    .toolCallDelta(
                        ToolCallDelta(
                            index: toolCall.index,
                            id: toolCall.id,
                            type: toolCall.type,
                            functionName: toolCall.function?.name,
                            argumentsDelta: toolCall.function?.arguments
                        )
                    )
                } ?? [])
                return events
            }
        } catch {
            throw LLMProviderError.invalidSSEPayload(payload)
        }
    }
}

private struct ChatCompletionChunk: Decodable {
    let choices: [ChatCompletionChoice]
}

private struct ChatCompletionChoice: Decodable {
    let delta: ChatCompletionDelta
}

private struct ChatCompletionDelta: Decodable {
    let content: String?
    let toolCalls: [ChatCompletionToolCall]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private struct ChatCompletionToolCall: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: ChatCompletionFunction?
}

private struct ChatCompletionFunction: Decodable {
    let name: String?
    let arguments: String?
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
