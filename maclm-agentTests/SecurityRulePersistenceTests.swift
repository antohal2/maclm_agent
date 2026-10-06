import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor
final class SecurityRulePersistenceTests: XCTestCase {
    func testSeedingIsIdempotentAndPreservesUserRules() throws {
        let container = try ModelContainer(for: SecurityRule.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(SecurityRule(dimension: .host, pattern: "example.test", action: .allow))
        try context.save()
        try SecurityRuleSeeder.seedIfNeeded(context: context)
        let first = try SecurityRuleSeeder.snapshots(context: context)
        XCTAssertEqual(first.count, DefaultSecurityRules.rules.count + 1)
        XCTAssertEqual(first.filter(\.isBuiltIn).map(\.order).sorted(), Array(0 ..< DefaultSecurityRules.rules.count))
        let builtIn = try XCTUnwrap(context.fetch(FetchDescriptor<SecurityRule>()).first(where: { $0.isBuiltIn }))
        builtIn.isEnabled = false
        try context.save()
        try SecurityRuleSeeder.seedIfNeeded(context: context)
        XCTAssertEqual(try SecurityRuleSeeder.snapshots(context: context).count, first.count)
        XCTAssertFalse(builtIn.isEnabled)
    }

    func testAllDimensionsRoundTripOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.store")
        func write() throws {
            let container = try ModelContainer(for: SecurityRule.self, configurations: .init(url: url))
            for (index, dimension) in RuleDimension.allCases.enumerated() {
                container.mainContext.insert(SecurityRule(
                    dimension: dimension,
                    pattern: "pattern-\(index)",
                    action: index % 2 == 0 ? .block : .allow,
                    order: index,
                    ruleDescription: "description-\(index)"
                ))
            }
            try container.mainContext.save()
        }
        try write()
        let reopened = try ModelContainer(for: SecurityRule.self, configurations: .init(url: url))
        let rules = try reopened.mainContext.fetch(FetchDescriptor<SecurityRule>(sortBy: [SortDescriptor(\.order)]))
        XCTAssertEqual(rules.map(\.dimension), RuleDimension.allCases)
        XCTAssertEqual(rules.map(\.action), [.block, .allow, .block, .allow])
        XCTAssertEqual(rules.map(\.ruleDescription), (0 ..< 4).map { "description-\($0)" })
    }

    func testAutomaticAdditiveMigrationPreservesV030Store() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("upgrade.store")
        let conversationID = UUID()
        let actionID = UUID()
        func createOldStore() throws {
            let schema = Schema([Conversation.self, Message.self, ToolCall.self, ClipboardAction.self])
            let container = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
            let conversation = Conversation(id: conversationID, title: "Keep conversation")
            let call = ToolCall(
                toolName: "read_file",
                argumentsJSON: "{}",
                resultJSON: "old result",
                status: .completed
            )
            let message = Message(role: .assistant, content: "Keep message", toolCalls: [call])
            conversation.messages.append(message)
            container.mainContext.insert(conversation)
            container.mainContext.insert(ClipboardAction(
                id: actionID,
                name: "Keep action",
                promptTemplate: "{{input}}",
                iconSystemName: "star",
                sortOrder: 0
            ))
            try container.mainContext.save()
        }
        try createOldStore()
        let schema = Schema([Conversation.self, Message.self, ToolCall.self, ClipboardAction.self, SecurityRule.self])
        let upgraded = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
        try SecurityRuleSeeder.seedIfNeeded(context: upgraded.mainContext)
        let conversations = try upgraded.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, conversationID)
        XCTAssertEqual(conversations.first?.title, "Keep conversation")
        XCTAssertEqual(conversations.first?.messages.first?.content, "Keep message")
        XCTAssertEqual(conversations.first?.messages.first?.toolCalls.first?.resultJSON, "old result")
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<ClipboardAction>()).first?.id, actionID)
        XCTAssertEqual(
            try upgraded.mainContext.fetchCount(FetchDescriptor<SecurityRule>()),
            DefaultSecurityRules.rules.count
        )
    }
}
