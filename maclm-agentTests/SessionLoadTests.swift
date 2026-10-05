import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class SessionLoadTests: XCTestCase {
    func testConcurrentDiskStreamingPreservesEveryDelta() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Conversation.self,
            Message.self,
            ToolCall.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("load.store"))
        )
        let model = ChatViewModel(modelContext: container.mainContext, providerFactory: { LoadProvider() })
        let firstRunner = try model.registry.runner(for: XCTUnwrap(model.selectedConversation))
        let secondRunner = model.registry.runner(for: model.createConversation())
        var longestGap = 0.0
        let clock = ContinuousClock()
        let heartbeat = Task { @MainActor in
            var previous = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = clock.now
                let elapsed = previous.duration(to: now).components
                longestGap = max(longestGap, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                previous = now
            }
        }
        let start = clock.now
        firstRunner.send("one")
        secondRunner.send("two")
        await firstRunner.waitUntilFinished()
        await secondRunner.waitUntilFinished()
        heartbeat.cancel()
        await heartbeat.value
        let duration = start.duration(to: clock.now).components
        let elapsedSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        print("SESSION_LOAD seconds=\(elapsedSeconds) max_main_gap_ms=\(longestGap * 1000)")
        XCTAssertEqual(firstRunner.messages.last?.content, String(repeating: "x", count: 1000))
        XCTAssertEqual(secondRunner.messages.last?.content, String(repeating: "x", count: 1000))
        let context = ModelContext(container)
        let saved = try context.fetch(FetchDescriptor<Message>()).filter { $0.role == .assistant }
        XCTAssertEqual(saved.map(\.content.count), [1000, 1000])
    }

    func testMigrationOnLocalRealV042Snapshot() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent("build/step43-validation/before.store")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Local real snapshot is intentionally excluded from Git")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("migration-copy.store")
        try FileManager.default.copyItem(at: source, to: path)
        let container = try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            configurations: ModelConfiguration(url: path)
        )
        let conversations = try container.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertFalse(conversations.isEmpty)
        XCTAssertTrue(conversations.allSatisfy { !$0.hasUnreadResult })
        print("SESSION_MIGRATION conversations=\(conversations.count)")
    }
}

private struct LoadProvider: LLMProvider {
    let name = "load fixture"
    func streamChat(messages _: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // No UI pacing: intentionally saturate the consumers.
            if !tools.isEmpty {
                for _ in 0 ..< 1000 {
                    continuation.yield(.contentDelta("x"))
                }
            } else {
                continuation.yield(.contentDelta("Load title"))
            }
            continuation.finish()
        }
    }
}
