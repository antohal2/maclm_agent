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
