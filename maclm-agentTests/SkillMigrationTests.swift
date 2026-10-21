import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillMigrationTests: XCTestCase {
    func testPreSkillStoreMigratesPreservingConversationMessagesAndAudit() throws {
        try verifyMigration(fixture: "workspace-v0.4.1", title: "Legacy fixture")
    }

    func testV0501StorePreservesEnabledSkillMetadataAndSessionHistory() throws {
        try verifyMigration(fixture: "skills-v0.5.0.1", title: "Skills 5.0.1 fixture")
    }

    func testV052StoreMigratesAttachmentsAndAuditAndPersistsPinManifestAndSessionState() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "skills-v0.5.2", withExtension: "store"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-v053-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("upgrade.store")
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema([
            Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            Checkpoint.self,
            SkillRecord.self,
        ])
        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        }
        let container = try open()
        let context = container.mainContext
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        let project = try XCTUnwrap(conversation.project)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<SkillRecord>()).first)
        let (attachments, audit) = try verifyV052(conversation, project: project, record: record, context: context)
        project.pinnedSkillsData = conversation.attachedSkillsData
        let manifests = ["v052-enabled": [SkillFile(path: "SKILL.md", size: 12, digest: "digest")]]
        record.manifestsData = try JSONEncoder().encode(manifests)
        conversation.detachedPinnedSkillsData = Data("[\"sample\"]".utf8)
        conversation.skillCatalogOrderData = Data("[\"sample\",\"other\"]".utf8)
        try context.save()
        let reopened = try open()
        let saved = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(saved.id, conversation.id)
        XCTAssertEqual(saved.attachedSkillsData, conversation.attachedSkillsData)
        XCTAssertEqual(saved.declinedSkillsData, conversation.declinedSkillsData)
        XCTAssertEqual(saved.detachedPinnedSkillsData, conversation.detachedPinnedSkillsData)
        XCTAssertEqual(saved.skillCatalogOrderData, conversation.skillCatalogOrderData)
        XCTAssertEqual(saved.project?.pinnedSkills, attachments)
        let savedSkill = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<SkillRecord>()).first)
        XCTAssertEqual(savedSkill.manifestsData, record.manifestsData)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<AuditEntry>()).first?.id, audit.id)
    }

    private func verifyV052(
        _ conversation: Conversation, project: Project, record: SkillRecord, context: ModelContext
    ) throws -> ([SkillAttachment], AuditEntry) {
        XCTAssertEqual(conversation.title, "Skills 5.2 fixture")
        XCTAssertEqual(conversation.messages.first?.content, "Preserve history")
        XCTAssertEqual(project.instructions, "Preserve project instructions")
        XCTAssertEqual(record.enabledHash, "v052-enabled")
        XCTAssertEqual(record.lastUsedAt, Date(timeIntervalSince1970: 123))
        XCTAssertNil(project.pinnedSkillsData)
        XCTAssertNil(record.manifestsData)
        XCTAssertNil(conversation.detachedPinnedSkillsData)
        XCTAssertNil(conversation.skillCatalogOrderData)
        let attachments = try JSONDecoder().decode(
            [SkillAttachment].self, from: XCTUnwrap(conversation.attachedSkillsData)
        )
        XCTAssertEqual(attachments.first?.hash, "v052-enabled")
        XCTAssertEqual(conversation.declinedSkillsData, Data("[\"other\"]".utf8))
        let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first)
        XCTAssertEqual(audit.conversationID, conversation.id)
        XCTAssertEqual(audit.toolName, "skill.attached")
        return (attachments, audit)
    }

    private func verifyMigration(fixture: String, title: String) throws {
        // Real SQLite fixtures made with original model declarations, not today's models.
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "store"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("upgrade.store")
        try FileManager.default.copyItem(at: source, to: url)
        let models: [any PersistentModel.Type] = [
            Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            Checkpoint.self,
            SkillRecord.self,
        ]
        func open() throws -> ModelContainer {
            let schema = Schema(models)
            return try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
        }
        let container = try open()
        let context = container.mainContext
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(conversation.title, title)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolCall>()), 1)
        let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first)
        XCTAssertEqual(audit.conversationID, conversation.id)
        XCTAssertNil(conversation.attachedSkillsData)
        XCTAssertNil(conversation.declinedSkillsData)
        if fixture == "skills-v0.5.0.1" {
            try verifySkillMetadata(context, conversation: conversation)
        }
        let references = [SkillAttachment(id: "sample", hash: "abc", source: "appFolder")]
        conversation.attachedSkillsData = try JSONEncoder().encode(references)
        try context.save()
        let reopened = try open()
        let saved = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(saved.id, conversation.id)
        XCTAssertEqual(saved.messages.count, 2)
        XCTAssertEqual(saved.attachedSkillsData, conversation.attachedSkillsData)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<AuditEntry>()).first?.id, audit.id)
    }

    private func verifySkillMetadata(_ context: ModelContext, conversation: Conversation) throws {
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<SkillRecord>()).first)
        XCTAssertEqual(skill.state, .enabled)
        XCTAssertEqual(skill.enabledHash, "enabled-before-upgrade")
        XCTAssertEqual(skill.enabledAt, Date(timeIntervalSince1970: 123))
        XCTAssertNil(skill.lastUsedAt)
        XCTAssertEqual(conversation.modelID, "fixture-model")
        XCTAssertEqual(conversation.lastContextTokens, 42)
        XCTAssertEqual(conversation.project?.instructions, "Keep this instruction")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Checkpoint>()), 1)
    }
}
