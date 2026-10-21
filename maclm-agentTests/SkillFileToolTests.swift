import Darwin
import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class SkillFileToolTests: XCTestCase {
    private func attachedFixture() async throws -> SkillSessionFixture {
        let fixture = try SkillSessionFixture()
        try await fixture.enable()
        _ = try await fixture.skills.attach("sample")
        return fixture
    }

    private func request(
        _ fixture: SkillSessionFixture, _ action: SkillFileRequest.Action = .read,
        skill: String = "sample", path: String? = nil
    ) async -> ToolExecutionResult {
        var arguments = ["skill": skill]
        if let path {
            arguments["path"] = path
        }
        return await fixture.skills.fileRequest(.init(action: action, arguments: arguments))
    }

    private func write(_ fixture: SkillSessionFixture, _ path: String, data: Data) throws {
        let url = fixture.root.appendingPathComponent("sample/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testAllUnsafePathFormsFailClosedAndAreAudited() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let paths = [
            "..", "../x", "a/../../x", "./x", "/etc/passwd", "~/x", "a\\b", "a\0b", "a\nb", "a\tb",
            "a\u{7F}b", "%2e%2e/x", "%2F", "%252e%252e/x", "．．/x", "．/x", "a／b", "a/", "", "a//b",
        ]
        for path in paths {
            let result = await request(fixture, path: path)
            XCTAssertTrue(result.isError, path.debugDescription)
            XCTAssertTrue(result.content.contains("invalid or hidden relative path"), path.debugDescription)
        }
        XCTAssertEqual(try fixture.audits("skill.fileRead").count, paths.count)
        XCTAssertTrue(try fixture.audits("skill.fileRead").allSatisfy {
            $0.decision == .blocked && $0.outcome == .failure && $0.conversationID == fixture.conversation.id
        })
    }

    func testLexicalValidationPrecedesOpeningAnyPath() {
        for path in ["../x", ".env", "%2e%2e/x", "．/x"] {
            XCTAssertThrowsError(try SkillFileIO.withResolvedPath(path, root: -1) { _ in XCTFail("opened") }) {
                XCTAssertEqual($0 as? SkillFileAccessError, .invalidPath)
            }
        }
    }

    func testDefaultPathAndNestedTextAndSizes() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let text = "Русский reference\nEnglish reference\t✓"
        try write(fixture, "refs/nested/example.txt", data: Data(text.utf8))
        let instructions = await request(fixture)
        XCTAssertFalse(instructions.isError)
        XCTAssertTrue(instructions.content.hasPrefix("---\nname: sample"))
        let nested = await request(fixture, path: "refs/nested/example.txt")
        XCTAssertEqual(nested.content, text)
        let listing = await request(fixture, .list)
        let files = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listing.content.utf8)) as? [[String: Any]])
        XCTAssertEqual(files.compactMap { $0["path"] as? String }, ["SKILL.md", "refs/nested/example.txt"])
        XCTAssertEqual(files.last?["size"] as? Int, text.utf8.count)
    }

    func testExactly32KiBIsReturnedInFull() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "limit.txt", data: Data(repeating: 65, count: 32768))
        let result = await request(fixture, path: "limit.txt")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.utf8.count, 32768)
    }

    func testOver32KiBReturnsNoPartialContent() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "large.txt", data: Data(repeating: 65, count: 32769))
        let result = await request(fixture, path: "large.txt")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("exceeds 32 KB"))
        XCTAssertFalse(result.content.contains(String(repeating: "A", count: 10)))
    }

    func testBinaryUTF8WithNULIsRejected() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "binary", data: Data([65, 0, 66]))
        let result = await request(fixture, path: "binary")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("not binary"))
    }

    func testInvalidUTF8IsRejected() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "invalid", data: Data([0xC3, 0x28]))
        let result = await request(fixture, path: "invalid")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("UTF-8"))
    }

    func testMissingFileAndDirectoryAreErrors() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "sub/file", data: Data())
        let missing = await request(fixture, path: "missing")
        let directory = await request(fixture, path: "sub")
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(directory.isError)
        XCTAssertTrue(directory.content.contains("regular file"))
    }

    func testEveryHiddenComponentIsExcludedAndRejected() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let hidden = [".git/config", ".env", "sub/.hidden", ".DS_Store", "sub/._sidecar"]
        for path in hidden {
            try write(fixture, path, data: Data("hidden secret".utf8))
        }
        try write(fixture, "sub/visible", data: Data("visible".utf8))
        let listing = await request(fixture, .list)
        XCTAssertFalse(listing.isError)
        for path in hidden {
            XCTAssertFalse(listing.content.contains(path))
            let read = await request(fixture, path: path)
            XCTAssertTrue(read.isError)
        }
        XCTAssertTrue(listing.content.contains("sub/visible"))
    }

    func testFileAndDirectorySymlinksIntroducedAfterScanAreNotFollowed() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("OUTSIDE SECRET".utf8).write(to: outside.appendingPathComponent("secret"))
        let folder = fixture.root.appendingPathComponent("sample")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("secret")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("dir-link"), withDestinationURL: outside
        )
        let listing = await request(fixture, .list)
        XCTAssertFalse(listing.isError)
        XCTAssertFalse(listing.content.contains("link"))
        for path in ["file-link", "dir-link/secret"] {
            let result = await request(fixture, path: path)
            XCTAssertTrue(result.isError)
            XCTAssertFalse(result.content.contains("OUTSIDE SECRET"))
        }
    }

    func testSymlinkSwappedBetweenListAndReadIsRejected() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "reference", data: Data("original".utf8))
        let listing = await request(fixture, .list)
        XCTAssertTrue(listing.content.contains("reference"))
        let target = fixture.root.appendingPathComponent("sample/reference")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let read = await request(fixture, path: "reference")
        XCTAssertTrue(read.isError)
    }

    func testSkillFolderSymlinkReplacementIsRejected() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let folder = fixture.root.appendingPathComponent("sample")
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        let read = await request(fixture)
        let listing = await request(fixture, .list)
        XCTAssertTrue(read.isError)
        XCTAssertTrue(listing.isError)
    }

    func testEnabledButNotAttachedAndUnknownSkillAreErrors() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        for id in ["sample", "unknown", "../sample"] {
            for action: SkillFileRequest.Action in [.read, .list] {
                let result = await request(fixture, action, skill: id)
                XCTAssertTrue(result.isError)
                XCTAssertTrue(result.content.contains("not attached"))
            }
        }
    }

    func testAttachmentInAnotherSessionDoesNotAuthorizeAccess() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        let other = Conversation(title: "Other session")
        fixture.container.mainContext.insert(other)
        let session = SessionSkills(store: fixture.store, conversation: other, context: fixture.container.mainContext)
        for action: SkillFileRequest.Action in [.read, .list] {
            let result = await session.fileRequest(.init(action: action, arguments: ["skill": "sample"]))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.content.contains("not attached"))
        }
    }

    func testDisabledAfterAttachIsUnavailable() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        _ = try await fixture.store.disable("sample")
        for action: SkillFileRequest.Action in [.read, .list] {
            let result = await request(fixture, action)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.content.contains("unavailable:"))
        }
    }

    func testDetachedSkillIsNoLongerAccessible() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        fixture.skills.detach("sample")
        let result = await request(fixture)
        XCTAssertTrue(result.content.contains("not attached"))
    }

    func testBadArgumentTypesAndMissingSkillAreAudited() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        for arguments: [String: Any] in [[:], ["skill": 1], ["skill": "sample", "path": 1]] {
            let result = await fixture.skills.fileRequest(.init(action: .read, arguments: arguments))
            XCTAssertTrue(result.isError)
        }
        XCTAssertEqual(try fixture.audits("skill.fileRead").count, 3)
    }

    func testReadsDoNotVerifyHashOrChangeTrust() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "reference", data: Data("changed during session".utf8))
        let result = await request(fixture, path: "reference")
        XCTAssertEqual(result.content, "changed during session")
        let state = try await fixture.store.state(of: "sample")
        XCTAssertEqual(state, .enabled)
        XCTAssertTrue(try fixture.audits("skill.hashMismatch").isEmpty)
    }

    func testSuccessfulAndRejectedAuditMetadataAndContentRedaction() async throws {
        let fixture = try await attachedFixture()
        defer { fixture.clean() }
        try write(fixture, "reference", data: Data("PRIVATE REFERENCE".utf8))
        _ = await request(fixture, path: "reference")
        _ = await request(fixture, .list)
        _ = await request(fixture, path: "../secret")
        let reads = try fixture.audits("skill.fileRead").sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(reads.count, 2)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reads[0].argumentsJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(metadata["skill"] as? String, "sample")
        XCTAssertEqual(metadata["source"] as? String, "appFolder")
        XCTAssertEqual(metadata["path"] as? String, "reference")
        XCTAssertEqual(metadata["byteCount"] as? Int, 17)
        XCTAssertEqual(metadata["conversationID"] as? String, fixture.conversation.id.uuidString)
        XCTAssertEqual(reads[0].outcome, .success)
        XCTAssertEqual(reads[1].outcome, .failure)
        XCTAssertTrue(reads[1].argumentsJSON.contains("reason"))
        XCTAssertFalse(reads[0].resultSummary.contains("PRIVATE REFERENCE"))
        let lists = try fixture.audits("skill.fileList")
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists.first?.conversationID, fixture.conversation.id)
        let summary = AuditSanitizer.summary(
            .success(content: "PRIVATE REFERENCE"), toolName: "read_skill_file", arguments: [:]
        )
        XCTAssertFalse(summary.0.contains("PRIVATE REFERENCE"))
    }

    func testRegistrySchemasAndStaticSafeLevels() throws {
        for name in ["list_skill_files", "read_skill_file"] {
            let tool = try XCTUnwrap(ToolRegistry.all.tool(named: name))
            XCTAssertEqual(type(of: tool).baseRiskLevel, .safe)
            XCTAssertTrue(tool.description.contains("attached to the current session"))
            guard case let .object(_, required, _) = tool.parametersSchema else { return XCTFail("object schema") }
            XCTAssertEqual(required, ["skill"])
        }
    }
}

extension SkillFileToolTests {
    func testProjectRulesAreNeverLoadedAndModelCanListThenRead() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        try write(fixture, "refs/reference.txt", data: Data("MODEL REFERENCE".utf8))
        // Attach after creating reference so the generation-start integrity gate passes.
        let snapshots = try await fixture.store.rescan()
        _ = try await fixture.store.reconfirm("sample", expectedHash: XCTUnwrap(snapshots.first?.hash))
        _ = try await fixture.skills.attach("sample")
        let loop = AgentLoop(securityRules: {
            XCTFail("Skill file tools must not load project rules")
            throw CocoaError(.fileReadUnknown)
        })
        let capture = SkillPromptCapture()
        try await loop.streamResponse(
            to: [.init(role: .user, content: "List and read reference")],
            using: SkillFileCallingProvider(capture: capture),
            invocationContext: {
                .init(
                    conversationID: fixture.conversation.id,
                    project: .init(id: UUID(), workingDirectoryPath: "/denied")
                )
            },
            skillFileRequest: { await fixture.skills.fileRequest($0) },
            onEvent: { event in
                if case .confirmationRequested = event {
                    XCTFail("safe tools must not prompt")
                }
            }
        )
        let history = await capture.requests.last ?? []
        let results = history.filter { $0.role == .tool }.map(\.content)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.first?.contains("refs/reference.txt") == true)
        XCTAssertEqual(results.last, "MODEL REFERENCE")
        XCTAssertEqual(try fixture.audits("skill.fileRead").count, 1)
    }

    func testSessionRunnerWiresFileToolsToCurrentSession() async throws {
        let fixture = try SkillSessionFixture()
        defer { fixture.clean() }
        try await fixture.enable()
        try write(fixture, "refs/reference.txt", data: Data("MODEL REFERENCE".utf8))
        let snapshots = try await fixture.store.rescan()
        _ = try await fixture.store.reconfirm("sample", expectedHash: XCTUnwrap(snapshots.first?.hash))
        let capture = SkillPromptCapture()
        let runner = SessionRunner(
            conversation: fixture.conversation, modelContext: fixture.container.mainContext,
            agentLoop: AgentLoop(), autoTitles: AutoTitleService(context: fixture.container.mainContext),
            skillStore: fixture.store, providerFactory: { SkillFileCallingProvider(capture: capture) }
        )
        _ = try await runner.skills?.attach("sample")
        runner.send("Read reference")
        await runner.waitUntilFinished()
        XCTAssertEqual(runner.status, .idle)
        let history = await capture.requests.filter { $0.contains { $0.role == .tool } }
        XCTAssertTrue(history.contains { $0.contains { $0.role == .tool && $0.content == "MODEL REFERENCE" } })
    }
}

private struct SkillFileCallingProvider: LLMProvider {
    let name = "skill file fixture"
    let capture: SkillPromptCapture

    func streamChat(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await capture.append(messages)
                let count = messages.filter { $0.role == .tool }.count
                if !tools.isEmpty, count < 2 {
                    continuation.yield(.toolCallDelta(.init(
                        index: 0, id: "file-call-\(count)", type: "function",
                        functionName: count == 0 ? "list_skill_files" : "read_skill_file",
                        argumentsDelta: count == 0 ? #"{"skill":"sample"}"#
                            : #"{"skill":"sample","path":"refs/reference.txt"}"#
                    )))
                } else {
                    continuation.yield(.contentDelta("Done"))
                }
                continuation.finish()
            }
        }
    }
}
