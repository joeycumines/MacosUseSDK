@testable import MacosUseServer
import XCTest

/// Unit tests for the text-editable role helper used by WriteElementValue.
final class ElementMethodsRoleTests: XCTestCase {
    func testRoleIsTextEditable_editableRoles() {
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXTextField"))
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXTextArea"))
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXComboBox"))
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXSearchField"))
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXSecureTextField"))
    }

    func testRoleIsTextEditable_caseInsensitive() {
        XCTAssertTrue(MacosUseService.roleIsTextEditable("axtextarea"))
        XCTAssertTrue(MacosUseService.roleIsTextEditable("aXTeXtFiElD"))
    }

    func testRoleIsTextEditable_nonEditableRoles() {
        XCTAssertFalse(MacosUseService.roleIsTextEditable("AXStaticText"))
        XCTAssertFalse(MacosUseService.roleIsTextEditable("AXButton"))
        XCTAssertFalse(MacosUseService.roleIsTextEditable("AXImage"))
        XCTAssertFalse(MacosUseService.roleIsTextEditable("AXCheckBox"))
    }

    func testRoleIsTextEditable_prefersCanonicalInput() {
        // roleIsTextEditable operates on canonical roles; callers must strip the
        // accessibility description suffix first. Verifying this precondition guards
        // against accidentally relying on the helper to handle suffix stripping.
        XCTAssertTrue(MacosUseService.roleIsTextEditable("AXTextArea"))
        XCTAssertFalse(MacosUseService.roleIsTextEditable("AXTextArea (text entry area)"))
    }
}
