import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Tests for ElementLocator selector matching logic.
///
/// These tests verify that ElementLocator.matchesSelector correctly
/// implements selector matching semantics including:
/// - Position selector with Euclidean distance calculation
/// - Compound selectors with AND, OR, NOT operators
/// - Various matching edge cases
final class ElementLocatorMatchingSelectorTests: XCTestCase {
    private var locator: ElementLocator {
        ElementLocator.shared
    }

    // MARK: - Position Selector Tests (Euclidean Distance)

    func testPositionSelectorExactMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = 30
        }
        // Center = (125, 115)
        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 125
                $0.y = 115
                $0.tolerance = 0
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches, "Element center matches position exactly")
    }

    func testPositionSelectorWithinTolerance() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = 30
        }
        // Center = (125, 115)
        // Target = (130, 118), distance = sqrt(25 + 9) = sqrt(34) ≈ 5.83
        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 130
                $0.y = 118
                $0.tolerance = 6
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches, "Element within tolerance should match")
    }

    func testPositionSelectorExceedsTolerance() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = 30
        }
        // Center = (125, 115)
        // Target = (140, 130), distance = sqrt(225 + 225) = sqrt(450) ≈ 21.21
        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 140
                $0.y = 130
                $0.tolerance = 20
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches, "Element outside tolerance should not match")
    }

    func testPositionSelectorBoundaryOfTolerance() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 0
            $0.y = 0
            $0.width = 10
            $0.height = 10
        }
        // Center = (5, 5)
        // Target = (8, 9), distance = sqrt(9 + 16) = sqrt(25) = 5.0 exactly
        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 8
                $0.y = 9
                $0.tolerance = 5
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches, "Element at exact boundary of tolerance should match (≤ comparison)")
    }

    func testPositionSelectorUsesElementCenter() async {
        // This test verifies that position matching uses CENTER, not top-left corner
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 100 // Top-left x
            $0.y = 100 // Top-left y
            $0.width = 100
            $0.height = 100
        }
        // Center = (150, 150), NOT (100, 100)

        // Selector matches center (150, 150), not top-left (100, 100)
        let selectorMatchesCenter = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 150
                $0.y = 150
                $0.tolerance = 1
            }
        }

        // Selector matches top-left (100, 100), not center
        let selectorMatchesTopLeft = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 100
                $0.tolerance = 1
            }
        }

        let matchesCenter = await locator.matchesSelector(element, selector: selectorMatchesCenter)
        let matchesTopLeft = await locator.matchesSelector(element, selector: selectorMatchesTopLeft)

        XCTAssertTrue(matchesCenter, "Position selector should match element CENTER")
        XCTAssertFalse(matchesTopLeft, "Position selector should NOT match element top-left corner")
    }

    func testPositionSelectorElementWithoutDimensions() async {
        // When width/height are missing, position matching should fall back to x,y as the "center"
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.x = 100
            $0.y = 100
            // No width/height set
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 100
                $0.tolerance = 0
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches, "Element without dimensions should use x,y as center fallback")
    }

    func testPositionSelectorElementWithoutPosition() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            // No x/y set
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.position = Macosusesdk_Type_PositionSelector.with {
                $0.x = 100
                $0.y = 100
                $0.tolerance = 100
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches, "Element without position should not match position selector")
    }

    // MARK: - NOT Operator Tests

    func testNOTOperatorInvertsMatch() async {
        let button = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.text = "Submit"
        }
        let staticText = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
            $0.text = "Label"
        }

        // NOT(role=AXButton)
        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.compound = Macosusesdk_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = [
                    Macosusesdk_Type_ElementSelector.with { $0.role = "AXButton" },
                ]
            }
        }

        let buttonMatches = await locator.matchesSelector(button, selector: selector)
        let staticTextMatches = await locator.matchesSelector(staticText, selector: selector)

        XCTAssertFalse(buttonMatches, "NOT(role=AXButton) should not match an AXButton")
        XCTAssertTrue(staticTextMatches, "NOT(role=AXButton) should match an AXStaticText")
    }

    func testNOTOperatorWithCompoundInner() async {
        // NOT(role=AXButton AND text=Submit)
        // This should match elements that are NOT (AXButton AND text=Submit)
        let buttonWithSubmit = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.text = "Submit"
        }
        let buttonWithCancel = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.text = "Cancel"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.compound = Macosusesdk_Type_CompoundSelector.with {
                $0.operator = .not
                $0.selectors = [
                    Macosusesdk_Type_ElementSelector.with {
                        $0.compound = Macosusesdk_Type_CompoundSelector.with {
                            $0.operator = .and
                            $0.selectors = [
                                Macosusesdk_Type_ElementSelector.with { $0.role = "AXButton" },
                                Macosusesdk_Type_ElementSelector.with { $0.text = "Submit" },
                            ]
                        }
                    },
                ]
            }
        }

        let submitMatches = await locator.matchesSelector(buttonWithSubmit, selector: selector)
        let cancelMatches = await locator.matchesSelector(buttonWithCancel, selector: selector)

        XCTAssertFalse(submitMatches, "Button with 'Submit' should NOT match NOT(AXButton AND Submit)")
        XCTAssertTrue(cancelMatches, "Button with 'Cancel' should match NOT(AXButton AND Submit)")
    }

    // MARK: - AND Operator Tests

    func testANDOperatorAllMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.text = "Submit"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.compound = Macosusesdk_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = [
                    Macosusesdk_Type_ElementSelector.with { $0.role = "AXButton" },
                    Macosusesdk_Type_ElementSelector.with { $0.textContains = "Sub" },
                ]
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches)
    }

    func testANDOperatorPartialMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.text = "Cancel"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.compound = Macosusesdk_Type_CompoundSelector.with {
                $0.operator = .and
                $0.selectors = [
                    Macosusesdk_Type_ElementSelector.with { $0.role = "AXButton" },
                    Macosusesdk_Type_ElementSelector.with { $0.textContains = "Sub" },
                ]
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches, "AND requires ALL sub-selectors to match")
    }

    // MARK: - OR Operator Tests

    func testOROperatorAnyMatch() async {
        let button = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
        }
        let link = Macosusesdk_Type_Element.with {
            $0.role = "AXLink"
        }
        let text = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.compound = Macosusesdk_Type_CompoundSelector.with {
                $0.operator = .or
                $0.selectors = [
                    Macosusesdk_Type_ElementSelector.with { $0.role = "AXButton" },
                    Macosusesdk_Type_ElementSelector.with { $0.role = "AXLink" },
                ]
            }
        }

        let buttonMatches = await locator.matchesSelector(button, selector: selector)
        let linkMatches = await locator.matchesSelector(link, selector: selector)
        let textMatches = await locator.matchesSelector(text, selector: selector)

        XCTAssertTrue(buttonMatches)
        XCTAssertTrue(linkMatches)
        XCTAssertFalse(textMatches)
    }

    // MARK: - Role Matching Tests

    func testRoleMatchingCaseInsensitive() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
        }

        let lowercaseSelector = Macosusesdk_Type_ElementSelector.with {
            $0.role = "axbutton"
        }
        let uppercaseSelector = Macosusesdk_Type_ElementSelector.with {
            $0.role = "AXBUTTON"
        }

        let matchesLower = await locator.matchesSelector(element, selector: lowercaseSelector)
        let matchesUpper = await locator.matchesSelector(element, selector: uppercaseSelector)

        XCTAssertTrue(matchesLower, "Role matching should be case-insensitive")
        XCTAssertTrue(matchesUpper, "Role matching should be case-insensitive")
    }

    // MARK: - Text Matching Tests

    func testTextExactMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
            $0.text = "Hello World"
        }

        let exactSelector = Macosusesdk_Type_ElementSelector.with {
            $0.text = "Hello World"
        }
        let partialSelector = Macosusesdk_Type_ElementSelector.with {
            $0.text = "Hello"
        }

        let matchesExact = await locator.matchesSelector(element, selector: exactSelector)
        let matchesPartial = await locator.matchesSelector(element, selector: partialSelector)

        XCTAssertTrue(matchesExact)
        XCTAssertFalse(matchesPartial, "text= requires exact match, not partial")
    }

    func testTextContainsMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
            $0.text = "Hello World"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.textContains = "World"
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches)
    }

    func testTextRegexMatch() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
            $0.text = "Hello-123"
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.textRegex = "Hello-\\d+"
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches)
    }

    func testTextContainsOnElementWithoutText() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            // No text set
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.textContains = "anything"
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches)
    }

    // MARK: - Empty Selector Tests

    func testEmptySelectorMatchesAll() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
        }

        let selector = Macosusesdk_Type_ElementSelector()

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches, "Empty selector should match all elements")
    }

    // MARK: - Attribute Matching Tests

    func testAttributeMatchingAllPresent() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.attributes = [
                "AXIdentifier": "submit-btn",
                "AXDescription": "Submit form",
            ]
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.attributes = Macosusesdk_Type_AttributeSelector.with {
                $0.attributes = ["AXIdentifier": "submit-btn"]
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertTrue(matches)
    }

    func testAttributeMatchingMissing() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.attributes = ["AXDescription": "Submit form"]
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.attributes = Macosusesdk_Type_AttributeSelector.with {
                $0.attributes = ["AXIdentifier": "submit-btn"]
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches)
    }

    func testAttributeMatchingWrongValue() async {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.attributes = ["AXIdentifier": "cancel-btn"]
        }

        let selector = Macosusesdk_Type_ElementSelector.with {
            $0.attributes = Macosusesdk_Type_AttributeSelector.with {
                $0.attributes = ["AXIdentifier": "submit-btn"]
            }
        }

        let matches = await locator.matchesSelector(element, selector: selector)
        XCTAssertFalse(matches)
    }
}
