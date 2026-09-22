import ExactMacProto
@testable import ExactMacServer
import GRPCCore
import XCTest

/// Tests for SelectorParser validation logic.
final class SelectorParserTests: XCTestCase {
    private var parser: SelectorParser {
        SelectorParser.shared
    }

    // MARK: - Role Selector Tests

    func testRoleSelectorNonEmptyValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.role = "AXButton"
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.role, "AXButton")
    }

    func testRoleSelectorEmptyThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.role = ""
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
            XCTAssertTrue(rpcError.message.contains("empty"))
        }
    }

    // MARK: - Text Contains Selector Tests

    func testTextContainsNonEmptyValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.textContains = "hello"
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.textContains, "hello")
    }

    func testTextContainsEmptyThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.textContains = ""
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - Regex Selector Tests

    func testRegexValidPattern() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.textRegex = "^[a-z]+$"
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.textRegex, "^[a-z]+$")
    }

    func testRegexInvalidPatternThrowsWithDetails() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.textRegex = "[invalid"
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
            // Should include the pattern
            XCTAssertTrue(rpcError.message.contains("[invalid"))
            // Should include error description (e.g., "invalid" or similar)
            XCTAssertTrue(rpcError.message.count > 20)
        }
    }

    // MARK: - Position Selector Tests

    func testPositionSelectorPositiveToleranceValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.position = Exactmac_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 200
                $0.tolerance = 10
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.position.tolerance, 10)
    }

    func testPositionSelectorZeroToleranceValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.position = Exactmac_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 200
                $0.tolerance = 0
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.position.tolerance, 0)
    }

    func testPositionSelectorNegativeToleranceThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.position = Exactmac_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 200
                $0.tolerance = -1
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
            XCTAssertTrue(rpcError.message.contains("negative"))
        }
    }

    // MARK: - Compound Selector Tests (AND/OR)

    func testCompoundSelectorANDValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                    Exactmac_Type_ElementSelector.with { $0.textContains = "Submit" },
                ]
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.compound.selectors.count, 2)
    }

    func testCompoundSelectorORValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .or
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                    Exactmac_Type_ElementSelector.with { $0.role = "AXLink" },
                ]
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.compound.operator, .or)
    }

    func testCompoundSelectorEmptyThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = []
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector))
    }

    // MARK: - NOT Operator Tests

    func testCompoundSelectorNOTWithOneElementValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXStaticText" },
                ]
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.compound.operator, .not)
        XCTAssertEqual(result.compound.selectors.count, 1)
    }

    func testCompoundSelectorNOTWithZeroElementsThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = []
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testCompoundSelectorNOTWithMultipleElementsThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                    Exactmac_Type_ElementSelector.with { $0.role = "AXLink" },
                ]
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
            XCTAssertTrue(rpcError.message.contains("NOT"))
            XCTAssertTrue(rpcError.message.contains("exactly one"))
        }
    }

    // MARK: - Attribute Selector Tests

    func testAttributeSelectorNonEmptyValid() throws {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.attributes = Exactmac_Type_AttributeSelector.with {
                $0.attributes = ["AXIdentifier": "submit-button"]
            }
        }

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.attributes.attributes.count, 1)
    }

    func testAttributeSelectorEmptyThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.attributes = Exactmac_Type_AttributeSelector.with {
                $0.attributes = [:]
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector))
    }

    // MARK: - Empty Selector Tests

    func testEmptySelectorValid() throws {
        let selector = Exactmac_Type_ElementSelector()

        let result = try parser.parseSelector(selector)
        XCTAssertEqual(result.criteria, .none)
    }

    // MARK: - Helper Method Tests

    func testDescribeSelectorRole() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.role = "AXButton"
        }

        let description = parser.describeSelector(selector)
        XCTAssertEqual(description, "role='AXButton'")
    }

    func testDescribeSelectorCompoundNOT() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                ]
            }
        }

        let description = parser.describeSelector(selector)
        XCTAssertTrue(description.contains("NOT"))
        XCTAssertTrue(description.contains("1 selectors"))
    }

    func testIsSimpleSelectorForRole() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.role = "AXButton"
        }

        XCTAssertTrue(parser.isSimpleSelector(selector))
    }

    func testIsSimpleSelectorForCompound() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                ]
            }
        }

        XCTAssertFalse(parser.isSimpleSelector(selector))
    }

    // MARK: - Nested Validation Tests

    func testNestedInvalidRegexThrows() {
        let selector = Exactmac_Type_ElementSelector.with {
            $0.compound = Exactmac_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = [
                    Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                    Exactmac_Type_ElementSelector.with { $0.textRegex = "[invalid" },
                ]
            }
        }

        XCTAssertThrowsError(try parser.parseSelector(selector)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }
}
