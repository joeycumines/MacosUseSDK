@testable import ExactMacServer
import XCTest

/// Unit tests for the text-editable role helper used by WriteElementValue.
final class ElementMethodsRoleTests: XCTestCase {
    func testRoleIsTextEditable_editableRoles() {
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXTextField"))
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXTextArea"))
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXComboBox"))
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXSearchField"))
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXSecureTextField"))
    }

    func testRoleIsTextEditable_caseInsensitive() {
        XCTAssertTrue(ExactMacService.roleIsTextEditable("axtextarea"))
        XCTAssertTrue(ExactMacService.roleIsTextEditable("aXTeXtFiElD"))
    }

    func testRoleIsTextEditable_nonEditableRoles() {
        XCTAssertFalse(ExactMacService.roleIsTextEditable("AXStaticText"))
        XCTAssertFalse(ExactMacService.roleIsTextEditable("AXButton"))
        XCTAssertFalse(ExactMacService.roleIsTextEditable("AXImage"))
        XCTAssertFalse(ExactMacService.roleIsTextEditable("AXCheckBox"))
    }

    func testRoleIsTextEditable_prefersCanonicalInput() {
        // roleIsTextEditable operates on canonical roles; callers must strip the
        // accessibility description suffix first. Verifying this precondition guards
        // against accidentally relying on the helper to handle suffix stripping.
        XCTAssertTrue(ExactMacService.roleIsTextEditable("AXTextArea"))
        XCTAssertFalse(ExactMacService.roleIsTextEditable("AXTextArea (text entry area)"))
    }
}
