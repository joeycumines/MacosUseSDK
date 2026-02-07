import Foundation
@testable import MacosUseServer
import XCTest

/// Unit tests for ScriptExecutionError descriptions and script result types.
final class ScriptExecutorErrorTests: XCTestCase {
    // MARK: - ScriptExecutionError Description Tests

    func testTimeout_description() {
        let error = ScriptExecutionError.timeout
        XCTAssertEqual(error.description, "Script execution timed out")
    }

    func testCompilationFailed_description() {
        let error = ScriptExecutionError.compilationFailed("Syntax error at line 5")
        XCTAssertEqual(error.description, "Script compilation failed: Syntax error at line 5")
    }

    func testExecutionFailed_description() {
        let error = ScriptExecutionError.executionFailed("Permission denied")
        XCTAssertEqual(error.description, "Script execution failed: Permission denied")
    }

    func testInvalidScript_description() {
        let error = ScriptExecutionError.invalidScript
        XCTAssertEqual(error.description, "Invalid script")
    }

    func testInvalidScriptType_description() {
        let error = ScriptExecutionError.invalidScriptType
        XCTAssertEqual(error.description, "Invalid script type")
    }

    func testCommandNotFound_description() {
        let error = ScriptExecutionError.commandNotFound("nonexistent_command")
        XCTAssertEqual(error.description, "Command not found: nonexistent_command")
    }

    func testSecurityViolation_description() {
        let error = ScriptExecutionError.securityViolation("Attempted to run rm -rf /")
        XCTAssertEqual(error.description, "Security violation: Attempted to run rm -rf /")
    }

    func testProcessError_description() {
        let error = ScriptExecutionError.processError("Exit code 127")
        XCTAssertEqual(error.description, "Process error: Exit code 127")
    }

    func testAllCases_haveNonEmptyDescription() {
        let errors: [ScriptExecutionError] = [
            .timeout,
            .compilationFailed("test"),
            .executionFailed("test"),
            .invalidScript,
            .invalidScriptType,
            .commandNotFound("test"),
            .securityViolation("test"),
            .processError("test"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: - ScriptExecutionError Edge Cases

    func testEmptyMessage() {
        let error = ScriptExecutionError.compilationFailed("")
        XCTAssertEqual(error.description, "Script compilation failed: ")
    }

    func testUnicodeMessage() {
        let error = ScriptExecutionError.executionFailed("スクリプトエラー")
        XCTAssertTrue(error.description.contains("スクリプトエラー"))
    }

    func testSpecialCharactersInMessage() {
        let error = ScriptExecutionError.securityViolation("Blocked: `rm -rf /`")
        XCTAssertTrue(error.description.contains("`rm -rf /`"))
    }

    func testNewlineInMessage() {
        let error = ScriptExecutionError.compilationFailed("Line 1\nLine 2")
        XCTAssertTrue(error.description.contains("Line 1\nLine 2"))
    }

    // MARK: - Conformance Tests

    func testScriptExecutionError_conformsToError() {
        let error: Error = ScriptExecutionError.timeout
        XCTAssertNotNil(error)
    }

    func testScriptExecutionError_conformsToCustomStringConvertible() {
        let error: CustomStringConvertible = ScriptExecutionError.invalidScript
        XCTAssertFalse(String(describing: error).isEmpty)
    }

    // MARK: - ScriptExecutionResult Tests

    func testScriptExecutionResult_initialization() {
        let result = ScriptExecutionResult(
            success: true,
            output: "Hello World",
            error: nil,
            duration: 0.5,
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "Hello World")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.duration, 0.5, accuracy: 0.001)
    }

    func testScriptExecutionResult_withError() {
        let result = ScriptExecutionResult(
            success: false,
            output: "",
            error: "Syntax error",
            duration: 0.1,
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "Syntax error")
    }

    // MARK: - ShellCommandResult Tests

    func testShellCommandResult_initialization() {
        let result = ShellCommandResult(
            success: true,
            stdout: "output line",
            stderr: "",
            exitCode: 0,
            duration: 0.25,
            error: nil,
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.stdout, "output line")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.duration, 0.25, accuracy: 0.001)
        XCTAssertNil(result.error)
    }

    func testShellCommandResult_withFailure() {
        let result = ShellCommandResult(
            success: false,
            stdout: "",
            stderr: "command not found",
            exitCode: 127,
            duration: 0.05,
            error: "Command failed",
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stderr, "command not found")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.error, "Command failed")
    }

    func testShellCommandResult_negativeExitCode() {
        // Some processes can return negative exit codes (signal-based termination)
        let result = ShellCommandResult(
            success: false,
            stdout: "",
            stderr: "Killed",
            exitCode: -9,
            duration: 1.0,
            error: "Process terminated",
        )

        XCTAssertEqual(result.exitCode, -9)
    }

    // MARK: - ScriptValidationResult Tests

    func testScriptValidationResult_valid() {
        let result = ScriptValidationResult(
            valid: true,
            errors: [],
            warnings: [],
        )

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.errors.count, 0)
        XCTAssertEqual(result.warnings.count, 0)
    }

    func testScriptValidationResult_invalid() {
        let result = ScriptValidationResult(
            valid: false,
            errors: ["Syntax error at line 1", "Missing end statement"],
            warnings: [],
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(result.errors.contains("Syntax error at line 1"))
        XCTAssertTrue(result.errors.contains("Missing end statement"))
    }

    func testScriptValidationResult_withWarnings() {
        let result = ScriptValidationResult(
            valid: true,
            errors: [],
            warnings: ["Deprecated syntax used"],
        )

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testScriptValidationResult_mixedErrorsAndWarnings() {
        let result = ScriptValidationResult(
            valid: false,
            errors: ["Fatal error"],
            warnings: ["Warning 1", "Warning 2"],
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.warnings.count, 2)
    }
}
