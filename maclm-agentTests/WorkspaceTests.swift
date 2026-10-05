import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self,
            Conversation.self,
            Message.self,
            ToolCall.self,
            AuditEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    func testOrderingAndArchive() {
        let old = Conversation(updatedAt: Date(timeIntervalSince1970: 1))
        let recent = Conversation(updatedAt: Date(timeIntervalSince1970: 3))
        let pinned = Conversation(updatedAt: Date(timeIntervalSince1970: 0))
        pinned.isPinned = true
        let archived = Conversation(updatedAt: Date(timeIntervalSince1970: 4))
        archived.isArchived = true
        XCTAssertEqual(
            SessionOrdering.sorted([recent, archived, old, pinned]).map(\.id),
            [pinned.id, recent.id, old.id]
        )
        XCTAssertEqual(
            SessionOrdering.sorted([recent, archived], showingArchive: true).map(\.id),
            [archived.id, recent.id]
        )
    }

    @MainActor
    func testProjectDeletionMovesSessionsByDefault() throws {
        let container = try container()
        let context = container.mainContext
        let model = ChatViewModel(modelContext: context)
        let project = Project(name: "Test")
        model.saveProject(project)
        let session = model.createConversation(project: project)
        model.deleteProject(project)
        XCTAssertNil(session.project)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Conversation>()).contains { $0.id == session.id })
    }

    @MainActor
    func testDeletingProjectAndConversationPreservesAudit() throws {
        let container = try container()
        let context = container.mainContext
        let model = ChatViewModel(modelContext: context)
        let project = Project(name: "Test")
        model.saveProject(project)
        let session = model.createConversation(project: project)
        let id = session.id
        context.insert(Message(role: .user, content: "test", conversation: session))
        context.insert(AuditEntry(AuditRecord(toolName: "read_file", argumentsJSON: "{}", conversationID: id)))
        try context.save()
        model.deleteProject(project, includingConversations: true)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Conversation>()).contains { $0.id == id })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Message>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).first?.conversationID, id)
        let another = model.createConversation()
        let secondID = another.id
        context.insert(AuditEntry(AuditRecord(toolName: "read_file", argumentsJSON: "{}", conversationID: secondID)))
        model.deleteConversation(another)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).count, 2)
    }

    func testWorkingDirectoryValidation() throws {
        XCTAssertEqual(WorkingDirectoryValidator.validate("/"), .invalid("Корневая папка запрещена."))
        XCTAssertEqual(WorkingDirectoryValidator.validate("relative"), .invalid("Укажите абсолютный путь к папке."))
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        XCTAssertEqual(WorkingDirectoryValidator.validate(home), .requiresConfirmation(home))
        for system in ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"] {
            let canonical = URL(fileURLWithPath: system).resolvingSymlinksInPath().path
            XCTAssertEqual(WorkingDirectoryValidator.validate(system), .requiresConfirmation(canonical))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(
            WorkingDirectoryValidator.validate(file.path),
            .invalid("Папка не существует или путь указывает на файл.")
        )
        XCTAssertEqual(
            WorkingDirectoryValidator.validate(root.appendingPathComponent("missing").path),
            .invalid("Папка не существует или путь указывает на файл.")
        )
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertEqual(WorkingDirectoryValidator.validate(link.path), .valid(root.resolvingSymlinksInPath().path))
        let rootLink = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(WorkingDirectoryValidator.validate(rootLink.path), .invalid("Корневая папка запрещена."))
    }

    func testSystemPromptComposition() {
        XCTAssertEqual(SystemPromptBuilder.build(base: "base"), "base")
        XCTAssertEqual(SystemPromptBuilder.build(base: "base", projectName: "A", instructions: " \n"), "base")
        XCTAssertEqual(
            SystemPromptBuilder.build(base: "base", projectName: "A", instructions: "rules"),
            "base\n\nИнструкции проекта «A»:\nrules"
        )
    }

    func testTitleCleanupAndFallback() {
        XCTAssertEqual(ConversationTitle.clean("**«Название беседы».**\nлишняя строка"), "Название беседы")
        XCTAssertEqual(
            ConversationTitle.clean("<think>reason\nmore</think>\n# \"Useful short title.\""),
            "Useful short title"
        )
        XCTAssertEqual(ConversationTitle.clean("<think>unfinished"), "")
        XCTAssertEqual(ConversationTitle.clean("```\n[Some title](https://example.invalid).\n```"), "Some title")
        XCTAssertEqual(ConversationTitle.clean("  \n **.**"), "")
        XCTAssertEqual(ConversationTitle.clean(String(repeating: "a", count: 80)).count, 60)
        XCTAssertEqual(ConversationTitle.fallback("  one   two three four", limit: 10), "one two…")
        XCTAssertEqual(ConversationTitle.fallback("one two three", limit: 7), "one two…")
        XCTAssertEqual(ConversationTitle.fallback("short"), "short")
    }

    @MainActor
    func testAutoTitleIsSeparateFromHistoryAndAudit() async throws {
        let container = try container()
        let context = container.mainContext
        let probe = WorkspaceProviderProbe()
        let model = ChatViewModel(modelContext: context, providerFactory: { WorkspaceProvider(probe: probe) })
        model.input = "first question"
        model.send()
        try await wait { model.selectedConversation?.title == "Useful short title" }
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.messages.map(\.content), ["first question", "Final answer"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<AuditEntry>()).isEmpty)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.first?.content, ConversationTitle.prompt)
        let toolCounts = await probe.toolCounts
        XCTAssertEqual(toolCounts.last, 0)
    }

    @MainActor
    func testNewMessageCancelsTitleWithoutBlockingGeneration() async throws {
        let container = try container()
        let probe = WorkspaceProviderProbe()
        let model = ChatViewModel(modelContext: container.mainContext, providerFactory: {
            WorkspaceProvider(probe: probe, slowTitle: true)
        })
        model.input = "first question"
        model.send()
        try await wait { !model.isGenerating }
        XCTAssertEqual(model.selectedConversation?.title, Conversation.defaultTitle)
        model.input = "second question"
        model.send()
        XCTAssertTrue(model.isGenerating)
        XCTAssertEqual(model.selectedConversation?.title, "first question")
        try await wait { !model.isGenerating }
        try await wait { await probe.titleCancelled }
        XCTAssertEqual(model.messages.filter { $0.role == .user }.count, 2)
    }

    @MainActor
    func testTitleErrorAndEmptyResultFallBack() async throws {
        for fail in [false, true] {
            let container = try container()
            let probe = WorkspaceProviderProbe()
            let model = ChatViewModel(modelContext: container.mainContext, providerFactory: {
                WorkspaceProvider(probe: probe, titleResponse: "<think>only reasoning</think>", failTitle: fail)
            })
            model.input = "fallback question"
            model.send()
            try await wait { model.selectedConversation?.title == "fallback question" }
            XCTAssertFalse(model.isGenerating)
            XCTAssertEqual(model.messages.count, 2)
        }
    }

    @MainActor
    func testTitleTimeoutAndManualRename() async throws {
        let container = try container()
        let probe = WorkspaceProviderProbe()
        let model = ChatViewModel(modelContext: container.mainContext, providerFactory: {
            WorkspaceProvider(probe: probe, slowTitle: true)
        }, titleTimeout: .milliseconds(30))
        model.input = "fallback question"
        model.send()
        try await wait { model.selectedConversation?.title == "fallback question" }
        try await wait { await probe.titleCancelled }
        let conversation = model.createConversation()
        model.input = "another question"
        model.send()
        try await wait { !model.isGenerating }
        model.renameConversation(conversation, to: "Manual title")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(conversation.titleIsManual)
        XCTAssertEqual(conversation.title, "Manual title")
    }

    @MainActor
    func testDeleteActiveConversationStopsBeforeDeleting() async throws {
        let container = try container()
        let context = container.mainContext
        let probe = WorkspaceProviderProbe()
        let model = ChatViewModel(modelContext: context, providerFactory: {
            WorkspaceProvider(probe: probe, slowAnswer: true)
        })
        let id = try XCTUnwrap(model.selectedConversationID)
        model.input = "first question"
        model.send()
        try await wait { model.messages.last?.content == "partial" }
        try model.deleteConversation(XCTUnwrap(model.selectedConversation))
        try await wait { !model.isGenerating }
        XCTAssertFalse(try context.fetch(FetchDescriptor<Conversation>()).contains { $0.id == id })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Message>()).isEmpty)
        try await wait { await probe.answerCancelled }
    }

    @MainActor
    func testProjectInstructionsReachProviderAndMoveDoesNotStop() async throws {
        let container = try container()
        let probe = WorkspaceProviderProbe()
        let model = ChatViewModel(modelContext: container.mainContext, providerFactory: {
            WorkspaceProvider(probe: probe, slowAnswer: true)
        })
        let project = Project(name: "Ops", instructions: "Keep evidence")
        model.saveProject(project)
        let conversation = model.createConversation(project: project)
        model.input = "test"
        model.send()
        try await wait { model.messages.last?.content == "partial" }
        let requests = await probe.requests
        XCTAssertEqual(requests.first?.first?.content, "Инструкции проекта «Ops»:\nKeep evidence")
        model.moveConversation(conversation, to: nil)
        model.renameConversation(conversation, to: "Manual")
        XCTAssertTrue(model.isGenerating)
        model.toggleArchive(conversation)
        try await wait { !model.isGenerating }
        XCTAssertTrue(conversation.isArchived)
        XCTAssertEqual(conversation.title, "Manual")
    }

    @MainActor
    func testDeleteProjectWhileWaitingForApprovalStopsAndRetainsAudit() async throws {
        let container = try container()
        let context = container.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        let model = ChatViewModel(modelContext: context, agentLoop: loop, providerFactory: { WorkspaceToolProvider() })
        let project = Project(name: "Waiting project")
        model.saveProject(project)
        let conversation = model.createConversation(project: project)
        let id = conversation.id
        model.input = "request approval"
        model.send()
        try await wait { model.messages.last?.toolCalls.first?.status == .pending }
        model.deleteProject(project, includingConversations: true)
        try await wait { !model.isGenerating }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).isEmpty)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Conversation>()).contains { $0.id == id })
        let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first)
        XCTAssertEqual(audit.conversationID, id)
        XCTAssertEqual(audit.outcome, .cancelled)
    }

    @MainActor
    func testTitleAfterToolCycleUsesFinalAnswer() async throws {
        let container = try container()
        let context = container.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        let model = ChatViewModel(modelContext: context, agentLoop: loop, providerFactory: { WorkspaceToolProvider() })
        model.input = "request tool"
        model.send()
        try await wait { model.messages.last?.toolCalls.first?.status == .pending }
        let call = try XCTUnwrap(model.messages.last?.toolCalls.first)
        model.resolveConfirmation(toolCallID: call.id, decision: .rejected)
        try await wait { model.selectedConversation?.title == "Tool cycle title" }
        XCTAssertEqual(model.messages.last?.content, "Final tool answer")
        XCTAssertEqual(model.messages.count, 4)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).count, 1)
    }

    @MainActor
    func testProviderUnavailableFallsBackWithoutManualFlag() throws {
        let container = try container()
        let model = ChatViewModel(
            modelContext: container.mainContext,
            providerFactory: { throw LLMProviderError.invalidResponse }
        )
        model.input = "offline question"
        model.send()
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.selectedConversation?.title, "offline question")
        XCTAssertEqual(model.selectedConversation?.titleIsManual, false)
    }
}

extension WorkspaceTests {
    @MainActor
    func testMigrationFromPreviousVersionFixture() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "workspace-v0.4.1", withExtension: "store"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("copy.store")
        try FileManager.default.copyItem(at: source, to: destination)
        let container = try ModelContainer(
            for: Project.self,
            Conversation.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            configurations: ModelConfiguration(url: destination)
        )
        let context = container.mainContext
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(conversation.title, "Legacy fixture")
        XCTAssertNil(conversation.project)
        XCTAssertFalse(conversation.isPinned)
        XCTAssertFalse(conversation.isArchived)
        XCTAssertFalse(conversation.titleIsManual)
        XCTAssertEqual(conversation.orderedMessages.count, 2)
        XCTAssertEqual(conversation.orderedMessages.first?.content, "Synthetic old message")
        let call = try XCTUnwrap(context.fetch(FetchDescriptor<ToolCall>()).first)
        XCTAssertEqual(call.status, .completed)
        XCTAssertEqual(call.resultJSON, "fixture")
        XCTAssertEqual(call.message?.role, .assistant)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AuditEntry>()).count, 1)
    }

    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor WorkspaceProviderProbe {
    var requests: [[ChatMessage]] = []
    var toolCounts: [Int] = []
    var titleCancelled = false
    var answerCancelled = false
    func record(_ messages: [ChatMessage], tools: Int) {
        requests.append(messages)
        toolCounts.append(tools)
    }

    func cancelled(title: Bool) {
        if title {
            titleCancelled = true
        } else {
            answerCancelled = true
        }
    }
}

private struct WorkspaceProvider: LLMProvider {
    let name = "workspace-test"
    let probe: WorkspaceProviderProbe
    var slowTitle = false
    var slowAnswer = false
    var titleResponse = "<think>Reasoning</think>\n**Useful short title.**"
    var failTitle = false
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let title = messages.first?.content == ConversationTitle.prompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(messages, tools: tools.count)
                do {
                    if title && slowTitle || !title && slowAnswer {
                        if !title {
                            continuation.yield(.contentDelta("partial"))
                        }
                        try await Task.sleep(for: .seconds(60))
                    }
                    if title, failTitle {
                        throw LLMProviderError.invalidResponse
                    }
                    continuation.yield(.contentDelta(title ? titleResponse : "Final answer"))
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    await probe.cancelled(title: title)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct WorkspaceToolProvider: LLMProvider {
    let name = "workspace-tool-test"
    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if tools.isEmpty {
                continuation
                    .yield(.contentDelta(messages.last?.content
                            .contains("Final tool answer") == true ? "Tool cycle title" : "Wrong answer"))
            } else if messages.last?.role == .tool {
                continuation.yield(.contentDelta("Final tool answer"))
            } else {
                continuation.yield(.toolCallDelta(.init(
                    index: 0,
                    id: "test-call",
                    type: "function",
                    functionName: "run_shell",
                    argumentsDelta: "{}"
                )))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
