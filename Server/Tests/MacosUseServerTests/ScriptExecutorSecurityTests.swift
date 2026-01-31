import Foundation
@testable import MacosUseServer
import XCTest

/// Tests for ScriptExecutor security validation.
/// These tests verify that dangerous operations are correctly blocked
/// and that error messages provide actionable guidance.
final class ScriptExecutorSecurityTests: XCTestCase {
    // MARK: - AppleScript Security Tests

    func testAppleScriptBlocksRmRfRoot() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeAppleScript(
                "do shell script \"rm -rf /\"",
                compileOnly: true,
            )
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("rm -rf /"),
                "Error should mention the dangerous pattern",
            )
            XCTAssertTrue(
                message.contains("blocked for safety"),
                "Error should explain it was blocked for safety",
            )
            XCTAssertTrue(
                message.contains("specific path"),
                "Error should suggest using a specific path",
            )
        }
    }

    func testAppleScriptBlocksSudo() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeAppleScript(
                "do shell script \"sudo touch /etc/test\"",
                compileOnly: true,
            )
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("sudo"),
                "Error should mention sudo",
            )
            XCTAssertTrue(
                message.contains("not allowed"),
                "Error should state it's not allowed",
            )
            XCTAssertTrue(
                message.contains("current user"),
                "Error should explain scripts run as current user",
            )
        }
    }

    func testAppleScriptAllowsSafeCommands() async throws {
        let executor = ScriptExecutor.shared

        // This should not throw a security error (although it may fail compilation)
        do {
            _ = try await executor.executeAppleScript(
                "return \"hello\"",
                compileOnly: true,
            )
            // Success - no security violation
        } catch let error as ScriptExecutionError {
            if case .securityViolation = error {
                XCTFail("Should not throw security violation for safe script")
            }
            // Other errors (like compilation) are acceptable
        }
    }

    // MARK: - JXA Security Tests

    func testJXABlocksRmRfRoot() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeJavaScript(
                "ObjC.import('stdlib'); $.system('rm -rf /')",
                compileOnly: true,
            )
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("rm -rf /"))
            XCTAssertTrue(message.contains("blocked for safety"))
        }
    }

    func testJXABlocksSudo() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeJavaScript(
                "ObjC.import('stdlib'); $.system('sudo touch /etc/test')",
                compileOnly: true,
            )
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("sudo"))
            XCTAssertTrue(message.contains("JXA"))
            XCTAssertTrue(message.contains("current user"))
        }
    }

    // MARK: - Shell Command Security Tests

    func testShellBlocksRmRfRoot() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeShellCommand("rm -rf /")
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("rm -rf /"))
            XCTAssertTrue(message.contains("blocked for safety"))
            XCTAssertTrue(message.contains("specific path"))
        }
    }

    func testShellBlocksSudoPrefix() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeShellCommand("sudo ls /")
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("sudo"))
            XCTAssertTrue(message.contains("not allowed"))
        }
    }

    func testShellBlocksSudoInArgs() async throws {
        let executor = ScriptExecutor.shared

        do {
            _ = try await executor.executeShellCommand("ls", args: ["sudo", "/"])
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("sudo"))
        }
    }

    func testShellBlocksSudoInCommandChain() async throws {
        let executor = ScriptExecutor.shared

        // Command chains like "echo test && sudo rm foo" should be blocked
        do {
            _ = try await executor.executeShellCommand("echo test && sudo rm /etc/passwd")
            XCTFail("Expected securityViolation error")
        } catch let error as ScriptExecutionError {
            guard case let .securityViolation(message) = error else {
                XCTFail("Expected securityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("sudo"))
            XCTAssertTrue(message.contains("not allowed"))
        }
    }

    func testShellAllowsSafeCommands() async throws {
        let executor = ScriptExecutor.shared

        // This should work without security violation
        let result = try await executor.executeShellCommand("echo 'hello world'")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("hello world"))
    }

    func testShellAllowsSafeRm() async throws {
        let executor = ScriptExecutor.shared

        // rm without -rf / should be allowed (even if the file doesn't exist)
        do {
            _ = try await executor.executeShellCommand("rm /tmp/nonexistent_file_12345")
            // May fail because file doesn't exist, but shouldn't be blocked
        } catch let error as ScriptExecutionError {
            if case .securityViolation = error {
                XCTFail("Should not block rm on specific paths")
            }
            // Other errors are acceptable (file not found, etc.)
        }
    }

    // MARK: - Error Message Quality Tests

    func testSecurityViolationDescriptionIsActionable() {
        let error = ScriptExecutionError.securityViolation(
            "Test message with guidance",
        )
        let description = error.description
        XCTAssertTrue(description.hasPrefix("Security violation:"))
        XCTAssertTrue(description.contains("Test message with guidance"))
    }
}
