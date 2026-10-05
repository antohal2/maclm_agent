import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class CheckpointMigrationTests: XCTestCase {
    func testRealV045StoreCopyMigrationPreservesRowsAndDefaults() throws {
        let source = URL(fileURLWithPath: "/tmp/maclm-46-migration-source")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Explicit v0.4.5 real-store copy not present")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration46-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: source.appendingPathComponent("default.store"), to: url)
        let counts = try JSONDecoder().decode(
            [String: Int].self,
            from: Data(contentsOf: source.appendingPathComponent("counts.json"))
        )
        func container() throws -> ModelContainer {
            try ModelContainer(
                for: Conversation.self,
                Project.self,
                Message.self,
                ToolCall.self,
                ClipboardAction.self,
                SecurityRule.self,
                AuditEntry.self,
                Checkpoint.self,
                configurations: ModelConfiguration(url: url)
            )
        }
        let store = try container(), context = store.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), counts["ZCONVERSATION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), counts["ZPROJECT"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), counts["ZMESSAGE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolCall>()), counts["ZTOOLCALL"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipboardAction>()), counts["ZCLIPBOARDACTION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SecurityRule>()), counts["ZSECURITYRULE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditEntry>()), counts["ZAUDITENTRY"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<AuditEntry>())
            .allSatisfy { $0.toolCallID == nil && $0.checkpointID == nil })
        XCTAssertTrue(try context.fetch(FetchDescriptor<ToolCall>()).allSatisfy { $0.filePreview == nil })
        let id = UUID()
        context.insert(Checkpoint(.init(id: id, conversationID: nil, toolName: "write_file", items: [], totalBytes: 0)))
        try context.save()
        let reopened = try container()
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Checkpoint>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Conversation>()), counts["ZCONVERSATION"])
        print("4.6 migration verified on real-store copy; preserved counts: \(counts)")
    }
}
