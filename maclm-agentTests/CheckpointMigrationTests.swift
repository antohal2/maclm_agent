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

@MainActor final class SchemaSnapshotTests: XCTestCase {
    func testSchemaSnapshot() throws {
        let container = try ModelContainer(
            for: Conversation.self, Project.self, Message.self, ToolCall.self,
            ClipboardAction.self, SecurityRule.self, AuditEntry.self, Checkpoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let snapshot = container.schema.entities.flatMap { entity -> [String] in
            var lines = ["entity|\(entity.name)"]
            for attribute in entity.attributes {
                let fields = [
                    "attribute", entity.name, attribute.name,
                    String(reflecting: attribute.valueType), String(attribute.isOptional),
                ]
                lines.append(fields.joined(separator: "|"))
            }
            for relationship in entity.relationships {
                let fields = [
                    "relationship", entity.name, relationship.name,
                    String(reflecting: relationship.valueType), relationship.destination,
                    relationship.inverseName ?? "nil", relationship.deleteRule.rawValue,
                    relationship.minimumModelCount.map(String.init) ?? "nil",
                    relationship.maximumModelCount.map(String.init) ?? "nil",
                ]
                lines.append(fields.joined(separator: "|"))
            }
            return lines
        }.sorted().joined(separator: "\n")
        XCTAssertEqual(snapshot, Self.expectedSchema)
    }

    func testPersistedCodableKeysAndValues() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ value: some Encodable) throws -> String {
            try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
        }
        let item = CheckpointItem(
            originalPath: "/original", existedBefore: true, isDirectory: false,
            storedRelativePath: "stored", sha256: "digest"
        )
        XCTAssertEqual(
            try json(item),
            // Fixed pre-cleanup JSON encoding snapshot.
            // swiftlint:disable:next line_length
            #"{"existedBefore":true,"isDirectory":false,"originalPath":"\/original","sha256":"digest","storedRelativePath":"stored"}"#
        )
        XCTAssertEqual(try json(CheckpointItem(
            originalPath: "original", existedBefore: false, isDirectory: true
        )), #"{"existedBefore":false,"isDirectory":true,"originalPath":"original"}"#)
        let shell = try await RunShellTool().execute(
            arguments: ["command": "printf out; printf err >&2; exit 7"], invocation: .init(conversationID: UUID())
        )
        let shellJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(shell.content.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(shellJSON.keys), ["stdout", "stderr", "exitCode", "timedOut"])
        XCTAssertEqual(shellJSON["stdout"] as? String, "out")
        XCTAssertEqual(shellJSON["stderr"] as? String, "err")
        XCTAssertEqual(shellJSON["exitCode"] as? Int, 7)
        XCTAssertEqual(shellJSON["timedOut"] as? Bool, false)
        XCTAssertEqual(
            try AuditDecision.allCases.map { try json($0) },
            [#""approved""#, #""rejected""#, #""auto""#, #""blocked""#, #""userInitiated""#]
        )
        let outcomes: [AuditOutcome] = [.success, .failure, .cancelled, .notExecuted]
        XCTAssertEqual(
            try outcomes.map { try json($0) },
            [#""success""#, #""failure""#, #""cancelled""#, #""notExecuted""#]
        )
    }

    /// Captured from the in-memory container at v0.4.7.1 before lint cleanup.
    private static let expectedSchema = """
    attribute|AuditEntry|argumentsJSON|Swift.String|false
    attribute|AuditEntry|checkpointID|Swift.Optional<Foundation.UUID>|true
    attribute|AuditEntry|conversationID|Swift.Optional<Foundation.UUID>|true
    attribute|AuditEntry|decisionRaw|Swift.String|false
    attribute|AuditEntry|durationMilliseconds|Swift.Optional<Swift.Int>|true
    attribute|AuditEntry|elevationReason|Swift.Optional<Swift.String>|true
    attribute|AuditEntry|errorDescription|Swift.Optional<Swift.String>|true
    attribute|AuditEntry|id|Foundation.UUID|false
    attribute|AuditEntry|matchedRuleDescription|Swift.Optional<Swift.String>|true
    attribute|AuditEntry|outcome|maclm_agent.AuditOutcome|false
    attribute|AuditEntry|resultSummary|Swift.String|false
    attribute|AuditEntry|riskRaw|Swift.Int|false
    attribute|AuditEntry|timestamp|Foundation.Date|false
    attribute|AuditEntry|toolCallID|Swift.Optional<Foundation.UUID>|true
    attribute|AuditEntry|toolName|Swift.String|false
    attribute|Checkpoint|conversationID|Swift.Optional<Foundation.UUID>|true
    attribute|Checkpoint|createdAt|Foundation.Date|false
    attribute|Checkpoint|id|Foundation.UUID|false
    attribute|Checkpoint|isRestored|Swift.Bool|false
    attribute|Checkpoint|items|Swift.Array<maclm_agent.CheckpointItem>|false
    attribute|Checkpoint|postOperation|Swift.Optional<Swift.Array<maclm_agent.FileFingerprint>>|true
    attribute|Checkpoint|toolName|Swift.String|false
    attribute|Checkpoint|totalBytes|Swift.Int64|false
    attribute|ClipboardAction|createdAt|Foundation.Date|false
    attribute|ClipboardAction|iconSystemName|Swift.String|false
    attribute|ClipboardAction|id|Foundation.UUID|false
    attribute|ClipboardAction|isBuiltIn|Swift.Bool|false
    attribute|ClipboardAction|isEnabled|Swift.Bool|false
    attribute|ClipboardAction|name|Swift.String|false
    attribute|ClipboardAction|promptTemplate|Swift.String|false
    attribute|ClipboardAction|sortOrder|Swift.Int|false
    attribute|ClipboardAction|updatedAt|Foundation.Date|false
    attribute|Conversation|createdAt|Foundation.Date|false
    attribute|Conversation|hasUnreadResult|Swift.Bool|false
    attribute|Conversation|id|Foundation.UUID|false
    attribute|Conversation|isArchived|Swift.Bool|false
    attribute|Conversation|isPinned|Swift.Bool|false
    attribute|Conversation|lastContextTokens|Swift.Optional<Swift.Int>|true
    attribute|Conversation|modelID|Swift.Optional<Swift.String>|true
    attribute|Conversation|providerID|Swift.Optional<Swift.String>|true
    attribute|Conversation|titleIsManual|Swift.Bool|false
    attribute|Conversation|title|Swift.String|false
    attribute|Conversation|updatedAt|Foundation.Date|false
    attribute|Message|content|Swift.String|false
    attribute|Message|id|Foundation.UUID|false
    attribute|Message|roleRawValue|Swift.String|false
    attribute|Message|timestamp|Foundation.Date|false
    attribute|Message|toolCallID|Swift.Optional<Swift.String>|true
    attribute|Project|createdAt|Foundation.Date|false
    attribute|Project|id|Foundation.UUID|false
    attribute|Project|instructions|Swift.String|false
    attribute|Project|name|Swift.String|false
    attribute|Project|sortOrder|Swift.Int|false
    attribute|Project|workingDirectoryPath|Swift.Optional<Swift.String>|true
    attribute|SecurityRule|action|maclm_agent.RuleAction|false
    attribute|SecurityRule|createdAt|Foundation.Date|false
    attribute|SecurityRule|dimension|maclm_agent.RuleDimension|false
    attribute|SecurityRule|isBuiltIn|Swift.Bool|false
    attribute|SecurityRule|isEnabled|Swift.Bool|false
    attribute|SecurityRule|isMandatory|Swift.Bool|false
    attribute|SecurityRule|order|Swift.Int|false
    attribute|SecurityRule|pattern|Swift.String|false
    attribute|SecurityRule|ruleDescription|Swift.String|false
    attribute|ToolCall|argumentsJSON|Swift.String|false
    attribute|ToolCall|confirmationRiskRawValue|Swift.Optional<Swift.Int>|true
    attribute|ToolCall|confirmationRiskReason|Swift.Optional<Swift.String>|true
    attribute|ToolCall|filePreview|Swift.Optional<maclm_agent.FilePreview>|true
    attribute|ToolCall|id|Foundation.UUID|false
    attribute|ToolCall|providerCallID|Swift.Optional<Swift.String>|true
    attribute|ToolCall|resultJSON|Swift.Optional<Swift.String>|true
    attribute|ToolCall|statusRawValue|Swift.String|false
    attribute|ToolCall|timestamp|Foundation.Date|false
    attribute|ToolCall|toolName|Swift.String|false
    entity|AuditEntry
    entity|Checkpoint
    entity|ClipboardAction
    entity|Conversation
    entity|Message
    entity|Project
    entity|SecurityRule
    entity|ToolCall
    relationship|Conversation|messages|Swift.Array<maclm_agent.Message>|Message|conversation|cascade|0|0
    relationship|Conversation|project|Swift.Optional<maclm_agent.Project>|Project|conversations|nullify|nil|nil
    relationship|Message|conversation|Swift.Optional<maclm_agent.Conversation>|Conversation|messages|nullify|nil|nil
    relationship|Message|toolCalls|Swift.Array<maclm_agent.ToolCall>|ToolCall|message|cascade|0|0
    relationship|Project|conversations|Swift.Array<maclm_agent.Conversation>|Conversation|project|nullify|0|0
    relationship|SecurityRule|project|Swift.Optional<maclm_agent.Project>|Project|nil|nullify|nil|nil
    relationship|ToolCall|message|Swift.Optional<maclm_agent.Message>|Message|toolCalls|nullify|nil|nil
    """
}

@MainActor final class CheckpointTraceSnapshotTests: XCTestCase {
    func testTracePrefersExactIDsOverOrderAndArguments() {
        let first = ToolCall(toolName: "write_file", argumentsJSON: "{}", status: .failed)
        let second = ToolCall(toolName: "write_file", argumentsJSON: "{}", status: .completed)
        let blocked = AuditEntry(AuditRecord(
            toolName: "write_file",
            argumentsJSON: "different",
            decision: .blocked,
            toolCallID: first.id
        ))
        let allowed = AuditEntry(AuditRecord(
            toolName: "write_file",
            argumentsJSON: "{}",
            riskLevel: .dangerous,
            decision: .approved,
            toolCallID: second.id
        ))
        XCTAssertEqual(
            TraceIncidents.count(calls: [first, second], audits: [allowed, blocked]),
            TraceIncidents(rejected: 0, blocked: 1, dangerous: 1, errors: 0)
        )
    }
}
