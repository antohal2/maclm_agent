import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SessionContextMigrationTests: XCTestCase {
    func testRealV046StoreCopyMigrationPreservesRowsAndDefaults() throws {
        let source = URL(fileURLWithPath: "/tmp/maclm-47-migration-source")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Explicit v0.4.6 real-store copy not present")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration47-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: source.appendingPathComponent("default.store"), to: url)
        let counts = try JSONDecoder().decode(
            [String: Int].self,
            from: Data(contentsOf: source.appendingPathComponent("counts.json"))
        )
        let store = try container(at: url), context = store.mainContext
        try verifyCounts(context, expected: counts)
        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertTrue(conversations
            .allSatisfy { $0.modelID == nil && $0.providerID == nil && $0.lastContextTokens == nil })
        let editedID = conversations.first?.id
        conversations.first?.modelID = "migration-test"
        conversations.first?.providerID = "lmStudio|http://localhost:1234"
        conversations.first?.lastContextTokens = 23
        try context.save()
        let reopened = try container(at: url)
        XCTAssertEqual(
            try reopened.mainContext.fetchCount(FetchDescriptor<Checkpoint>()),
            counts["ZCHECKPOINT"] ?? 0
        )
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Conversation>()), counts["ZCONVERSATION"])
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<Conversation>()).first { $0.id == editedID }?
                .lastContextTokens,
            23
        )
        XCTAssertEqual(
            try reopened.mainContext.fetch(FetchDescriptor<Conversation>()).first { $0.id == editedID }?.modelID,
            "migration-test"
        )
        print("4.7 migration verified on real-store copy; preserved counts: \(counts)")
    }

    private func container(at url: URL) throws -> ModelContainer {
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

    private func verifyCounts(_ context: ModelContext, expected counts: [String: Int]) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), counts["ZCONVERSATION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), counts["ZPROJECT"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), counts["ZMESSAGE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolCall>()), counts["ZTOOLCALL"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipboardAction>()), counts["ZCLIPBOARDACTION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SecurityRule>()), counts["ZSECURITYRULE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditEntry>()), counts["ZAUDITENTRY"])
    }
}
