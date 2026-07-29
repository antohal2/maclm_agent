import Darwin
import Foundation

struct RunShellTool: Tool {
    let name = "run_shell"
    let description =
        "Run an exact shell command through /bin/zsh -c and return stdout, stderr, and exit code."
    let riskLevel = RiskLevel.confirm

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

    func execute(arguments: [String: Any]) async throws -> ToolExecutionResult {
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

private enum ShellCommandRunner {
    static func run(
        command: String,
        timeoutSeconds: Int
    ) async throws -> ToolExecutionResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        configure(
            process,
            command: command,
            standardOutput: standardOutput,
            standardError: standardError
        )

        do {
            try process.run()
        } catch {
            return .failure("Unable to launch /bin/zsh: \(error.localizedDescription)")
        }

        let outputTask = drain(standardOutput.fileHandleForReading)
        let errorTask = drain(standardError.fileHandleForReading)
        let didTimeOut = try await waitForExit(
            process,
            timeoutSeconds: timeoutSeconds,
            outputTask: outputTask,
            errorTask: errorTask
        )
        let output = await makeOutput(
            process: process,
            didTimeOut: didTimeOut,
            outputTask: outputTask,
            errorTask: errorTask
        )
        return result(from: output)
    }

    private static func configure(
        _ process: Process,
        command: String,
        standardOutput: Pipe,
        standardError: Pipe
    ) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    private static func drain(_ handle: FileHandle) -> Task<Data, any Error> {
        Task.detached {
            try handle.readToEnd() ?? Data()
        }
    }

    private static func waitForExit(
        _ process: Process,
        timeoutSeconds: Int,
        outputTask: Task<Data, any Error>,
        errorTask: Task<Data, any Error>
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        do {
            while process.isRunning, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let didTimeOut = process.isRunning
            if didTimeOut {
                try await stop(process, clock: clock)
            }
            return didTimeOut
        } catch is CancellationError {
            terminate(process)
            outputTask.cancel()
            errorTask.cancel()
            throw CancellationError()
        }
    }

    private static func stop(
        _ process: Process,
        clock: ContinuousClock
    ) async throws {
        process.terminate()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while process.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        kill(process.processIdentifier, SIGKILL)
    }

    private static func makeOutput(
        process: Process,
        didTimeOut: Bool,
        outputTask: Task<Data, any Error>,
        errorTask: Task<Data, any Error>
    ) async -> ShellCommandOutput {
        let outputData = await (try? outputTask.value) ?? Data()
        let errorData = await (try? errorTask.value) ?? Data()
        return ShellCommandOutput(
            stdout: decode(outputData),
            stderr: decode(errorData),
            exitCode: process.terminationStatus,
            timedOut: didTimeOut
        )
    }

    private static func decode(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8)
            ?? "<non-UTF-8 output: \(data.count) bytes>"
    }

    private static func result(from output: ShellCommandOutput) -> ToolExecutionResult {
        let content = encode(output)
        let displayContent = [
            "stdout:\n\(output.stdout.isEmpty ? "(empty)" : output.stdout)",
            "stderr:\n\(output.stderr.isEmpty ? "(empty)" : output.stderr)",
            "exit code: \(output.exitCode)",
            "timed out: \(output.timedOut ? "yes" : "no")",
        ]
        .joined(separator: "\n\n")
        return ToolExecutionResult(
            content: content,
            displayContent: displayContent,
            isError: output.timedOut || output.exitCode != 0
        )
    }

    private static func encode(_ output: ShellCommandOutput) -> String {
        guard
            let data = try? JSONEncoder.toolOutput.encode(output),
            let value = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"Unable to encode shell result."}"#
        }
        return value
    }
}

private struct ShellCommandOutput: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}
