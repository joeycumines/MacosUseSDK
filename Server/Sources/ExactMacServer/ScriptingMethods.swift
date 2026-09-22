import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

private func parseExecutionTimeout(
    _ duration: SwiftProtobuf.Google_Protobuf_Duration,
    isPresent: Bool,
) throws -> TimeInterval {
    guard isPresent else {
        return 30
    }
    return try RequestNumericValidation.positiveProtobufTimeoutSeconds(duration)
}

private func executeWithRequestCancellation<Result: Sendable>(
    context: ServerContext,
    operation: @Sendable @escaping () async throws -> Result,
) async throws -> Result {
    let execution = Task {
        try await operation()
    }
    let cancellation = Task {
        do {
            try await context.cancellation.cancelled
            execution.cancel()
        } catch {
            // The operation completed and cancelled this watcher, or the
            // request cancellation source itself terminated.
        }
    }

    do {
        let result = try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            cancellation.cancel()
            execution.cancel()
        }
        cancellation.cancel()
        await cancellation.value
        return result
    } catch is CancellationError {
        cancellation.cancel()
        execution.cancel()
        await cancellation.value
        throw RPCError(code: .cancelled, message: "Script execution was cancelled")
    } catch {
        cancellation.cancel()
        await cancellation.value
        throw error
    }
}

extension ExactMacService {
    func executeAppleScript(
        request: ServerRequest<Exactmac_V1_ExecuteAppleScriptRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ExecuteAppleScriptResponse> {
        Self.logger.info("executeAppleScript called")
        let req = request.message

        // Validate script is not empty
        guard !req.script.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "script is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "script",
            )
        }

        let timeout = try parseExecutionTimeout(req.timeout, isPresent: req.hasTimeout)

        do {
            // Execute AppleScript using ScriptExecutor
            let result = try await executeWithRequestCancellation(context: context) {
                try await self.scriptExecutor.executeAppleScript(
                    req.script,
                    timeout: timeout,
                    compileOnly: req.compileOnly,
                )
            }

            let response = Exactmac_V1_ExecuteAppleScriptResponse.with {
                $0.success = result.success
                $0.output = result.output
                if let error = result.error {
                    $0.error = error
                }
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
            }
            return ServerResponse(message: response)
        } catch let error as RPCError {
            throw error
        } catch let error as ScriptExecutionError {
            let response = Exactmac_V1_ExecuteAppleScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Exactmac_V1_ExecuteAppleScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func executeJavaScript(
        request: ServerRequest<Exactmac_V1_ExecuteJavaScriptRequest>,
        context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ExecuteJavaScriptResponse> {
        Self.logger.info("executeJavaScript called")
        let req = request.message

        // Validate script is not empty
        guard !req.script.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "script is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "script",
            )
        }

        let timeout = try parseExecutionTimeout(req.timeout, isPresent: req.hasTimeout)

        do {
            // Execute JavaScript using ScriptExecutor
            let result = try await executeWithRequestCancellation(context: context) {
                try await self.scriptExecutor.executeJavaScript(
                    req.script,
                    timeout: timeout,
                    compileOnly: req.compileOnly,
                )
            }

            let response = Exactmac_V1_ExecuteJavaScriptResponse.with {
                $0.success = result.success
                $0.output = result.output
                if let error = result.error {
                    $0.error = error
                }
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
            }
            return ServerResponse(message: response)
        } catch let error as RPCError {
            throw error
        } catch let error as ScriptExecutionError {
            let response = Exactmac_V1_ExecuteJavaScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Exactmac_V1_ExecuteJavaScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func executeShellCommand(
        request: ServerRequest<Exactmac_V1_ExecuteShellCommandRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ExecuteShellCommandResponse> {
        Self.logger.info("executeShellCommand called")
        let req = request.message

        // Validate command is not empty
        guard !req.command.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "command is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "command",
            )
        }

        let timeout = try parseExecutionTimeout(req.timeout, isPresent: req.hasTimeout)

        // Extract shell (default to /bin/bash)
        let shell = req.shell.isEmpty ? "/bin/bash" : req.shell

        // Extract working directory (optional)
        let workingDir = req.workingDirectory.isEmpty ? nil : req.workingDirectory

        // Extract environment (optional)
        let environment =
            req.environment.isEmpty
                ? nil : Dictionary(uniqueKeysWithValues: req.environment.map { ($0.key, $0.value) })

        // Extract stdin (optional)
        let stdin = req.stdin.isEmpty ? nil : req.stdin

        do {
            // Execute shell command using ScriptExecutor
            let result = try await executeWithRequestCancellation(context: context) {
                try await self.scriptExecutor.executeShellCommand(
                    req.command,
                    args: Array(req.args),
                    workingDirectory: workingDir,
                    environment: environment,
                    timeout: timeout,
                    stdin: stdin,
                    shell: shell,
                )
            }

            let response = Exactmac_V1_ExecuteShellCommandResponse.with {
                $0.success = result.success
                $0.stdout = result.stdout
                $0.stderr = result.stderr
                $0.exitCode = result.exitCode
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
                if let error = result.error {
                    $0.error = error
                }
            }
            return ServerResponse(message: response)
        } catch let error as RPCError {
            throw error
        } catch let error as ScriptExecutionError {
            let response = Exactmac_V1_ExecuteShellCommandResponse.with {
                $0.success = false
                $0.stdout = ""
                $0.stderr = ""
                $0.exitCode = -1
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Exactmac_V1_ExecuteShellCommandResponse.with {
                $0.success = false
                $0.stdout = ""
                $0.stderr = ""
                $0.exitCode = -1
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func validateScript(
        request: ServerRequest<Exactmac_V1_ValidateScriptRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ValidateScriptResponse> {
        Self.logger.info("validateScript called")
        let req = request.message

        // Validate script is not empty
        guard !req.script.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "script is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "script",
            )
        }

        // Convert proto ScriptType to internal ScriptType
        let scriptType: ScriptType
        switch req.type {
        case .applescript:
            scriptType = .appleScript
        case .jxa:
            scriptType = .jxa
        case .shell:
            scriptType = .shell
        case .unspecified, .UNRECOGNIZED:
            throw RPCError(code: .invalidArgument, message: "Script type must be specified")
        }

        do {
            // Validate script using the composition-owned executor.
            let result = try await executeWithRequestCancellation(context: context) {
                try await self.scriptExecutor.validateScript(req.script, type: scriptType)
            }

            let response = Exactmac_V1_ValidateScriptResponse.with {
                $0.valid = result.valid
                $0.errors = result.errors
                $0.warnings = result.warnings
            }
            return ServerResponse(message: response)
        } catch let error as RPCError {
            throw error
        } catch let error as ScriptExecutionError {
            let response = Exactmac_V1_ValidateScriptResponse.with {
                $0.valid = false
                $0.errors = [error.description]
                $0.warnings = []
            }
            return ServerResponse(message: response)
        } catch {
            let response = Exactmac_V1_ValidateScriptResponse.with {
                $0.valid = false
                $0.errors = ["Unexpected error: \(error.localizedDescription)"]
                $0.warnings = []
            }
            return ServerResponse(message: response)
        }
    }

    func getScriptingDictionaries(
        request: ServerRequest<Exactmac_V1_GetScriptingDictionariesRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ScriptingDictionaries> {
        Self.logger.info("getScriptingDictionaries called")
        let req = request.message

        // Validate resource name (singleton: "scriptingDictionaries")
        guard req.name == "scriptingDictionaries" else {
            throw RPCError(
                code: .invalidArgument, message: "Invalid scripting dictionaries name: \(req.name)",
            )
        }

        // Get all tracked applications
        let applications = await stateStore.listTargets()

        var dictionaries: [Exactmac_V1_ScriptingDictionary] = []

        // For each application, check if it has scripting support
        for app in applications {
            // Resolve bundle ID from PID via injected SystemOperations
            let pid = app.pid
            let bundleId = system.getRunningApplicationBundleID(pid: pid) ?? "unknown"

            // Create dictionary entry for the application
            let dictionary = Exactmac_V1_ScriptingDictionary.with {
                $0.application = app.name
                $0.bundleID = bundleId
                // Most macOS applications support AppleScript
                $0.supportsApplescript = true
                // JXA is supported by apps that support AppleScript
                $0.supportsJxa = true
                // Note: Getting actual scripting commands/classes would require
                // parsing the application's scripting dictionary (sdef file)
                // which is complex - for now, return common commands
                $0.commands = ["activate", "quit", "open", "close", "save"]
                $0.classes = ["application", "window", "document"]
            }
            dictionaries.append(dictionary)
        }

        // Add system-level applications that are always available
        let systemApps = [
            ("Finder", "com.apple.finder"),
            ("System Events", "com.apple.systemevents"),
            ("Safari", "com.apple.Safari"),
            ("Terminal", "com.apple.Terminal"),
        ]

        for (name, bundleId) in systemApps where !dictionaries.contains(where: { $0.bundleID == bundleId }) {
            let dictionary = Exactmac_V1_ScriptingDictionary.with {
                $0.application = name
                $0.bundleID = bundleId
                $0.supportsApplescript = true
                $0.supportsJxa = true
                $0.commands = ["activate", "quit", "open", "close"]
                $0.classes = ["application", "window"]
            }
            dictionaries.append(dictionary)
        }

        let response = Exactmac_V1_ScriptingDictionaries.with {
            $0.dictionaries = dictionaries
        }
        return ServerResponse(message: response)
    }
}
