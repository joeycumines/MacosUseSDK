import Foundation
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for MacroExecutor error types and supporting structures.
final class MacroExecutorTests: XCTestCase {
    // MARK: - MacroExecutionError Description Tests

    func testMacroExecutionError_macroNotFound_description() {
        let error = MacroExecutionError.macroNotFound("TestMacro")
        XCTAssertEqual(error.description, "Macro not found: TestMacro")
    }

    func testMacroExecutionError_invalidAction_description() {
        let error = MacroExecutionError.invalidAction("Missing parameter")
        XCTAssertEqual(error.description, "Invalid action: Missing parameter")
    }

    func testMacroExecutionError_conditionFailed_description() {
        let error = MacroExecutionError.conditionFailed("Element not visible")
        XCTAssertEqual(error.description, "Condition failed: Element not visible")
    }

    func testMacroExecutionError_variableNotFound_description() {
        let error = MacroExecutionError.variableNotFound("myVar")
        XCTAssertEqual(error.description, "Variable not found: myVar")
    }

    func testMacroExecutionError_elementNotFound_description() {
        let error = MacroExecutionError.elementNotFound("role:Button")
        XCTAssertEqual(error.description, "Element not found: role:Button")
    }

    func testMacroExecutionError_executionFailed_description() {
        let error = MacroExecutionError.executionFailed("Click failed")
        XCTAssertEqual(error.description, "Execution failed: Click failed")
    }

    func testMacroExecutionError_timeout_description() {
        let error = MacroExecutionError.timeout
        XCTAssertEqual(error.description, "Macro execution timed out")
    }

    func testMacroExecutionError_allCasesHaveNonEmptyDescription() {
        let errors: [MacroExecutionError] = [
            .macroNotFound("test"),
            .invalidAction("test"),
            .conditionFailed("test"),
            .variableNotFound("test"),
            .elementNotFound("test"),
            .executionFailed("test"),
            .timeout,
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: - MacroContext Tests

    func testMacroContext_defaultInitialization() {
        let context = MacroContext()

        XCTAssertEqual(context.variables.count, 0)
        XCTAssertEqual(context.parameters.count, 0)
        XCTAssertEqual(context.parent, "")
        XCTAssertNil(context.pid)
    }

    func testMacroContext_initWithValues() {
        var context = MacroContext()
        context.variables = ["key1": "value1"]
        context.parameters = ["param1": "paramValue1"]
        context.parent = "applications/com.apple.Calculator"
        context.pid = 1234

        XCTAssertEqual(context.variables["key1"], "value1")
        XCTAssertEqual(context.parameters["param1"], "paramValue1")
        XCTAssertEqual(context.parent, "applications/com.apple.Calculator")
        XCTAssertEqual(context.pid, 1234)
    }

    func testMacroContext_variablesMutable() {
        var context = MacroContext()

        context.variables["a"] = "1"
        context.variables["b"] = "2"

        XCTAssertEqual(context.variables.count, 2)
        XCTAssertEqual(context.variables["a"], "1")
        XCTAssertEqual(context.variables["b"], "2")

        context.variables["a"] = "updated"
        XCTAssertEqual(context.variables["a"], "updated")
    }

    func testMacroContext_parametersMutable() {
        var context = MacroContext()

        context.parameters["input"] = "hello"
        context.parameters["output"] = "world"

        XCTAssertEqual(context.parameters.count, 2)
    }

    // MARK: - MacroExecutionError Conformance Tests

    func testMacroExecutionError_conformsToError() {
        let error: Error = MacroExecutionError.timeout

        // Verify it can be caught as Error
        XCTAssertNotNil(error)
    }

    func testMacroExecutionError_conformsToCustomStringConvertible() {
        let error: CustomStringConvertible = MacroExecutionError.macroNotFound("Test")

        // String(describing:) uses description property
        let desc = String(describing: error)
        XCTAssertEqual(desc, "Macro not found: Test")
    }

    func testMacroExecutionError_canBeUsedInStringInterpolation() {
        let error = MacroExecutionError.executionFailed("Failed to click")
        let message = "Error occurred: \(error)"

        XCTAssertTrue(message.contains("Execution failed: Failed to click"))
    }

    func testMacroExecutionError_emptyStringHandledGracefully() {
        let error = MacroExecutionError.invalidAction("")

        // Empty message should still produce valid description
        XCTAssertEqual(error.description, "Invalid action: ")
    }

    func testMacroExecutionError_specialCharactersInMessage() {
        let error = MacroExecutionError.executionFailed("Failed: <button id=\"submit\">")

        XCTAssertTrue(error.description.contains("<button"))
        XCTAssertTrue(error.description.contains("submit"))
    }

    func testMacroExecutionError_unicodeInMessage() {
        let error = MacroExecutionError.macroNotFound("マクロ")

        XCTAssertTrue(error.description.contains("マクロ"))
    }
}
