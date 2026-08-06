import Darwin
import Foundation
@preconcurrency import OSAKit

private enum ChildStopReason {
    case timeout
    case cancelled
}

private final class ChildProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func finish(status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Thread-safe lifecycle controller for one exact child process. A stop request
/// first sends SIGTERM, then escalates to SIGKILL if the same `Process` instance
/// is still running after the grace period. Foundation's termination handler is
/// the reap authority, so returning from execution means the exact child is gone.
private final class ChildProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var storedReason: ChildStopReason?
    private var forceKillTask: Task<Void, Never>?

    init(process: Process) {
        self.process = process
    }

    var stopReason: ChildStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }

    func requestStop(reason: ChildStopReason) {
        lock.lock()
        guard storedReason == nil, process.isRunning else {
            lock.unlock()
            return
        }
        storedReason = reason
        let pid = process.processIdentifier
        process.terminate()
        forceKillTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.forceKillIfStillRunning(pid: pid)
        }
        lock.unlock()
    }

    func waitForEscalation() async {
        let task = currentForceKillTask()
        if let task {
            await task.value
        }
    }

    private func forceKillIfStillRunning(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard storedReason != nil, process.isRunning, process.processIdentifier == pid else {
            return
        }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private func currentForceKillTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return forceKillTask
    }
}

/// Errors that can occur during script execution.
enum ScriptExecutionError: Error, CustomStringConvertible {
    case admissionClosed
    case mutationQueueFull
    case timeout
    case compilationFailed(String)
    case executionFailed(String)
    case invalidScript
    case invalidScriptType
    case commandNotFound(String)
    case securityViolation(String)
    case processError(String)

    var description: String {
        switch self {
        case .admissionClosed:
            "Script execution admission is closed"
        case .mutationQueueFull:
            "Physical desktop mutation queue is full"
        case .timeout:
            "Script execution timed out"
        case let .compilationFailed(msg):
            "Script compilation failed: \(msg)"
        case let .executionFailed(msg):
            "Script execution failed: \(msg)"
        case .invalidScript:
            "Invalid script"
        case .invalidScriptType:
            "Invalid script type"
        case let .commandNotFound(cmd):
            "Command not found: \(cmd)"
        case let .securityViolation(msg):
            "Security violation: \(msg)"
        case let .processError(msg):
            "Process error: \(msg)"
        }
    }
}

/// Result of script execution.
struct ScriptExecutionResult {
    let success: Bool
    let output: String
    let error: String?
    let duration: TimeInterval
}

/// Result of shell command execution.
struct ShellCommandResult {
    let success: Bool
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let duration: TimeInterval
    let error: String?
}

/// Result of script validation.
struct ScriptValidationResult {
    let valid: Bool
    let errors: [String]
    let warnings: [String]
}

/// Utility for executing scripts (AppleScript, JXA, Shell).
///
/// Security Note: This executor implements defense-in-depth checks for obviously
/// dangerous patterns like `rm -rf /` and `sudo`. These checks are not a security
/// sandbox and can be bypassed by determined users. They serve to prevent accidental
/// catastrophic operations.
actor ScriptExecutor {
    private struct ActiveExecution: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    nonisolated let mutationGate: PhysicalDesktopMutationGate
    private let processOperation: (@Sendable () async throws -> Void)?
    private let processStartHandler: (@Sendable (pid_t) -> Void)?
    private var activeExecutions: [UUID: ActiveExecution] = [:]
    private var acceptingExecutions = true

    init(
        mutationGate: PhysicalDesktopMutationGate,
        processOperation: (@Sendable () async throws -> Void)? = nil,
        processStartHandler: (@Sendable (pid_t) -> Void)? = nil,
    ) {
        self.mutationGate = mutationGate
        self.processOperation = processOperation
        self.processStartHandler = processStartHandler
    }

    private nonisolated static func validatedTimeoutNanoseconds(
        _ timeout: TimeInterval,
    ) throws -> UInt64 {
        guard timeout.isFinite,
              timeout > 0,
              timeout <= RequestNumericValidation.maximumTimeoutSeconds
        else {
            throw ScriptExecutionError.processError("Timeout must be a finite positive duration")
        }
        return UInt64((timeout * 1_000_000_000).rounded(.up))
    }

    func beginDraining() {
        acceptingExecutions = false
    }

    func shutdown() async {
        acceptingExecutions = false
        let executions = activeExecutions
        for execution in executions.values {
            execution.cancel()
        }
        for execution in executions.values {
            await execution.wait()
        }
        for id in executions.keys {
            activeExecutions.removeValue(forKey: id)
        }
    }

    func activeExecutionCount() -> Int {
        activeExecutions.count
    }

    private func withOwnedExecution<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result,
    ) async throws -> Result {
        guard acceptingExecutions else {
            throw ScriptExecutionError.admissionClosed
        }

        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        activeExecutions[id] = ActiveExecution(
            cancel: { task.cancel() },
            wait: { _ = try? await task.value },
        )
        defer { activeExecutions.removeValue(forKey: id) }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated func withPhysicalDesktopMutation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result,
    ) async throws -> Result {
        do {
            return try await mutationGate.withExclusiveOperation(operation)
        } catch let error as PhysicalDesktopMutationError {
            switch error {
            case .admissionClosed:
                throw ScriptExecutionError.admissionClosed
            case .queueFull:
                throw ScriptExecutionError.mutationQueueFull
            }
        }
    }

    /// Executes an AppleScript string and returns the result.
    ///
    /// - Parameters:
    ///   - script: The AppleScript source code
    ///   - timeout: Maximum execution time in seconds (default: 30)
    ///   - compileOnly: If true, only compile without execution
    /// - Returns: Script execution result
    func executeAppleScript(
        _ script: String,
        timeout: TimeInterval = 30.0,
        compileOnly: Bool = false,
    ) async throws -> ScriptExecutionResult {
        _ = try Self.validatedTimeoutNanoseconds(timeout)
        return try await withOwnedExecution { [self] in
            try await executeAppleScriptBody(
                script,
                timeout: timeout,
                compileOnly: compileOnly,
            )
        }
    }

    private func executeAppleScriptBody(
        _ script: String,
        timeout: TimeInterval,
        compileOnly: Bool,
    ) async throws -> ScriptExecutionResult {
        let startTime = Date()

        // Validate script is not empty
        guard !script.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check: basic validation
        try validateAppleScriptSecurity(script)

        // If compile-only mode, return success
        if compileOnly {
            guard let appleScript = NSAppleScript(source: script) else {
                throw ScriptExecutionError.compilationFailed("Failed to create NSAppleScript instance")
            }
            var compileError: NSDictionary?
            if !appleScript.compileAndReturnError(&compileError) {
                let errorMsg =
                    compileError?[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
                throw ScriptExecutionError.compilationFailed(errorMsg)
            }
            let duration = Date().timeIntervalSince(startTime)
            return ScriptExecutionResult(
                success: true,
                output: "Script compiled successfully",
                error: nil,
                duration: duration,
            )
        }

        // Execute through one exact osascript child so timeout and cancellation
        // cover both compilation and execution without an uninterruptible in-process
        // OSA call. One `-e` argument preserves the source byte-for-byte.
        let shellResult = try await withPhysicalDesktopMutation { [self] in
            try await executeProcess(
                executable: "/usr/bin/osascript",
                args: ["-e", script],
                timeout: timeout,
            )
        }
        let duration = Date().timeIntervalSince(startTime)

        let stdout = shellResult.stdout.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let stderr = shellResult.stderr.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))

        if shellResult.exitCode != 0 {
            return ScriptExecutionResult(
                success: false,
                output: stdout,
                error: stderr.isEmpty ? shellResult.error : stderr,
                duration: duration,
            )
        }

        return ScriptExecutionResult(
            success: true,
            output: stdout,
            error: nil,
            duration: duration,
        )
    }

    /// Executes JavaScript for Automation (JXA) and returns the result.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source code
    ///   - timeout: Maximum execution time in seconds (default: 30)
    ///   - compileOnly: If true, only compile without execution
    /// - Returns: Script execution result
    func executeJavaScript(
        _ script: String,
        timeout: TimeInterval = 30.0,
        compileOnly: Bool = false,
    ) async throws -> ScriptExecutionResult {
        _ = try Self.validatedTimeoutNanoseconds(timeout)
        return try await withOwnedExecution { [self] in
            try await executeJavaScriptBody(
                script,
                timeout: timeout,
                compileOnly: compileOnly,
            )
        }
    }

    private func executeJavaScriptBody(
        _ script: String,
        timeout: TimeInterval,
        compileOnly: Bool,
    ) async throws -> ScriptExecutionResult {
        let startTime = Date()

        // Validate script is not empty
        guard !script.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check: basic validation
        try validateJavaScriptSecurity(script)

        // If compile-only mode, return success
        if compileOnly {
            guard let jsLanguage = OSALanguage(forName: "JavaScript") else {
                throw ScriptExecutionError.compilationFailed("JavaScript language not available")
            }
            let osaScript = OSAScript(source: script, language: jsLanguage)
            var compileError: NSDictionary?
            osaScript.compileAndReturnError(&compileError)
            if let error = compileError {
                let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
                throw ScriptExecutionError.compilationFailed(errorMsg)
            }
            let duration = Date().timeIntervalSince(startTime)
            return ScriptExecutionResult(
                success: true,
                output: "Script compiled successfully",
                error: nil,
                duration: duration,
            )
        }

        // Execute through an exact child for the same timeout/cancellation/reap
        // guarantees as AppleScript and shell execution.
        let processResult = try await withPhysicalDesktopMutation { [self] in
            try await executeProcess(
                executable: "/usr/bin/osascript",
                args: ["-l", "JavaScript", "-e", script],
                timeout: timeout,
            )
        }
        let duration = Date().timeIntervalSince(startTime)
        let stdout = processResult.stdout.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let stderr = processResult.stderr.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        return ScriptExecutionResult(
            success: processResult.success,
            output: stdout,
            error: processResult.success ? nil : (stderr.isEmpty ? processResult.error : stderr),
            duration: duration,
        )
    }

    /// Executes an external process directly (without a shell wrapper) and returns
    /// the result. Timed-out processes are inferred from elapsed duration, not exit
    /// status, and the timeout task terminates the real child process.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the executable
    ///   - args: Command arguments
    ///   - workingDirectory: Working directory for execution
    ///   - environment: Environment variables
    ///   - timeout: Maximum execution time in seconds (default: 30)
    ///   - stdin: Input to provide via stdin
    /// - Returns: Shell command execution result
    private func executeProcess(
        executable: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0,
        stdin: String? = nil,
    ) async throws -> ShellCommandResult {
        let startTime = Date()

        let timeoutNanoseconds = try Self.validatedTimeoutNanoseconds(timeout)

        if let processOperation {
            try await processOperation()
            try Task.checkCancellation()
            return ShellCommandResult(
                success: true,
                stdout: "",
                stderr: "",
                exitCode: 0,
                duration: Date().timeIntervalSince(startTime),
                error: nil,
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        if let workingDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        let termination = ChildProcessTermination()
        process.terminationHandler = { child in
            termination.finish(status: child.terminationStatus)
        }

        do {
            try process.run()
            processStartHandler?(process.processIdentifier)
        } catch {
            throw ScriptExecutionError.processError(
                "Failed to launch process: \(error.localizedDescription)",
            )
        }

        // Start draining stdout/stderr concurrently before waitUntilExit() so a
        // child that fills the pipe buffer cannot deadlock before exiting.
        let stdoutTask = Task.detached(priority: .utility) {
            try? stdoutPipe.fileHandleForReading.readToEnd()
        }
        let stderrTask = Task.detached(priority: .utility) {
            try? stderrPipe.fileHandleForReading.readToEnd()
        }
        let controller = ChildProcessController(process: process)

        do {
            if let stdinData = stdin?.data(using: .utf8) {
                try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            }
            // Always close stdin, including when no input was supplied. Commands
            // such as `cat` must observe EOF instead of hanging until timeout.
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            controller.requestStop(reason: .cancelled)
            _ = await termination.wait()
            await controller.waitForEscalation()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw ScriptExecutionError.processError(
                "Failed to write process stdin: \(error.localizedDescription)",
            )
        }

        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                controller.requestStop(reason: .timeout)
            } catch {
                // Normal process completion cancels the watchdog.
            }
        }

        let exitCode = await withTaskCancellationHandler {
            await termination.wait()
        } onCancel: {
            controller.requestStop(reason: .cancelled)
        }
        timeoutTask.cancel()
        await timeoutTask.value
        await controller.waitForEscalation()

        let duration = Date().timeIntervalSince(startTime)

        let stdoutData = await stdoutTask.value ?? Data()
        let stderrData = await stderrTask.value ?? Data()

        switch controller.stopReason {
        case .timeout:
            throw ScriptExecutionError.timeout
        case .cancelled:
            throw CancellationError()
        case nil:
            try Task.checkCancellation()
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ShellCommandResult(
            success: exitCode == 0,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            duration: duration,
            error: exitCode != 0 ? "Command exited with code \(exitCode)" : nil,
        )
    }

    /// Executes a shell command and returns the result.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - args: Command arguments
    ///   - workingDirectory: Working directory for execution
    ///   - environment: Environment variables
    ///   - timeout: Maximum execution time in seconds (default: 30)
    ///   - stdin: Input to provide via stdin
    ///   - shell: Shell to use (default: /bin/bash)
    /// - Returns: Shell command execution result
    func executeShellCommand(
        _ command: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0,
        stdin: String? = nil,
        shell: String = "/bin/bash",
    ) async throws -> ShellCommandResult {
        _ = try Self.validatedTimeoutNanoseconds(timeout)
        return try await withOwnedExecution { [self] in
            try await executeShellCommandBody(
                command,
                args: args,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout,
                stdin: stdin,
                shell: shell,
            )
        }
    }

    private func executeShellCommandBody(
        _ command: String,
        args: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: TimeInterval,
        stdin: String?,
        shell: String,
    ) async throws -> ShellCommandResult {
        // Validate command
        guard !command.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check
        try validateShellCommandSecurity(command, args: args)

        // Build command with args
        let commandWithArgs = if args.isEmpty {
            command
        } else {
            command + " " + args.map { shellEscape($0) }.joined(separator: " ")
        }

        return try await withPhysicalDesktopMutation { [self] in
            try await executeProcess(
                executable: shell,
                args: ["-c", commandWithArgs],
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout,
                stdin: stdin,
            )
        }
    }

    /// Validates a script without executing it.
    ///
    /// - Parameters:
    ///   - script: The script source code
    ///   - type: The script type (AppleScript or JXA)
    /// - Returns: Validation result
    func validateScript(_ script: String, type: ScriptType) async throws -> ScriptValidationResult {
        try await withOwnedExecution { [self] in
            try await validateScriptBody(script, type: type)
        }
    }

    private func validateScriptBody(
        _ script: String,
        type: ScriptType,
    ) async throws -> ScriptValidationResult {
        switch type {
        case .appleScript:
            try await validateAppleScript(script)
        case .jxa:
            try await validateJavaScript(script)
        case .shell:
            // Shell scripts don't have compile-time validation
            ScriptValidationResult(
                valid: !script.isEmpty,
                errors: script.isEmpty ? ["Script is empty"] : [],
                warnings: [],
            )
        }
    }

    private func validateAppleScript(_ script: String) async throws -> ScriptValidationResult {
        guard let appleScript = NSAppleScript(source: script) else {
            return ScriptValidationResult(
                valid: false,
                errors: ["Failed to create NSAppleScript instance"],
                warnings: [],
            )
        }

        var compileError: NSDictionary?
        let compiled = appleScript.compileAndReturnError(&compileError)

        if compiled {
            return ScriptValidationResult(
                valid: true,
                errors: [],
                warnings: [],
            )
        } else {
            let errorMsg =
                compileError?[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
            return ScriptValidationResult(
                valid: false,
                errors: [errorMsg],
                warnings: [],
            )
        }
    }

    private func validateJavaScript(_ script: String) async throws -> ScriptValidationResult {
        guard let jsLanguage = OSALanguage(forName: "JavaScript") else {
            return ScriptValidationResult(
                valid: false,
                errors: ["JavaScript language not available"],
                warnings: [],
            )
        }
        let osaScript = OSAScript(source: script, language: jsLanguage)

        var compileError: NSDictionary?
        osaScript.compileAndReturnError(&compileError)

        if compileError == nil {
            return ScriptValidationResult(
                valid: true,
                errors: [],
                warnings: [],
            )
        } else {
            let errorMsg =
                compileError?[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
            return ScriptValidationResult(
                valid: false,
                errors: [errorMsg],
                warnings: [],
            )
        }
    }

    private func validateAppleScriptSecurity(_ script: String) throws {
        let lowerScript = script.lowercased()

        // Check for extremely dangerous patterns
        if lowerScript.contains("rm -rf /") {
            throw ScriptExecutionError.securityViolation(
                "Recursive deletion of root directory detected ('rm -rf /'). " +
                    "This operation is blocked for safety. Use a specific path instead.",
            )
        }

        if lowerScript.contains("sudo") {
            throw ScriptExecutionError.securityViolation(
                "Privilege escalation via 'sudo' is not allowed. " +
                    "Scripts run with the permissions of the current user.",
            )
        }

        // Note: "do shell script" is common in AppleScript, so we allow it
        // but ideally would log/monitor usage
    }

    private func validateJavaScriptSecurity(_ script: String) throws {
        let lowerScript = script.lowercased()

        if lowerScript.contains("sudo") {
            throw ScriptExecutionError.securityViolation(
                "Privilege escalation via 'sudo' is not allowed in JXA scripts. " +
                    "Scripts run with the permissions of the current user.",
            )
        }

        if lowerScript.contains("rm -rf /") {
            throw ScriptExecutionError.securityViolation(
                "Recursive deletion of root directory detected ('rm -rf /'). " +
                    "This operation is blocked for safety. Use a specific path instead.",
            )
        }
    }

    private func validateShellCommandSecurity(_ command: String, args: [String]) throws {
        let lowerCommand = command.lowercased()

        // Check for dangerous commands
        if lowerCommand.contains("rm -rf /") {
            throw ScriptExecutionError.securityViolation(
                "Recursive deletion of root directory detected ('rm -rf /'). " +
                    "This operation is blocked for safety. Use a specific path instead.",
            )
        }

        // Check for sudo in command or args - use contains() to catch command chains
        // e.g., "echo test && sudo rm foo"
        if lowerCommand.contains("sudo") || args.contains(where: { $0.lowercased() == "sudo" }) {
            throw ScriptExecutionError.securityViolation(
                "Privilege escalation via 'sudo' is not allowed. " +
                    "Shell commands run with the permissions of the current user.",
            )
        }
    }
}

/// shellEscape wraps a string in single quotes, escaping any embedded single quotes.
/// This is the safest form of shell argument escaping — single quotes in POSIX shell
/// have no special characters inside them except the closing single quote itself.
private func shellEscape(_ arg: String) -> String {
    "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum ScriptType {
    case appleScript
    case jxa
    case shell
}
