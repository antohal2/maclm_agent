import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class WorkspaceMigrationTests: XCTestCase {
    func testMigrationOfExplicitRealStoreCopy() throws {
        // This fixed path is a pre-created copy, never the user's application store.
        let source = URL(fileURLWithPath: "/tmp/maclm-44-migration-source")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Explicit migration fixture not present")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration44-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let input = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: input.path) {
                try FileManager.default.copyItem(at: input, to: destination.appendingPathComponent(name))
            }
        }
        let configuration = ModelConfiguration(url: destination.appendingPathComponent("default.store"))
        let container = try makeContainer(configuration: configuration)
        let context = container.mainContext
        try verifyCounts(context: context, source: source)
        let rules = try context.fetch(FetchDescriptor<SecurityRule>())
        XCTAssertTrue(rules.allSatisfy { $0.project == nil && !$0.isMandatory })
        let count = try context.fetchCount(FetchDescriptor<Conversation>())
        try ApplicationProtection.ensure(context: context, storeURL: configuration.url, bundleID: "local.maclm-agent")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SecurityRule>()).filter(\.isMandatory).count, 4)
        try context.save()
        let reopened = try makeContainer(configuration: configuration)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Conversation>()), count)
        print("4.4 migration copy verified; conversations preserved: \(count), legacy rules: \(rules.count)")
    }

    private func verifyCounts(context: ModelContext, source: URL) throws {
        let expected = try JSONDecoder().decode(
            [String: Int].self,
            from: Data(contentsOf: source.appendingPathComponent("entity-counts.json"))
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), expected["ZCONVERSATION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), expected["ZPROJECT"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), expected["ZMESSAGE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolCall>()), expected["ZTOOLCALL"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipboardAction>()), expected["ZCLIPBOARDACTION"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SecurityRule>()), expected["ZSECURITYRULE"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditEntry>()), expected["ZAUDITENTRY"])
    }

    private func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            configurations: configuration
        )
    }
}
