import Foundation
@preconcurrency import OSAKit

/// Errors that can occur during script execution.
enum ScriptExecutionError: Error, CustomStringConvertible {
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
    static let shared = ScriptExecutor()

    private init() {}

    /// Executes an AppleScript string and returns the result.
    ///
    /// - Parameters:
    ///   - script: The AppleScript source code
    ///   - timeout: Maximum execution time in seconds (default: 30)
    ///   - compileOnly: If true, only compile without execution
    /// - Returns: Script execution result
    func executeAppleScript(
        _ script: String,
        timeout _: TimeInterval = 30.0,
        compileOnly: Bool = false,
    ) async throws -> ScriptExecutionResult {
        let startTime = Date()

        // Validate script is not empty
        guard !script.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check: basic validation
        try validateAppleScriptSecurity(script)

        // Compile the script
        guard let appleScript = NSAppleScript(source: script) else {
            throw ScriptExecutionError.compilationFailed("Failed to create NSAppleScript instance")
        }

        // Get compilation errors
        var compileError: NSDictionary?
        if !appleScript.compileAndReturnError(&compileError) {
            let errorMsg =
                compileError?[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
            throw ScriptExecutionError.compilationFailed(errorMsg)
        }

        // If compile-only mode, return success
        if compileOnly {
            let duration = Date().timeIntervalSince(startTime)
            return ScriptExecutionResult(
                success: true,
                output: "Script compiled successfully",
                error: nil,
                duration: duration,
            )
        }

        // Execute (must be nonisolated to avoid Sendable capture issues)
        var executeError: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&executeError)

        let duration = Date().timeIntervalSince(startTime)

        if let error = executeError {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown execution error"
            return ScriptExecutionResult(
                success: false,
                output: "",
                error: errorMsg,
                duration: duration,
            )
        }

        // Get output as string
        let output = descriptor.stringValue ?? ""

        return ScriptExecutionResult(
            success: true,
            output: output,
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
        let startTime = Date()

        // Validate script is not empty
        guard !script.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check: basic validation
        try validateJavaScriptSecurity(script)

        // Create OSAScript with JavaScript language
        // Note: OSALanguage initialization differs - using JavaScript identifier
        guard let jsLanguage = OSALanguage(forName: "JavaScript") else {
            throw ScriptExecutionError.compilationFailed("JavaScript language not available")
        }
        let osaScript = OSAScript(source: script, language: jsLanguage)

        // Compile the script
        var compileError: NSDictionary?
        osaScript.compileAndReturnError(&compileError)

        if let error = compileError {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown compilation error"
            throw ScriptExecutionError.compilationFailed(errorMsg)
        }

        // If compile-only mode, return success
        if compileOnly {
            let duration = Date().timeIntervalSince(startTime)
            return ScriptExecutionResult(
                success: true,
                output: "Script compiled successfully",
                error: nil,
                duration: duration,
            )
        }

        // Execute with timeout
        return try await withTimeout(seconds: timeout) {
            var executeError: NSDictionary?
            let descriptor = osaScript.executeAndReturnError(&executeError)

            let duration = Date().timeIntervalSince(startTime)

            if let error = executeError {
                let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown execution error"
                return ScriptExecutionResult(
                    success: false,
                    output: "",
                    error: errorMsg,
                    duration: duration,
                )
            }

            // Get output as string (JSON-encoded if applicable)
            let output = descriptor?.stringValue ?? ""

            return ScriptExecutionResult(
                success: true,
                output: output,
                error: nil,
                duration: duration,
            )
        }
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
        let startTime = Date()

        // Validate command
        guard !command.isEmpty else {
            throw ScriptExecutionError.invalidScript
        }

        // Security check
        try validateShellCommandSecurity(command, args: args)

        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)

        // Build command with args
        var commandWithArgs = command
        if !args.isEmpty {
            commandWithArgs += " " + args.map { "\"\($0)\"" }.joined(separator: " ")
        }

        process.arguments = ["-c", commandWithArgs]

        // Set working directory if provided
        if let workingDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        // Set environment if provided
        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        // Setup pipes for stdout, stderr, stdin
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Launch process
        do {
            try process.run()
        } catch {
            throw ScriptExecutionError.processError(
                "Failed to launch process: \(error.localizedDescription)",
            )
        }

        // Write stdin if provided
        if let stdinData = stdin?.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Wait for process with timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let duration = Date().timeIntervalSince(startTime)

        // Check if timed out
        if duration >= timeout, process.terminationStatus == SIGTERM {
            throw ScriptExecutionError.timeout
        }

        // Read stdout and stderr
        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        return ShellCommandResult(
            success: exitCode == 0,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            duration: duration,
            error: exitCode != 0 ? "Command exited with code \(exitCode)" : nil,
        )
    }

    /// Validates a script without executing it.
    ///
    /// - Parameters:
    ///   - script: The script source code
    ///   - type: The script type (AppleScript or JXA)
    /// - Returns: Validation result
    func validateScript(_ script: String, type: ScriptType) async throws -> ScriptValidationResult {
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

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add operation task
            group.addTask {
                try operation()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ScriptExecutionError.timeout
            }

            // Return first result (either operation or timeout)
            guard let result = try await group.next() else {
                throw ScriptExecutionError.executionFailed("Task group was cancelled before completion")
            }
            group.cancelAll()
            return result
        }
    }
}

enum ScriptType {
    case appleScript
    case jxa
    case shell
}
