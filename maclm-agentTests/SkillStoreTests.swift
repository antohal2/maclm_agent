import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillStoreTests: XCTestCase {
    private func withStore(_ operation: (SkillStore, ModelContainer, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-test-" + UUID().uuidString)
        let folder = root.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("---\nname: sample\ndescription: yes\n---\nBody".utf8)
            .write(to: folder.appendingPathComponent("SKILL.md"))
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuditEntry.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        try await operation(SkillStore(root: root, container: container), container, folder)
    }

    func testTrustStateMachineAndAudit() async throws {
        try await withStore { store, container, folder in
            let found = try await store.rescan()
            XCTAssertEqual(found.first?.state, .disabled)
            let firstHash = try XCTUnwrap(found.first?.hash)
            let enabled = try await store.enable("sample", expectedHash: firstHash)
            XCTAssertEqual(enabled.first?.state, .enabled)
            let metadata = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SkillRecord>()).first)
            XCTAssertEqual(metadata.enabledHash, firstHash)
            XCTAssertNotNil(metadata.enabledAt)
            try Data("changed".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            let changed = try await store.rescan()
            XCTAssertEqual(changed.first?.state, .needsReconfirm)
            let newHash = try XCTUnwrap(changed.first?.hash)
            do {
                _ = try await store.enable("sample", expectedHash: newHash)
                XCTFail("A normal enable must not bypass reconfirmation")
            } catch { XCTAssertEqual(error as? SkillValidationError, .reconfirmRequired) }
            let confirmed = try await store.reconfirm("sample", expectedHash: newHash)
            XCTAssertEqual(confirmed.first?.state, .enabled)
            XCTAssertEqual(confirmed.first?.enabledHash, newHash)
            let disabled = try await store.disable("sample")
            XCTAssertEqual(disabled.first?.state, .disabled)
            XCTAssertNil(disabled.first?.enabledHash)
            let events = try ModelContext(container).fetch(FetchDescriptor<AuditEntry>())
            XCTAssertEqual(events.filter { $0.toolName == "skill.enable" }.count, 2)
            XCTAssertEqual(events.filter { $0.toolName == "skill.disable" }.count, 1)
            XCTAssertEqual(events.filter { $0.toolName == "skill.hashMismatch" }.count, 1)
            for event in events {
                let object = try XCTUnwrap(JSONSerialization
                    .jsonObject(with: Data(event.argumentsJSON.utf8)) as? [String: Any])
                XCTAssertEqual(object["source"] as? String, "appFolder")
                XCTAssertNotNil(object["hash"] as? String)
                XCTAssertEqual(event.outcome, .success)
            }
        }
    }

    func testFreshStoreRechecksPersistedHashAtLaunch() async throws {
        try await withStore { store, container, folder in
            let found = try await store.rescan()
            _ = try await store.enable("sample", expectedHash: XCTUnwrap(found.first?.hash))
            try Data("modified".utf8).write(to: folder.appendingPathComponent("file"))
            let restarted = SkillStore(root: folder.deletingLastPathComponent(), container: container)
            let scanned = try await restarted.rescan()
            XCTAssertEqual(scanned.first?.state, .needsReconfirm)
        }
    }

    func testStalePreviewCannotApproveDifferentBytes() async throws {
        try await withStore { store, _, folder in
            let found = try await store.rescan()
            let shownHash = try XCTUnwrap(found.first?.hash)
            try Data("new".utf8).write(to: folder.appendingPathComponent("file"))
            do {
                _ = try await store.enable("sample", expectedHash: shownHash)
                XCTFail("Stale preview must be refused")
            } catch { XCTAssertEqual(error as? SkillValidationError, .changedSincePreview) }
            let entries = try await store.rescan()
            XCTAssertEqual(entries.first?.state, .disabled)
            XCTAssertNil(entries.first?.enabledHash)
        }
    }

    func testInvalidRecoveryAndMissingFolderCannotRestoreTrust() async throws {
        try await withStore { store, container, folder in
            let found = try await store.rescan()
            _ = try await store.enable("sample", expectedHash: XCTUnwrap(found.first?.hash))
            let link = folder.appendingPathComponent("symlink")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
            let invalid = try await store.rescan()
            XCTAssertEqual(invalid.first?.state, .invalid)
            try FileManager.default.removeItem(at: link)
            let recovered = try await store.rescan()
            XCTAssertEqual(recovered.first?.state, .needsReconfirm)
            _ = try await store.reconfirm("sample", expectedHash: XCTUnwrap(recovered.first?.hash))
            try FileManager.default.removeItem(at: folder)
            let missing = try await store.rescan()
            XCTAssertEqual(missing.first?.state, .invalid)
            XCTAssertEqual(missing.first?.problem, .unavailable)
            let events = try ModelContext(container).fetch(FetchDescriptor<AuditEntry>())
            XCTAssertEqual(events.filter { $0.toolName == "skill.hashMismatch" }.count, 2)
        }
    }

    func testInvalidSkillCannotBeEnabled() async throws {
        try await withStore { store, _, folder in
            try Data("No frontmatter".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            let found = try await store.rescan()
            XCTAssertEqual(found.first?.state, .invalid)
            do {
                _ = try await store.enable("sample", expectedHash: "fake")
                XCTFail("Invalid skill was enabled")
            } catch { XCTAssertEqual(error as? SkillValidationError, .unavailable) }
        }
    }

    func testFolderIsCreatedOnFirstUse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuditEntry.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let store = SkillStore(root: root, container: container)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let entries = try await store.rescan()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testModelFileToolsRemainBlockedDespiteUserAllowRule() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent("Library/Application Support/local.test/skills/sample/SKILL.md").path
        var rules = ApplicationProtection.rules(
            storeURL: home.appendingPathComponent("store"),
            bundleID: "local.test",
            home: home
        )
        rules.append(.init(pattern: path, action: .allow, order: -1000))
        let policy = SecurityPolicyEngine(rules: rules)
        for tool: any Tool in [
            ReadFileTool(),
            WriteFileTool(),
            ListDirectoryTool(),
            SearchFilesTool(),
            DeleteFileTool(),
            MoveFileTool(),
        ] {
            XCTAssertEqual(
                policy.decision(for: tool, arguments: ["path": path, "root": path, "from": path, "to": path])
                    .disposition,
                .blocked
            )
        }
        XCTAssertTrue(rules.contains { $0.isMandatory && $0.isBuiltIn && $0.action == .block })
    }

    func testAddingSkillModelPreservesExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("upgrade.store")
        let models: [any PersistentModel.Type] = [
            Conversation.self,
            Project.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
            Checkpoint.self,
        ]
        func oldStore() throws {
            let schema = Schema(models)
            let old = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
            old.mainContext.insert(Conversation(title: "before-skills"))
            old.mainContext.insert(AuditEntry(.init(toolName: "read_file", argumentsJSON: "{}")))
            try old.mainContext.save()
        }
        try oldStore()
        let schema = Schema(models + [SkillRecord.self])
        let upgraded = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<Conversation>()).first?.title, "before-skills")
        XCTAssertEqual(try upgraded.mainContext.fetchCount(FetchDescriptor<AuditEntry>()), 1)
        upgraded.mainContext.insert(SkillRecord(skillID: "sample"))
        try upgraded.mainContext.save()
        XCTAssertEqual(try upgraded.mainContext.fetchCount(FetchDescriptor<SkillRecord>()), 1)
    }
}
