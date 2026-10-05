import Foundation
@testable import maclm_agent
import SwiftData
import XCTest

@MainActor final class AuditLogTests: XCTestCase {
    private func jsonString(_ value: Any) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AuditEntry.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func run(
        _ name: String,
        arguments: [String: Any],
        decision: ConfirmationDecision = .approved,
        rules: [SecurityRuleSnapshot] = [],
        memory: SessionPermissions = SessionPermissions(),
        allowed: [String] = []
    ) async throws -> AuditRecord {
        let store = try container()
        let context = store.mainContext
        let loop = AgentLoop(
            sessionPermissions: memory,
            riskContext: { .init(allowedDirectories: allowed) },
            auditSink: { context.insert(AuditEntry($0)); try context.save() },
            securityRules: { rules }
        )
        let json = try jsonString(arguments)
        try await loop.streamResponse(to: [], using: AuditProvider(name: name, json: json)) { event in
            if case let .confirmationRequested(request) = event {
                await loop.resolveConfirmation(requestID: request.id, decision: decision)
            }
        }
        let entries = try context.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(entries.count, 1)
        return try XCTUnwrap(entries.first).record
    }

    func testUnknownToolAndMalformedArgumentsAreAudited() async throws {
        let unknown = try await run("missing_tool", arguments: [:])
        XCTAssertEqual(unknown.outcome, .failure)
        XCTAssertNotNil(unknown.errorDescription)
        let store = try container()
        let context = store.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        try await loop.streamResponse(to: [], using: AuditProvider(name: "write_file", json: "invalid")) { _ in }
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first).record
        XCTAssertEqual(record.outcome, .failure)
        XCTAssertEqual(record.argumentsJSON, "invalid")
        XCTAssertNotNil(record.errorDescription)
    }

    func testRejectedAndBlocked() async throws {
        let rejected = try await run("run_shell", arguments: ["command": "exit 0"], decision: .rejected)
        XCTAssertEqual(rejected.decision, .rejected)
        XCTAssertEqual(rejected.outcome, .notExecuted)
        let blocked = try await run(
            "read_file",
            arguments: ["path": "/tmp/audit-blocked"],
            rules: [.init(pattern: "/tmp/audit-blocked", action: .block)]
        )
        XCTAssertEqual(blocked.decision, .blocked)
        XCTAssertEqual(blocked.outcome, .notExecuted)
        XCTAssertEqual(blocked.riskLevel, .safe)
        XCTAssertNotNil(blocked.matchedRuleDescription)
    }

    func testSafeReadDoesNotDuplicateContentAndSessionIsAuto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text")
        try "private payload".write(to: file, atomically: true, encoding: .utf8)
        let read = try await run("read_file", arguments: ["path": file.path])
        XCTAssertEqual(read.decision, .auto)
        XCTAssertEqual(read.outcome, .success)
        XCTAssertFalse(read.resultSummary.contains("private payload"))
        XCTAssertTrue(read.resultSummary.contains("15 bytes"))
        let memory = SessionPermissions()
        memory.remember(toolName: "write_file", riskLevel: .caution)
        let write = try await run(
            "write_file",
            arguments: ["path": file.path, "content": "new", "mode": "overwrite"],
            memory: memory,
            allowed: [root.path]
        )
        XCTAssertEqual(write.decision, .auto)
        XCTAssertEqual(write.outcome, .success)
        XCTAssertEqual(write.riskLevel, .caution)
    }

    func testShellFailuresAndTimeout() async throws {
        let failed = try await run("run_shell", arguments: ["command": "printf out; printf err >&2; exit 7"])
        XCTAssertEqual(failed.decision, .approved)
        XCTAssertEqual(failed.outcome, .failure)
        XCTAssertTrue(failed.resultSummary.contains("exitCode: 7"))
        XCTAssertNotNil(failed.errorDescription)
        let timeout = try await run("run_shell", arguments: ["command": "exec sleep 10", "timeoutSeconds": 1])
        XCTAssertEqual(timeout.outcome, .failure)
        XCTAssertTrue(timeout.errorDescription?.contains("timeout") == true)
        XCTAssertTrue(timeout.resultSummary.contains("timedOut: true"))
    }

    func testShellCancellationIsPersisted() async throws {
        let store = try container()
        let context = store.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        let task = Task {
            try await loop.streamResponse(
                to: [],
                using: AuditProvider(name: "run_shell", json: #"{"command":"exec sleep 30"}"#)
            ) { event in
                if case let .confirmationRequested(request) = event {
                    await loop.resolveConfirmation(requestID: request.id, decision: .approved)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error
        }
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AuditEntry>()).first).record
        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(record.decision, .approved)
        XCTAssertNotNil(record.durationMilliseconds)
    }

    func testCancellationAuditsRemainingCallsInBatch() async throws {
        let store = try container()
        let context = store.mainContext
        let loop = AgentLoop(auditSink: { context.insert(AuditEntry($0)); try context.save() })
        let provider = AuditProvider(name: "run_shell", json: #"{"command":"exec sleep 30"}"#, callCount: 2)
        let task = Task {
            try await loop.streamResponse(to: [], using: provider) { event in
                if case let .confirmationRequested(request) = event {
                    await loop.resolveConfirmation(requestID: request.id, decision: .approved)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error
        }
        let entries = try context.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.outcome == .cancelled })
        XCTAssertEqual(entries.filter { $0.durationMilliseconds != nil }.count, 1)
    }

    func testTruncationAndShellStreams() throws {
        let long = String(repeating: "Ж", count: 12000)
        let raw = try jsonString(["path": "/tmp/file", "content": long, "nested": [long]])
        let saved = AuditSanitizer.arguments(raw, toolName: "write_file")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "/tmp/file")
        XCTAssertTrue((object["content"] as? String)?.contains("original length: 12000") == true)
        XCTAssertEqual((object["content"] as? String)?.prefix(2000), long.prefix(2000))
        let command = try AuditSanitizer.arguments(
            jsonString(["command": long]),
            toolName: "run_shell"
        )
        let shell = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: String])
        XCTAssertEqual(shell["command"]?.prefix(10000), long.prefix(10000))
        let shortCommand = String(repeating: "x", count: 5000)
        XCTAssertFalse(AuditSanitizer.arguments("{\"command\":\"\(shortCommand)\"}", toolName: "run_shell")
            .contains("truncated"))
        XCTAssertTrue(AuditSanitizer.summary(.success(content: long), toolName: "list_dir", arguments: [:]).0
            .contains("truncated"))
        let output = try jsonString([
            "stdout": long,
            "stderr": long,
            "exitCode": 0,
            "timedOut": false,
        ])
        let summary = AuditSanitizer.summary(.success(content: output), toolName: "run_shell", arguments: [:]).0
        XCTAssertEqual(summary.components(separatedBy: "[truncated;").count - 1, 2)
        XCTAssertTrue(summary.contains("exitCode: 0"))
        XCTAssertTrue(summary.contains("timedOut: false"))
    }

    func testLargeJournalPaginationFilteredExportAndRetention() async throws {
        let store = try container()
        let context = store.mainContext
        let now = Date()
        for index in 0 ..< 10000 {
            var record = AuditRecord(
                toolName: index % 2 == 0 ? "read_file" : "run_shell",
                argumentsJSON: "{\"path\":\"/tmp/needle\"}"
            )
            record.timestamp = now.addingTimeInterval(-Double(index) * 86400)
            record.riskLevel = index % 2 == 0 ? .safe : .dangerous
            context.insert(AuditEntry(record))
        }
        try context.save()
        var filter = AuditFilter()
        filter.tool = "read_file"
        filter.risk = .safe
        filter.decision = .auto
        filter.search = "needle"
        filter.start = now.addingTimeInterval(-1000 * 86400)
        filter.end = now
        let first = try filter.page(context: context, offset: 0)
        let second = try filter.page(context: context, offset: 200)
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(second.count, 200)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let maintenance = await AuditMaintenance.background(container: store)
        let count = try await maintenance.export(filter: filter, to: url)
        XCTAssertEqual(count, 501)
        let replacedCount = try await maintenance.export(filter: filter, to: url)
        XCTAssertEqual(replacedCount, count)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let record = try decoder.decode(AuditRecord.self, from: Data(line.utf8))
            XCTAssertEqual(record.toolName, "read_file")
            XCTAssertEqual(record.riskLevel, .safe)
        }
        try await maintenance.prune(days: 90, now: now)
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<AuditEntry>()), 91)
        try await maintenance.prune(days: 0, now: now)
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<AuditEntry>()), 91)
        try await maintenance.clear()
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<AuditEntry>()), 0)
    }

    func testAdditiveMigrationPreservesExistingStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("upgrade.store")
        func oldStore() throws {
            let schema = Schema([
                Conversation.self,
                Message.self,
                ToolCall.self,
                ClipboardAction.self,
                SecurityRule.self,
            ])
            let store = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
            let conversation = Conversation(title: "preserved")
            conversation.messages.append(Message(role: .user, content: "old message"))
            store.mainContext.insert(conversation)
            store.mainContext.insert(SecurityRule(dimension: .path, pattern: "/private", action: .block))
            try store.mainContext.save()
        }
        try oldStore()
        let schema = Schema([
            Conversation.self,
            Message.self,
            ToolCall.self,
            ClipboardAction.self,
            SecurityRule.self,
            AuditEntry.self,
        ])
        let store = try ModelContainer(for: schema, configurations: .init(schema: schema, url: url))
        XCTAssertEqual(
            try store.mainContext.fetch(FetchDescriptor<Conversation>()).first?.messages.first?.content,
            "old message"
        )
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<SecurityRule>()), 1)
        store.mainContext.insert(AuditEntry(.init(toolName: "read_file", argumentsJSON: "{}")))
        try store.mainContext.save()
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<AuditEntry>()), 1)
    }
}

private struct AuditProvider: LLMProvider {
    let name: String
    let json: String
    var callCount = 1
    func streamChat(messages: [ChatMessage], tools _: [ToolDefinition]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if !messages.contains(where: { $0.role == .tool }) {
                for index in 0 ..< callCount {
                    continuation.yield(.toolCallDelta(.init(
                        index: index,
                        id: "audit-call-\(index)",
                        type: "function",
                        functionName: name,
                        argumentsDelta: json
                    )))
                }
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
