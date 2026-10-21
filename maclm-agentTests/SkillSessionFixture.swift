import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillSessionFixture {
    let root: URL
    let container: ModelContainer
    let store: SkillStore
    let conversation: Conversation
    let skills: SessionSkills

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-session-" + UUID().uuidString)
        container = try ModelContainer(
            for: Conversation.self, Message.self, ToolCall.self, AuditEntry.self, SkillRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = SkillStore(root: root, container: container)
        conversation = Conversation(title: "Skill fixture")
        container.mainContext.insert(conversation)
        try container.mainContext.save()
        skills = SessionSkills(store: store, conversation: conversation, context: container.mainContext)
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store.snapshotRoot)
    }

    func write(_ id: String = "sample", body: String = "Secret skill instructions") throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: \(id)\ndescription: A useful task skill\n---\n\(body)".utf8)
            .write(to: folder.appendingPathComponent("SKILL.md"))
    }

    @discardableResult
    func enable(_ id: String = "sample", body: String = "Secret skill instructions") async throws -> String {
        try write(id, body: body)
        let scanned = try await store.rescan()
        let hash = try XCTUnwrap(scanned.first { $0.id == id }?.hash)
        _ = try await store.enable(id, expectedHash: hash)
        return hash
    }

    func restarted() -> SessionSkills {
        SessionSkills(
            store: SkillStore(root: root, container: container),
            conversation: conversation,
            context: container.mainContext
        )
    }

    func audits(_ name: String) throws -> [AuditEntry] {
        try container.mainContext.fetch(FetchDescriptor<AuditEntry>()).filter { $0.toolName == name }
    }

    func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0 ..< 500 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for skill proposal")
        throw SkillValidationError.unavailable
    }
}
