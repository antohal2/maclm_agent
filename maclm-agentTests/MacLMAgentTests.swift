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

    func testOllamaNDJSONParserParsesContentAcrossNetworkChunks() throws {
        var parser = OllamaNDJSONParser()
        let firstChunk = Data(
            #"{"message":{"role":"assistant","content":"При"#.utf8
        )
        let secondChunk = Data(
            #"вет"},"done":false}"#.utf8
        )

        XCTAssertEqual(try parser.append(firstChunk), [])
        XCTAssertEqual(try parser.append(secondChunk), [])
        XCTAssertEqual(try parser.append(Data("\n".utf8)), [.contentDelta("Привет")])
    }

    func testOllamaNDJSONParserMapsToolCallAndDone() throws {
        var parser = OllamaNDJSONParser()
        let toolCallChunk =
            #"{"message":{"role":"assistant","content":"","tool_calls":["#
                + #"{"function":{"index":3,"name":"read_file","arguments":{"path":"/tmp/example"}}}"#
                + #"]},"done":false}"#
        let doneChunk = #"{"message":{"role":"assistant","content":""},"done":true}"#
        let payload = "\(toolCallChunk)\n\(doneChunk)\n"

        let events = try parser.append(Data(payload.utf8))
        let toolCallEvent = ChatStreamEvent.toolCallDelta(
            ToolCallDelta(
                index: 3,
                id: nil,
                type: "function",
                functionName: "read_file",
                argumentsDelta: #"{"path":"/tmp/example"}"#
            )
        )

        XCTAssertEqual(events, [toolCallEvent, .done])
    }

    func testOllamaNDJSONParserRejectsInvalidJSON() {
        var parser = OllamaNDJSONParser()

        XCTAssertThrowsError(try parser.append(Data("{invalid}\n".utf8))) { error in
            XCTAssertEqual(
                error as? LLMProviderError,
                .invalidNDJSONPayload("{invalid}")
            )
        }
    }

    func testProviderSelectionUsesDetectedProviderWhenNothingWasSaved() throws {
        let ollama = try DetectedProvider(
            provider: .ollama,
            availableModels: ["qwen3:8b"],
            baseURL: XCTUnwrap(URL(string: "http://localhost:11434"))
        )

        let selection = ProviderSelectionResolver.resolve(saved: nil, detected: [ollama])

        XCTAssertEqual(
            selection,
            ProviderSelection(
                provider: .ollama,
                baseURL: ollama.baseURL,
                model: "qwen3:8b"
            )
        )
    }

    func testProviderSelectionPrefersSavedUserDefaultsChoice() throws {
        let suiteName = "MacLMAgentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderSelectionStore(defaults: defaults)
        let saved = try ProviderSelection(
            provider: .ollama,
            baseURL: XCTUnwrap(URL(string: "http://localhost:11434")),
            model: "llama3.2:3b"
        )
        store.save(saved)
        let lmStudio = try DetectedProvider(
            provider: .lmStudio,
            availableModels: ["local-model"],
            baseURL: XCTUnwrap(URL(string: "http://localhost:1234"))
        )
        let ollama = DetectedProvider(
            provider: .ollama,
            availableModels: ["llama3.2:3b", "qwen3:8b"],
            baseURL: saved.baseURL
        )
        let detected = [lmStudio, ollama]

        let selection = ProviderSelectionResolver.resolve(
            saved: store.load(),
            detected: detected
        )

        XCTAssertEqual(selection, saved)
    }

    func testProviderSelectionKeepsSavedManualEndpointWhenNotDetected() throws {
        let saved = try ProviderSelection(
            provider: .lmStudio,
            baseURL: XCTUnwrap(URL(string: "http://192.168.1.10:8080/v1")),
            model: "remote-model"
        )
        let detectedProvider = try DetectedProvider(
            provider: .ollama,
            availableModels: ["qwen3:8b"],
            baseURL: XCTUnwrap(URL(string: "http://localhost:11434"))
        )
        let detected = [detectedProvider]

        XCTAssertEqual(
            ProviderSelectionResolver.resolve(saved: saved, detected: detected),
            saved
        )
    }

    func testProviderSelectionFallsBackWhenSavedModelDisappeared() throws {
        let saved = try ProviderSelection(
            provider: .ollama,
            baseURL: XCTUnwrap(URL(string: "http://localhost:11434")),
            model: "removed:latest"
        )
        let detectedProvider = DetectedProvider(
            provider: .ollama,
            availableModels: ["available:latest"],
            baseURL: saved.baseURL
        )
        let detected = [detectedProvider]

        XCTAssertEqual(
            ProviderSelectionResolver.resolve(saved: saved, detected: detected)?.model,
            "available:latest"
        )
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
            id: "provider_call_42",
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
    func testToolMessageDTOConversionPreservesToolCallID() {
        let dto = ChatMessage(
            role: .tool,
            content: "result",
            toolCallID: "provider_call_42"
        )

        let message = Message(chatMessage: dto)

        XCTAssertEqual(message.chatMessage, dto)
    }

    @MainActor
    func testChatViewModelRestoresMostRecentConversation() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let olderConversation = Conversation(
            title: "Старая",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let recentConversation = Conversation(
            title: "Активная",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(olderConversation)
        context.insert(recentConversation)
        try context.save()

        let viewModel = ChatViewModel(modelContext: context)

        XCTAssertEqual(viewModel.selectedConversationID, recentConversation.id)
    }

    @MainActor
    func testChatViewModelCreatesConversationForEmptyStore() throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)

        let viewModel = ChatViewModel(modelContext: context)
        let conversations = try context.fetch(FetchDescriptor<Conversation>())

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(viewModel.selectedConversationID, conversations.first?.id)
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
