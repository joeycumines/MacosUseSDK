import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Unit tests for mapKeyNameToKeyCode function and related key constants.
final class InputControllerTests: XCTestCase {
    // MARK: - Special Keys

    func testReturn_returnsCorrectKeyCode() {
        XCTAssertEqual(mapKeyNameToKeyCode("return"), KEY_RETURN)
        XCTAssertEqual(mapKeyNameToKeyCode("enter"), KEY_RETURN)
    }

    func testTab_returnsCorrectKeyCode() {
        XCTAssertEqual(mapKeyNameToKeyCode("tab"), KEY_TAB)
    }

    func testSpace_returnsCorrectKeyCode() {
        XCTAssertEqual(mapKeyNameToKeyCode("space"), KEY_SPACE)
    }

    func testDelete_returnsCorrectKeyCode() {
        XCTAssertEqual(mapKeyNameToKeyCode("delete"), KEY_DELETE)
        XCTAssertEqual(mapKeyNameToKeyCode("backspace"), KEY_DELETE)
    }

    func testEscape_returnsCorrectKeyCode() {
        XCTAssertEqual(mapKeyNameToKeyCode("escape"), KEY_ESCAPE)
        XCTAssertEqual(mapKeyNameToKeyCode("esc"), KEY_ESCAPE)
    }

    func testArrowKeys_returnCorrectKeyCodes() {
        XCTAssertEqual(mapKeyNameToKeyCode("left"), KEY_ARROW_LEFT)
        XCTAssertEqual(mapKeyNameToKeyCode("right"), KEY_ARROW_RIGHT)
        XCTAssertEqual(mapKeyNameToKeyCode("up"), KEY_ARROW_UP)
        XCTAssertEqual(mapKeyNameToKeyCode("down"), KEY_ARROW_DOWN)
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitivity_uppercaseWorks() {
        XCTAssertEqual(mapKeyNameToKeyCode("RETURN"), KEY_RETURN)
        XCTAssertEqual(mapKeyNameToKeyCode("TAB"), KEY_TAB)
        XCTAssertEqual(mapKeyNameToKeyCode("ESCAPE"), KEY_ESCAPE)
    }

    func testCaseInsensitivity_mixedCaseWorks() {
        XCTAssertEqual(mapKeyNameToKeyCode("Return"), KEY_RETURN)
        XCTAssertEqual(mapKeyNameToKeyCode("Tab"), KEY_TAB)
        XCTAssertEqual(mapKeyNameToKeyCode("EsCaPe"), KEY_ESCAPE)
    }

    // MARK: - Letters

    func testLetters_returnsCorrectKeyCodes() {
        // Sample letters from different keyboard regions
        XCTAssertEqual(mapKeyNameToKeyCode("a"), 0)
        XCTAssertEqual(mapKeyNameToKeyCode("s"), 1)
        XCTAssertEqual(mapKeyNameToKeyCode("d"), 2)
        XCTAssertEqual(mapKeyNameToKeyCode("f"), 3)
        XCTAssertEqual(mapKeyNameToKeyCode("z"), 6)
    }

    func testLetters_allLettersAreMapped() {
        let expectedMappings: [(String, CGKeyCode)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14),
            ("f", 3), ("g", 5), ("h", 4), ("i", 34), ("j", 38),
            ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31),
            ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17),
            ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16),
            ("z", 6),
        ]

        for (letter, expectedCode) in expectedMappings {
            XCTAssertEqual(mapKeyNameToKeyCode(letter), expectedCode, "Letter '\(letter)' mismatch")
        }
    }

    // MARK: - Numbers

    func testNumbers_returnCorrectKeyCodes() {
        let expectedMappings: [(String, CGKeyCode)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ]

        for (number, expectedCode) in expectedMappings {
            XCTAssertEqual(mapKeyNameToKeyCode(number), expectedCode, "Number '\(number)' mismatch")
        }
    }

    // MARK: - Symbols

    func testSymbols_returnCorrectKeyCodes() {
        XCTAssertEqual(mapKeyNameToKeyCode("-"), 27)
        XCTAssertEqual(mapKeyNameToKeyCode("="), 24)
        XCTAssertEqual(mapKeyNameToKeyCode("["), 33)
        XCTAssertEqual(mapKeyNameToKeyCode("]"), 30)
        XCTAssertEqual(mapKeyNameToKeyCode("\\"), 42)
        XCTAssertEqual(mapKeyNameToKeyCode(";"), 41)
        XCTAssertEqual(mapKeyNameToKeyCode("'"), 39)
        XCTAssertEqual(mapKeyNameToKeyCode(","), 43)
        XCTAssertEqual(mapKeyNameToKeyCode("."), 47)
        XCTAssertEqual(mapKeyNameToKeyCode("/"), 44)
        XCTAssertEqual(mapKeyNameToKeyCode("`"), 50)
    }

    // MARK: - Function Keys

    func testFunctionKeys_returnCorrectKeyCodes() {
        XCTAssertEqual(mapKeyNameToKeyCode("f1"), 122)
        XCTAssertEqual(mapKeyNameToKeyCode("f2"), 120)
        XCTAssertEqual(mapKeyNameToKeyCode("f3"), 99)
        XCTAssertEqual(mapKeyNameToKeyCode("f4"), 118)
        XCTAssertEqual(mapKeyNameToKeyCode("f5"), 96)
        XCTAssertEqual(mapKeyNameToKeyCode("f6"), 97)
        XCTAssertEqual(mapKeyNameToKeyCode("f7"), 98)
        XCTAssertEqual(mapKeyNameToKeyCode("f8"), 100)
        XCTAssertEqual(mapKeyNameToKeyCode("f9"), 101)
        XCTAssertEqual(mapKeyNameToKeyCode("f10"), 109)
        XCTAssertEqual(mapKeyNameToKeyCode("f11"), 103)
        XCTAssertEqual(mapKeyNameToKeyCode("f12"), 111)
    }

    func testFunctionKeys_caseInsensitive() {
        XCTAssertEqual(mapKeyNameToKeyCode("F1"), 122)
        XCTAssertEqual(mapKeyNameToKeyCode("F12"), 111)
    }

    // MARK: - Numeric String Fallback

    func testNumericString_parsesAsKeyCode() {
        // When a numeric string is passed that doesn't match a named key,
        // it should attempt to parse as a raw key code
        XCTAssertEqual(mapKeyNameToKeyCode("36"), 36) // Return key code
        XCTAssertEqual(mapKeyNameToKeyCode("53"), 53) // Escape key code
    }

    func testNumericString_largeValues() {
        XCTAssertEqual(mapKeyNameToKeyCode("255"), 255)
    }

    // MARK: - Invalid Inputs

    func testUnrecognizedKeyName_returnsNil() {
        XCTAssertNil(mapKeyNameToKeyCode("unknownkey"))
        XCTAssertNil(mapKeyNameToKeyCode("ctrl")) // Not a mapped key
        XCTAssertNil(mapKeyNameToKeyCode("alt")) // Not a mapped key
        XCTAssertNil(mapKeyNameToKeyCode("cmd")) // Not a mapped key
    }

    func testEmptyString_returnsNil() {
        XCTAssertNil(mapKeyNameToKeyCode(""))
    }

    func testWhitespaceOnly_returnsNil() {
        XCTAssertNil(mapKeyNameToKeyCode(" "))
        XCTAssertNil(mapKeyNameToKeyCode("  "))
    }

    func testNonNumericNonKey_returnsNil() {
        XCTAssertNil(mapKeyNameToKeyCode("hello"))
        XCTAssertNil(mapKeyNameToKeyCode("abc123"))
    }

    // MARK: - Key Constants Verification

    func testKeyConstants_haveExpectedValues() {
        // Verify the public constants match expected macOS key codes
        XCTAssertEqual(KEY_RETURN, 36)
        XCTAssertEqual(KEY_TAB, 48)
        XCTAssertEqual(KEY_SPACE, 49)
        XCTAssertEqual(KEY_DELETE, 51)
        XCTAssertEqual(KEY_ESCAPE, 53)
        XCTAssertEqual(KEY_ARROW_LEFT, 123)
        XCTAssertEqual(KEY_ARROW_RIGHT, 124)
        XCTAssertEqual(KEY_ARROW_DOWN, 125)
        XCTAssertEqual(KEY_ARROW_UP, 126)
    }
}
