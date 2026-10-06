import Darwin
import Foundation
@testable import maclm_agent
import XCTest

final class ShellProcessTests: XCTestCase {
    private func markedProcesses(_ marker: String) throws -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line in
            guard line.contains(marker), let pid = line.split(separator: " ").first else { return nil }
            return Int32(pid)
        }
    }

    private func cleanupMarkedProcesses(_ marker: String) {
        for pid in (try? markedProcesses(marker)) ?? [] {
            kill(pid, SIGKILL)
        }
    }

    private func waitForMarkedProcess(_ marker: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try markedProcesses(marker).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(try markedProcesses(marker).isEmpty, "Child must start before cancellation")
    }

    private func assertNoMarkedProcesses(_ marker: String) async throws {
        // Allow launchd a short interval to reap orphaned children after group termination.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while try !markedProcesses(marker).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try markedProcesses(marker).isEmpty, "No marked processes may survive the tool")
    }

    func testShellTimeoutTerminatesDescendantAndPreservesOutput() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let start = ContinuousClock.now
        let result = try await RunShellTool().execute(arguments: [
            "command": "printf before-timeout; (exec -a \(marker) /bin/sleep 300) & wait",
            "timeoutSeconds": 1,
        ])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        XCTAssertEqual(output["stdout"] as? String, "before-timeout")
        XCTAssertEqual(output["timedOut"] as? Bool, true)
        XCTAssertTrue(result.isError)
        XCTAssertLessThan(start.duration(to: .now), .seconds(6))
        try await assertNoMarkedProcesses(marker)
    }

    func testShellCancellationKillsTermIgnoringDescendant() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let task = Task.detached {
            try await RunShellTool().execute(arguments: [
                "command": "(trap '' TERM; exec -a \(marker) /bin/sleep 300) & wait",
                "timeoutSeconds": 30,
            ])
        }
        try await waitForMarkedProcess(marker)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        try await assertNoMarkedProcesses(marker)
    }

    func testShellBackgroundProcessIsStoppedAndReportedInAudit() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let start = ContinuousClock.now
        let result = try await RunShellTool().execute(arguments: [
            "command": "(exec -a \(marker) /bin/sleep 300) &",
        ])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        XCTAssertEqual(output["exitCode"] as? Int, 0)
        XCTAssertEqual(output["timedOut"] as? Bool, false)
        XCTAssertTrue((output["lifecycleNote"] as? String)?.contains("background processes stopped") == true)
        XCTAssertTrue(AuditSanitizer.summary(result, toolName: "run_shell", arguments: [:]).0
            .contains("Remaining background processes stopped."))
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        try await assertNoMarkedProcesses(marker)
    }

    func testShellBoundsPipeHeldByEscapedProcess() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let start = ContinuousClock.now
        // Perl is a system executable on macOS. Wait for the escape handshake before zsh exits.
        let command = #"/usr/bin/perl -MPOSIX -e 'pipe(R,W); my $pid=fork(); "#
            + #"if ($pid==0) { close R; POSIX::setsid(); $0="\#(marker)"; $|=1; "#
            + #"print "escaped\n"; print W "ok\n"; close W; sleep 300; } else { close W; <R>; }'"#
        let result = try await RunShellTool().execute(arguments: ["command": command])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        XCTAssertTrue((output["stdout"] as? String)?.contains("escaped") == true)
        XCTAssertTrue((output["lifecycleNote"] as? String)?.contains("Output truncated") == true)
        XCTAssertTrue(AuditSanitizer.summary(result, toolName: "run_shell", arguments: [:]).0
            .contains("Output truncated: a descendant kept an output pipe open."))
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertFalse(try markedProcesses(marker).isEmpty, "Escaped process demonstrates the documented limitation")
        cleanupMarkedProcesses(marker)
        try await assertNoMarkedProcesses(marker)
    }

    func testOutputBufferExactCountsAndUTF8Boundaries() {
        var buffer = ShellOutputBuffer(limits: .init(headBytes: 8, tailBytes: 8))
        let bytes = Array("🙂🙂🙂🙂🙂🙂".utf8)
        for byte in bytes {
            buffer.append([byte][...])
        }
        XCTAssertEqual(buffer.totalBytes, 24)
        XCTAssertEqual(buffer.retainedBytes, 16)
        XCTAssertEqual(buffer.rendered, "🙂🙂\n[... 8 bytes omitted ...]\n🙂🙂")
        var split = ShellOutputBuffer(limits: .init(headBytes: 7, tailBytes: 7))
        split.append(bytes[...])
        XCTAssertEqual(split.rendered, "🙂\n[... 16 bytes omitted ...]\n🙂")
        XCTAssertFalse(split.rendered.contains("�"))
        var small = ShellOutputBuffer(limits: .init(headBytes: 7, tailBytes: 7))
        small.append(Array("🙂🙂🙂".utf8)[...])
        XCTAssertEqual(small.rendered, "🙂🙂🙂")
        XCTAssertNil(small.truncationNote)
        var invalid = ShellOutputBuffer(limits: .init(headBytes: 4, tailBytes: 4))
        invalid.append([UInt8](repeating: 255, count: 20)[...])
        XCTAssertTrue(invalid.rendered.contains("�"))
    }

    func testShellSmallOutputFormatUnchanged() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let result = try await RunShellTool().execute(arguments: [
            "command": "printf hello; printf error >&2 # \(marker)",
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["stdout", "stderr", "exitCode", "timedOut"]))
        XCTAssertEqual(json["stdout"] as? String, "hello")
        XCTAssertEqual(json["stderr"] as? String, "error")
        XCTAssertFalse(result.isError)
        try await assertNoMarkedProcesses(marker)
    }

    func testShellStreamsTruncateIndependentlyAndPreserveExit() async throws {
        let marker = "maclm-shell-\(UUID().uuidString)"
        defer { cleanupMarkedProcesses(marker) }
        let result = try await RunShellTool().execute(arguments: [
            "command": "/usr/bin/perl -e 'print \"A\" x 102400; print STDERR \"B\" x 102400' # \(marker)",
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        for (stream, character) in [("stdout", "A"), ("stderr", "B")] {
            let value = try XCTUnwrap(json[stream] as? String)
            XCTAssertEqual(
                value,
                String(repeating: character, count: 8192)
                    + "\n[... 86016 bytes omitted ...]\n" + String(repeating: character, count: 8192)
            )
            let note = "\(stream): Output truncated: kept first 8192 and last 8192 bytes of 102400."
            XCTAssertTrue((json["lifecycleNote"] as? String)?.contains(note) == true)
        }
        XCTAssertEqual(json["exitCode"] as? Int, 0)
        XCTAssertEqual(json["timedOut"] as? Bool, false)
        XCTAssertFalse(result.isError)
        XCTAssertLessThan(result.content.utf8.count, 34000)
        XCTAssertTrue(AuditSanitizer.summary(result, toolName: "run_shell", arguments: [:]).0.contains("kept first"))
        try await assertNoMarkedProcesses(marker)
        let failed = try await RunShellTool().execute(arguments: ["command": "printf fail >&2; exit 7 # \(marker)"])
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failed.content.utf8)) as? [String: Any])
        XCTAssertEqual(failure["exitCode"] as? Int, 7)
        XCTAssertTrue(failed.isError)
        let unicode = try await RunShellTool(limits: .init(headBytes: 7, tailBytes: 7)).execute(arguments: [
            "command": "printf '🙂🙂🙂🙂🙂🙂' # \(marker)",
        ])
        let unicodeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(unicode.content.utf8)) as? [String: Any]
        )
        XCTAssertEqual(unicodeJSON["stdout"] as? String, "🙂\n[... 16 bytes omitted ...]\n🙂")
        try await assertNoMarkedProcesses(marker)
    }

    func testInfiniteOutputTimeoutAndHardLimitLeaveNoProcesses() async throws {
        let cases: [(UInt64, String)] = [(UInt64.max, ""), (2 * 1024 * 1024, ""), (2 * 1024 * 1024, " >&2")]
        for (hardLimit, redirect) in cases {
            let marker = "maclm-shell-\(UUID().uuidString)"
            defer { cleanupMarkedProcesses(marker) }
            let start = ContinuousClock.now
            let result = try await RunShellTool(limits: .init(hardBytes: hardLimit)).execute(arguments: [
                "command": "exec -a \(marker) /usr/bin/yes\(redirect)", "timeoutSeconds": 1,
            ])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            XCTAssertEqual(json["timedOut"] as? Bool, hardLimit == UInt64.max)
            XCTAssertEqual(json["outputLimitExceeded"] as? Bool, hardLimit == UInt64.max ? nil : true)
            XCTAssertTrue(result.isError)
            XCTAssertLessThan(result.content.utf8.count, 34000)
            XCTAssertLessThan(start.duration(to: .now), .seconds(6))
            if hardLimit != UInt64.max {
                XCTAssertEqual(
                    AuditSanitizer.summary(result, toolName: "run_shell", arguments: [:]).1,
                    "Shell command output limit exceeded"
                )
            }
            try await assertNoMarkedProcesses(marker)
        }
    }

    func testShellDescriptionRoutesFileOperations() {
        let description = RunShellTool().description
        XCTAssertTrue(description.contains("Do not"))
        for word in [
            "read",
            "write",
            "move",
            "delete",
            "directories",
            "path access rules",
            "read_file",
            "write_file",
            "move_file",
            "delete_file",
            "list_dir",
            "search_files",
        ] {
            XCTAssertTrue(description.contains(word), word)
        }
    }
}
