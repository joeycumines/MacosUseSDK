import Foundation
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Unit tests for ScriptingMethods RPCs (executeAppleScript, executeJavaScript,
/// executeShellCommand, validateScript, getScriptingDictionaries).
final class ScriptingMethodsTests: XCTestCase {
    var service: MacosUseService!
    var stateStore: AppStateStore!

    override func setUp() async throws {
        stateStore = AppStateStore()
        let mock = MockSystemOperations()
        let registry = WindowRegistry(system: mock)
        service = MacosUseService(
            stateStore: stateStore,
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )
    }

    override func tearDown() async throws {
        service = nil
        stateStore = nil
    }

    // MARK: - Helpers

    private func makeAppleScriptRequest(
        _ msg: Macosusesdk_V1_ExecuteAppleScriptRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_ExecuteAppleScriptRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeJavaScriptRequest(
        _ msg: Macosusesdk_V1_ExecuteJavaScriptRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_ExecuteJavaScriptRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeShellCommandRequest(
        _ msg: Macosusesdk_V1_ExecuteShellCommandRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_ExecuteShellCommandRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeValidateScriptRequest(
        _ msg: Macosusesdk_V1_ValidateScriptRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_ValidateScriptRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeGetScriptingDictionariesRequest(
        _ msg: Macosusesdk_V1_GetScriptingDictionariesRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_GetScriptingDictionariesRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeAppleScriptContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ExecuteAppleScript.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeJavaScriptContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ExecuteJavaScript.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeShellCommandContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ExecuteShellCommand.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeValidateScriptContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ValidateScript.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeGetScriptingDictionariesContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.GetScriptingDictionaries.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    // MARK: - executeAppleScript Tests

    func testExecuteAppleScriptWithValidScript() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "return 42"
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success, "Valid AppleScript should execute successfully")
        XCTAssertEqual(msg.output, "42", "Output should be the return value")
        XCTAssertTrue(msg.error.isEmpty, "No error expected for valid script")
        XCTAssertGreaterThan(msg.executionDuration.seconds + Int64(msg.executionDuration.nanos), 0, "Duration should be recorded")
    }

    func testExecuteAppleScriptWithStringResult() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "return \"hello world\""
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.output, "hello world")
    }

    func testExecuteAppleScriptWithSyntaxError() async throws {
        // This is invalid AppleScript syntax
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "this is not valid applescript syntax {"
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success, "Script with syntax error should fail")
        XCTAssertFalse(msg.error.isEmpty, "Error message should be provided")
        XCTAssertTrue(
            msg.error.lowercased().contains("compilation") || msg.error.lowercased().contains("error") || msg.error.lowercased().contains("syntax"),
            "Error should indicate compilation/syntax problem",
        )
    }

    func testExecuteAppleScriptWithEmptyScript() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest()

        do {
            _ = try await service.executeAppleScript(
                request: makeAppleScriptRequest(request),
                context: makeAppleScriptContext(),
            )
            XCTFail("Expected validation error for empty script")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument, "Should be invalidArgument for validation error")
            XCTAssertTrue(error.message.contains("script"), "Error message should mention script field")
        }
    }

    func testExecuteAppleScriptCompileOnlyMode() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "display dialog \"test\""
            $0.compileOnly = true
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertTrue(msg.output.contains("compiled"), "Output should indicate compilation only")
    }

    func testExecuteAppleScriptSecurityBlocksSudo() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "do shell script \"sudo echo hello\""
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.lowercased().contains("security") || msg.error.lowercased().contains("sudo"))
    }

    func testExecuteAppleScriptSecurityBlocksRmRf() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "do shell script \"rm -rf /\""
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.lowercased().contains("security") || msg.error.lowercased().contains("violation"))
    }

    func testExecuteAppleScriptWithCustomTimeout() async throws {
        let request = Macosusesdk_V1_ExecuteAppleScriptRequest.with {
            $0.script = "return 1 + 1"
            $0.timeout = SwiftProtobuf.Google_Protobuf_Duration.with {
                $0.seconds = 5
                $0.nanos = 500_000_000 // 5.5 seconds
            }
        }

        let response = try await service.executeAppleScript(
            request: makeAppleScriptRequest(request),
            context: makeAppleScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.output, "2")
    }

    // MARK: - executeJavaScript Tests

    func testExecuteJavaScriptWithValidScript() async throws {
        let request = Macosusesdk_V1_ExecuteJavaScriptRequest.with {
            $0.script = "1 + 1"
        }

        let response = try await service.executeJavaScript(
            request: makeJavaScriptRequest(request),
            context: makeJavaScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success, "Valid JXA script should execute successfully")
        // JXA numeric result may be "2" or have different formatting
        XCTAssertTrue(msg.error.isEmpty, "No error expected for valid script")
    }

    func testExecuteJavaScriptWithSyntaxError() async throws {
        let request = Macosusesdk_V1_ExecuteJavaScriptRequest.with {
            $0.script = "function( { invalid"
        }

        let response = try await service.executeJavaScript(
            request: makeJavaScriptRequest(request),
            context: makeJavaScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success, "Script with syntax error should fail")
        XCTAssertFalse(msg.error.isEmpty, "Error message should be provided")
    }

    func testExecuteJavaScriptWithEmptyScript() async throws {
        let request = Macosusesdk_V1_ExecuteJavaScriptRequest()

        do {
            _ = try await service.executeJavaScript(
                request: makeJavaScriptRequest(request),
                context: makeJavaScriptContext(),
            )
            XCTFail("Expected validation error for empty script")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("script"))
        }
    }

    func testExecuteJavaScriptCompileOnlyMode() async throws {
        let request = Macosusesdk_V1_ExecuteJavaScriptRequest.with {
            $0.script = "var x = 42; x * 2"
            $0.compileOnly = true
        }

        let response = try await service.executeJavaScript(
            request: makeJavaScriptRequest(request),
            context: makeJavaScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertTrue(msg.output.contains("compiled"))
    }

    func testExecuteJavaScriptSecurityBlocksSudo() async throws {
        let request = Macosusesdk_V1_ExecuteJavaScriptRequest.with {
            $0.script = "app.doShellScript('sudo echo test')"
        }

        let response = try await service.executeJavaScript(
            request: makeJavaScriptRequest(request),
            context: makeJavaScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.lowercased().contains("security") || msg.error.lowercased().contains("sudo"))
    }

    // MARK: - executeShellCommand Tests

    func testExecuteShellCommandWithValidCommand() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo hello"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success, "Valid shell command should succeed")
        XCTAssertEqual(msg.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(msg.exitCode, 0)
        XCTAssertTrue(msg.stderr.isEmpty || msg.error.isEmpty)
    }

    func testExecuteShellCommandWithArgs() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo"
            $0.args = ["arg1", "arg2"]
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertTrue(msg.stdout.contains("arg1"))
        XCTAssertTrue(msg.stdout.contains("arg2"))
    }

    func testExecuteShellCommandWithNonZeroExitCode() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "false" // /usr/bin/false exits with 1
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success, "Command that exits non-zero should not be success")
        XCTAssertEqual(msg.exitCode, 1, "Exit code should be 1 for 'false' command")
        XCTAssertFalse(msg.error.isEmpty, "Error message should indicate non-zero exit")
    }

    func testExecuteShellCommandWithTimeout() async throws {
        // Sleep for longer than timeout
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "sleep 10"
            $0.timeout = SwiftProtobuf.Google_Protobuf_Duration.with {
                $0.seconds = 1
                $0.nanos = 0
            }
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success, "Timed out command should fail")
        XCTAssertTrue(
            msg.error.lowercased().contains("timeout") || msg.error.lowercased().contains("timed"),
            "Error should indicate timeout",
        )
    }

    func testExecuteShellCommandWithEmptyCommand() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest()

        do {
            _ = try await service.executeShellCommand(
                request: makeShellCommandRequest(request),
                context: makeShellCommandContext(),
            )
            XCTFail("Expected validation error for empty command")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("command"))
        }
    }

    func testExecuteShellCommandWithStdin() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "cat"
            $0.stdin = "hello from stdin"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello from stdin")
    }

    func testExecuteShellCommandWithEnvironment() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo $MY_VAR"
            $0.environment = ["MY_VAR": "test_value"]
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "test_value")
    }

    func testExecuteShellCommandWithCustomShell() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo $0"
            $0.shell = "/bin/zsh"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertTrue(msg.stdout.contains("zsh"))
    }

    func testExecuteShellCommandSecurityBlocksSudo() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "sudo echo hello"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.lowercased().contains("security") || msg.error.lowercased().contains("sudo"))
    }

    func testExecuteShellCommandSecurityBlocksRmRf() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "rm -rf /"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.lowercased().contains("security") || msg.error.lowercased().contains("violation"))
    }

    func testExecuteShellCommandRecordsDuration() async throws {
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "true"
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        // Duration should be positive (at least some nanoseconds)
        let hasNonZeroDuration = msg.executionDuration.seconds > 0 || msg.executionDuration.nanos > 0
        XCTAssertTrue(hasNonZeroDuration, "Duration should be recorded")
    }

    // MARK: - validateScript Tests

    func testValidateScriptAppleScriptValid() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "return 42"
            $0.type = .applescript
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.valid, "Valid AppleScript should validate successfully")
        XCTAssertTrue(msg.errors.isEmpty, "No errors expected for valid script")
    }

    func testValidateScriptAppleScriptSyntaxError() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "this is { invalid syntax"
            $0.type = .applescript
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.valid, "Invalid AppleScript should fail validation")
        XCTAssertFalse(msg.errors.isEmpty, "Errors should be reported for syntax errors")
    }

    func testValidateScriptJXAValid() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "var x = 1 + 1; x"
            $0.type = .jxa
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.valid, "Valid JXA should validate successfully")
        XCTAssertTrue(msg.errors.isEmpty)
    }

    func testValidateScriptJXASyntaxError() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "function(( {"
            $0.type = .jxa
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.valid)
        XCTAssertFalse(msg.errors.isEmpty)
    }

    func testValidateScriptShellNonEmpty() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "echo hello"
            $0.type = .shell
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        // Shell scripts only check for non-empty
        XCTAssertTrue(msg.valid)
    }

    func testValidateScriptShellEmpty() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = ""
            $0.type = .shell
        }

        do {
            _ = try await service.validateScript(
                request: makeValidateScriptRequest(request),
                context: makeValidateScriptContext(),
            )
            XCTFail("Expected validation error for empty script")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testValidateScriptRequiresType() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "return 1"
            // type not set, defaults to UNSPECIFIED
        }

        do {
            _ = try await service.validateScript(
                request: makeValidateScriptRequest(request),
                context: makeValidateScriptContext(),
            )
            XCTFail("Expected error for unspecified script type")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.lowercased().contains("type") || error.message.lowercased().contains("specified"))
        }
    }

    func testValidateScriptEmptyScriptThrows() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = ""
            $0.type = .applescript
        }

        do {
            _ = try await service.validateScript(
                request: makeValidateScriptRequest(request),
                context: makeValidateScriptContext(),
            )
            XCTFail("Expected validation error for empty script")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - getScriptingDictionaries Tests

    func testGetScriptingDictionariesReturnsSystemApps() async throws {
        let request = Macosusesdk_V1_GetScriptingDictionariesRequest.with {
            $0.name = "scriptingDictionaries"
        }

        let response = try await service.getScriptingDictionaries(
            request: makeGetScriptingDictionariesRequest(request),
            context: makeGetScriptingDictionariesContext(),
        )
        let msg = try response.message

        // Should always include system apps
        XCTAssertFalse(msg.dictionaries.isEmpty, "Should have at least system apps")

        // Check for expected system apps
        let bundleIDs = msg.dictionaries.map(\.bundleID)
        XCTAssertTrue(bundleIDs.contains("com.apple.finder"), "Should include Finder")
        XCTAssertTrue(bundleIDs.contains("com.apple.systemevents"), "Should include System Events")
    }

    func testGetScriptingDictionariesIncludesAppleScriptSupport() async throws {
        let request = Macosusesdk_V1_GetScriptingDictionariesRequest.with {
            $0.name = "scriptingDictionaries"
        }

        let response = try await service.getScriptingDictionaries(
            request: makeGetScriptingDictionariesRequest(request),
            context: makeGetScriptingDictionariesContext(),
        )
        let msg = try response.message

        for dictionary in msg.dictionaries {
            XCTAssertTrue(dictionary.supportsApplescript, "System apps should support AppleScript")
            XCTAssertTrue(dictionary.supportsJxa, "System apps should support JXA")
        }
    }

    func testGetScriptingDictionariesInvalidName() async throws {
        let request = Macosusesdk_V1_GetScriptingDictionariesRequest.with {
            $0.name = "invalid-name"
        }

        do {
            _ = try await service.getScriptingDictionaries(
                request: makeGetScriptingDictionariesRequest(request),
                context: makeGetScriptingDictionariesContext(),
            )
            XCTFail("Expected error for invalid resource name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testGetScriptingDictionariesUsesSystemBundleID() async throws {
        let store = AppStateStore()
        let pid: pid_t = 4242
        let app = Macosusesdk_V1_Application.with {
            $0.name = "applications/\(pid)"
            $0.pid = pid
            $0.displayName = "MyApp"
        }

        await store.addTarget(app)

        let mock = MockSystemOperations(bundleIDs: [pid: "com.test.bundle"])
        let registry = WindowRegistry(system: mock)
        let provider = MacosUseService(stateStore: store, operationStore: OperationStore(), windowRegistry: registry, system: mock)

        let req = Macosusesdk_V1_GetScriptingDictionariesRequest.with { $0.name = "scriptingDictionaries" }

        let response = try await provider.getScriptingDictionaries(
            request: makeGetScriptingDictionariesRequest(req),
            context: makeGetScriptingDictionariesContext(),
        )

        let msg = try response.message

        let found = msg.dictionaries.first { $0.bundleID == "com.test.bundle" }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.application, "applications/\(pid)")
    }

    func testGetScriptingDictionariesIncludesCommandsAndClasses() async throws {
        let request = Macosusesdk_V1_GetScriptingDictionariesRequest.with {
            $0.name = "scriptingDictionaries"
        }

        let response = try await service.getScriptingDictionaries(
            request: makeGetScriptingDictionariesRequest(request),
            context: makeGetScriptingDictionariesContext(),
        )
        let msg = try response.message

        for dictionary in msg.dictionaries {
            XCTAssertFalse(dictionary.commands.isEmpty, "Dictionaries should have commands: \(dictionary.application)")
            XCTAssertFalse(dictionary.classes.isEmpty, "Dictionaries should have classes: \(dictionary.application)")
            XCTAssertTrue(dictionary.commands.contains("activate"), "Should include 'activate' command")
        }
    }

    // MARK: - Timeout Parsing Tests

    func testTimeoutParsingFromDuration() async throws {
        // Test that timeout with both seconds and nanos is parsed correctly
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo test"
            $0.timeout = SwiftProtobuf.Google_Protobuf_Duration.with {
                $0.seconds = 10
                $0.nanos = 500_000_000 // 500 milliseconds
            }
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        // If command completed, timeout was parsed correctly (would fail if timeout was 0)
    }

    func testDefaultTimeoutWhenNotProvided() async throws {
        // When no timeout is provided, should use default (30s)
        let request = Macosusesdk_V1_ExecuteShellCommandRequest.with {
            $0.command = "echo quick"
            // No timeout set
        }

        let response = try await service.executeShellCommand(
            request: makeShellCommandRequest(request),
            context: makeShellCommandContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success, "Command should succeed with default timeout")
    }

    // MARK: - Script Type Validation Tests

    func testScriptTypeAppleScript() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "tell application \"Finder\" to activate"
            $0.type = .applescript
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.valid)
    }

    func testScriptTypeJXA() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "Application('Finder').activate()"
            $0.type = .jxa
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.valid)
    }

    func testScriptTypeShell() async throws {
        let request = Macosusesdk_V1_ValidateScriptRequest.with {
            $0.script = "#!/bin/bash\necho hello"
            $0.type = .shell
        }

        let response = try await service.validateScript(
            request: makeValidateScriptRequest(request),
            context: makeValidateScriptContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.valid)
    }
}
