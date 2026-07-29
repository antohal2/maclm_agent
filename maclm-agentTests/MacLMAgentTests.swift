import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class MacLMAgentTests: XCTestCase {
    func testSSEParserParsesContentDeltaAcrossNetworkChunks() throws {
        var parser = SSEParser()
        let firstChunk = Data(#"data: {"choices":[{"delta":{"content":"Hel"#.utf8)
        let secondChunk = Data(#"lo"}}]}"#.utf8)
        let terminator = Data("\n\n".utf8)

        XCTAssertEqual(try parser.append(firstChunk), [])
        XCTAssertEqual(try parser.append(secondChunk), [])
        XCTAssertEqual(try parser.append(terminator), [.contentDelta("Hello")])
    }

    func testSSEParserParsesDone() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("data: [DONE]\n\n".utf8))

        XCTAssertEqual(events, [.done])
    }

    func testSSEParserRejectsInvalidJSON() {
        var parser = SSEParser()

        XCTAssertThrowsError(try parser.append(Data("data: {invalid}\n\n".utf8))) { error in
            XCTAssertEqual(
                error as? LLMProviderError,
                .invalidSSEPayload("{invalid}")
            )
        }
    }

    func testConversationTitleGenerationNormalizesAndTruncatesContent() {
        XCTAssertEqual(
            Conversation.generatedTitle(from: "  Раз   два\nтри  "),
            "Раз два три"
        )

        let longContent = String(repeating: "а", count: 41)
        XCTAssertEqual(
            Conversation.generatedTitle(from: longContent),
            String(repeating: "а", count: 40) + "…"
        )
    }

    @MainActor
    func testConversationAndMessageCRUD() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1000)
        let conversation = Conversation(
            title: "Первоначальное название",
            createdAt: createdAt
        )
        let message = Message(
            role: .user,
            content: "Проверка сохранения",
            timestamp: createdAt.addingTimeInterval(1),
            conversation: conversation
        )

        context.insert(conversation)
        context.insert(message)
        try context.save()

        var conversations = try context.fetch(FetchDescriptor<Conversation>())
        var messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.content, "Проверка сохранения")
        XCTAssertEqual(messages.first?.conversation?.id, conversation.id)
        XCTAssertEqual(conversation.messages.map(\.id), [message.id])

        conversation.title = "Новое название"
        conversation.updatedAt = createdAt.addingTimeInterval(2)
        message.content = "Обновлённое сообщение"
        try context.save()

        conversations = try context.fetch(FetchDescriptor<Conversation>())
        messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(conversations.first?.title, "Новое название")
        XCTAssertEqual(messages.first?.content, "Обновлённое сообщение")

        context.delete(conversation)
        try context.save()

        conversations = try context.fetch(FetchDescriptor<Conversation>())
        messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    @MainActor
    func testMessageDTOConversionPreservesProviderFields() {
        let conversation = Conversation()
        let toolCall = ChatToolCall(
            id: UUID().uuidString,
            type: "function",
            function: ChatToolFunction(
                name: "read_file",
                arguments: #"{"path":"/tmp/example"}"#
            )
        )
        let dto = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "Готово",
            toolCalls: [toolCall]
        )

        let message = Message(chatMessage: dto, conversation: conversation)
        let convertedDTO = message.chatMessage

        XCTAssertEqual(convertedDTO.id, dto.id)
        XCTAssertEqual(convertedDTO.role, dto.role)
        XCTAssertEqual(convertedDTO.content, dto.content)
        XCTAssertEqual(convertedDTO.toolCalls, dto.toolCalls)
    }

    @MainActor
    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: configuration
        )
    }
}
