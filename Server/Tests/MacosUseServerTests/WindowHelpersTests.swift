@testable import MacosUseServer
import XCTest

/// Unit tests for WindowHelpers extension methods on MacosUseService.
///
/// These tests verify the `getActionsForRole` function which determines
/// available actions for UI elements based on their role.
final class WindowHelpersTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeService() async -> MacosUseService {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        return MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )
    }

    // MARK: - getActionsForRole Tests: Button

    func testGetActionsForRole_button_returnsPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("button")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_Button_caseInsensitive() async {
        let service = await makeService()

        let actions = service.getActionsForRole("Button")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_BUTTON_caseInsensitive() async {
        let service = await makeService()

        let actions = service.getActionsForRole("BUTTON")

        XCTAssertEqual(actions, ["press"])
    }

    // MARK: - getActionsForRole Tests: Checkbox/RadioButton

    func testGetActionsForRole_checkbox_returnsPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("checkbox")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_radiobutton_returnsPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("radiobutton")

        XCTAssertEqual(actions, ["press"])
    }

    // MARK: - getActionsForRole Tests: Slider/Scrollbar

    func testGetActionsForRole_slider_returnsIncrementDecrement() async {
        let service = await makeService()

        let actions = service.getActionsForRole("slider")

        XCTAssertEqual(actions, ["increment", "decrement"])
    }

    func testGetActionsForRole_scrollbar_returnsIncrementDecrement() async {
        let service = await makeService()

        let actions = service.getActionsForRole("scrollbar")

        XCTAssertEqual(actions, ["increment", "decrement"])
    }

    // MARK: - getActionsForRole Tests: Menu Elements

    func testGetActionsForRole_menu_returnsMenuActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("menu")

        XCTAssertEqual(actions, ["press", "open", "close"])
    }

    func testGetActionsForRole_menuitem_returnsMenuActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("menuitem")

        XCTAssertEqual(actions, ["press", "open", "close"])
    }

    // MARK: - getActionsForRole Tests: Tab

    func testGetActionsForRole_tab_returnsTabActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("tab")

        XCTAssertEqual(actions, ["press", "select"])
    }

    // MARK: - getActionsForRole Tests: Combo Elements

    func testGetActionsForRole_combobox_returnsComboActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("combobox")

        XCTAssertEqual(actions, ["press", "open", "close"])
    }

    func testGetActionsForRole_popupbutton_returnsComboActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("popupbutton")

        XCTAssertEqual(actions, ["press", "open", "close"])
    }

    // MARK: - getActionsForRole Tests: Text Elements

    func testGetActionsForRole_text_returnsTextActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("text")

        XCTAssertEqual(actions, ["focus", "select"])
    }

    func testGetActionsForRole_textfield_returnsTextActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("textfield")

        XCTAssertEqual(actions, ["focus", "select"])
    }

    func testGetActionsForRole_textarea_returnsTextActions() async {
        let service = await makeService()

        let actions = service.getActionsForRole("textarea")

        XCTAssertEqual(actions, ["focus", "select"])
    }

    // MARK: - getActionsForRole Tests: Default/Unknown

    func testGetActionsForRole_unknownRole_returnsDefaultPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("unknownrole")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_emptyString_returnsDefaultPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_axPrefixedRole_returnsDefaultPress() async {
        let service = await makeService()
        // AX roles like "AXButton" don't match since we check "button" not "axbutton"

        let actions = service.getActionsForRole("AXButton")

        XCTAssertEqual(actions, ["press"])
    }

    func testGetActionsForRole_specialCharacters_returnsDefaultPress() async {
        let service = await makeService()

        let actions = service.getActionsForRole("button!")

        XCTAssertEqual(actions, ["press"])
    }
}
