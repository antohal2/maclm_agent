import Darwin
import Foundation

struct RunShellTool: Tool {
    let name = "run_shell"
    /// Soft routing guidance only: no command parsing or runtime file-operation block.
    let description =
        "Run an exact shell command through /bin/zsh -c and return stdout, stderr, and exit code. "
            + "Do not read, write, move, delete files or browse directories with shell: it bypasses path access rules. "
            + "Use read_file, write_file, move_file, delete_file, list_dir and search_files instead."
    static let baseRiskLevel = RiskLevel.dangerous
    static let isPolicyEnforceable = false

    var parametersSchema: JSONSchema {
        .object(
            properties: [
                "command": .string(description: "Exact command passed to /bin/zsh -c."),
                "timeoutSeconds": .integer(
                    description: "Optional positive timeout in seconds. Defaults to 30."
                ),
            ],
            required: ["command"]
        )
    }

    func execute(arguments: [String: Any], invocation _: ToolInvocationContext) async throws -> ToolExecutionResult {
        let command: String
        switch ToolArgument.requiredRawString(named: "command", in: arguments) {
        case let .value(value):
            command = value
        case let .error(result):
            return result
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Argument 'command' must not be empty.")
        }

        let timeoutSeconds: Int
        if let value = arguments["timeoutSeconds"] {
            guard
                let number = value as? NSNumber,
                number.doubleValue.rounded() == number.doubleValue,
                number.intValue > 0
            else {
                return .failure("Argument 'timeoutSeconds' must be a positive integer.")
            }
            timeoutSeconds = number.intValue
        } else {
            timeoutSeconds = 30
        }

        return try await ShellCommandRunner.run(
            command: command,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// Cancellation is signalled to a POSIX worker so cleanup cannot itself be cancelled.
private final class ShellCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum ShellCommandRunner {
    private static let terminationGrace: Duration = .seconds(2)
    private static let outputGrace: Duration = .seconds(2)

    static func run(command: String, timeoutSeconds: Int) async throws -> ToolExecutionResult {
        let cancellation = ShellCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                // POSIX polling blocks a thread: keep it out of Swift's cooperative executor.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try continuation.resume(returning: runSynchronously(
                            command: command, timeoutSeconds: timeoutSeconds, cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runSynchronously(
        command: String,
        timeoutSeconds: Int,
        cancellation: ShellCancellation
    ) throws -> ToolExecutionResult {
        let output = try ShellPipe()
        defer { output.close() }
        let error = try ShellPipe()
        defer { error.close() }
        let pid: pid_t
        do {
            pid = try spawn(command: command, output: output, error: error)
        } catch {
            return .failure("Unable to launch /bin/zsh: \(error.localizedDescription)")
        }
        output.closeWriter()
        error.closeWriter()
        let execution = Execution(pid: pid, output: output, error: error)
        let timedOut = execution.wait(timeoutSeconds: timeoutSeconds, cancellation: cancellation)
        let stoppedBackground = execution.stopGroup()
        let truncated = execution.finishOutput()
        if cancellation.isCancelled {
            throw CancellationError()
        }
        var notices: [String] = []
        if stoppedBackground {
            notices.append("Remaining background processes stopped.")
        }
        if truncated {
            notices.append("Output truncated: a descendant kept an output pipe open.")
        }
        return result(from: ShellCommandOutput(
            stdout: decode(output.data), stderr: decode(error.data),
            exitCode: execution.exitCode, timedOut: timedOut,
            lifecycleNote: notices.isEmpty ? nil : notices.joined(separator: "\n")
        ))
    }

    private final class Execution {
        let pid: pid_t
        let output: ShellPipe
        let error: ShellPipe
        var status: Int32 = 0
        var reaped = false

        init(pid: pid_t, output: ShellPipe, error: ShellPipe) {
            self.pid = pid
            self.output = output
            self.error = error
        }

        var exitCode: Int32 {
            guard reaped else { return SIGKILL }
            return status & 0x7F == 0 ? (status >> 8) & 0xFF : status & 0x7F
        }

        func collect() {
            output.drain()
            error.drain()
            if !reaped {
                reaped = waitpid(pid, &status, WNOHANG) == pid
            }
        }

        func wait(timeoutSeconds: Int, cancellation: ShellCancellation) -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
            while !reaped {
                collect()
                if reaped {
                    return false
                }
                if cancellation.isCancelled {
                    return false
                }
                if ContinuousClock.now >= deadline {
                    return true
                }
                usleep(10000)
            }
            return false
        }

        func stopGroup() -> Bool {
            // setsid/setpgid descendants can escape; this is cleanup, not an OS sandbox.
            guard killpg(pid, 0) == 0 || errno == EPERM else { return false }
            let stoppedBackground = reaped
            killpg(pid, SIGTERM)
            let deadline = ContinuousClock.now.advanced(by: terminationGrace)
            repeat {
                collect()
                if killpg(pid, 0) != 0, errno == ESRCH {
                    return stoppedBackground
                }
                usleep(10000)
            } while ContinuousClock.now < deadline
            killpg(pid, SIGKILL)
            return stoppedBackground
        }

        func finishOutput() -> Bool {
            let deadline = ContinuousClock.now.advanced(by: outputGrace)
            repeat {
                collect()
                if reaped, output.reachedEOF, error.reachedEOF {
                    break
                }
                usleep(10000)
            } while ContinuousClock.now < deadline
            let truncated = !output.reachedEOF || !error.reachedEOF
            output.close()
            error.close()
            if !reaped {
                // SIGKILL cannot wake uninterruptible sleep. Reap later, off the caller's path.
                let childPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var lateStatus: Int32 = 0
                    while waitpid(childPID, &lateStatus, 0) < 0, errno == EINTR {}
                }
            }
            return truncated
        }
    }

    private static func spawn(command: String, output: ShellPipe, error: ShellPipe) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))
        // Do not inherit the launching worker thread's blocked/ignored signals.
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE] {
            sigaddset(&defaults, signal)
        }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        // Do not leak unrelated app/test-host descriptors into zsh and its descendants.
        // Explicit spawn actions preserve only stdin and the two output channels.
        if fcntl(STDIN_FILENO, F_GETFD) >= 0 {
            try check(posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO))
        }
        try check(posix_spawn_file_actions_adddup2(&actions, output.writer, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, error.writer, STDERR_FILENO))
        for descriptor in [output.reader, output.writer, error.reader, error.writer] {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        let arguments = ["/bin/zsh", "-c", command].map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var argv = arguments + [nil]
        var pid: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer {
            let argvPointer = $0.baseAddress!
            return envp.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argvPointer, $0.baseAddress!)
            }
        }
        try check(code)
        return pid
    }

    private static func check(_ code: Int32) throws {
        if code != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func decode(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? "<non-UTF-8 output: \(data.count) bytes>"
    }

    private static func result(from output: ShellCommandOutput) -> ToolExecutionResult {
        let encoded = try? JSONEncoder.toolOutput.encode(output)
        let content: String = if let encoded, let value = String(data: encoded, encoding: .utf8) {
            value
        } else {
            #"{"error":"Unable to encode shell result."}"#
        }
        var lines = [
            "stdout:\n\(output.stdout.isEmpty ? "(empty)" : output.stdout)",
            "stderr:\n\(output.stderr.isEmpty ? "(empty)" : output.stderr)",
            "exit code: \(output.exitCode)",
            "timed out: \(output.timedOut ? "yes" : "no")",
        ]
        if let note = output.lifecycleNote {
            lines.append(note)
        }
        return ToolExecutionResult(
            content: content, displayContent: lines.joined(separator: "\n\n"),
            isError: output.timedOut || output.exitCode != 0
        )
    }
}

/// Owned only by the synchronous worker. O_NONBLOCK bounds every read; draining both
/// channels on each turn avoids stdout/stderr deadlock and keeps collecting during cleanup.
private final class ShellPipe {
    private(set) var reader: Int32
    private(set) var writer: Int32
    private(set) var data = Data()
    private(set) var reachedEOF = false

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        reader = descriptors[0]
        writer = descriptors[1]
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader, F_SETFL, O_NONBLOCK) == 0
        else {
            let code = errno
            Darwin.close(reader)
            Darwin.close(writer)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func closeWriter() {
        if writer >= 0 {
            Darwin.close(writer); writer = -1
        }
    }

    func close() {
        closeWriter()
        if reader >= 0 {
            Darwin.close(reader); reader = -1
        }
    }

    func drain() {
        guard reader >= 0, !reachedEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        // Limit work per turn so continuous output cannot starve timeout/cancellation.
        for _ in 0 ..< 16 {
            let count = Darwin.read(reader, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                reachedEOF = true; return
            } else if errno != EINTR {
                return
            }
        }
    }
}

private struct ShellCommandOutput: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
    let lifecycleNote: String?
}
