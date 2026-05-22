import Foundation
import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Tests for the WatchAccessibility diff algorithm.
/// These tests verify:
/// - computeElementChanges correctly detects attribute changes
/// - Identical elements produce empty changes
/// - All tracked attributes are compared correctly
final class ElementDiffTests: XCTestCase {
    var service: MacosUseService!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        // Create a minimal service instance for testing
        let stateStore = AppStateStore()
        let operationStore = OperationStore()
        let windowRegistry = WindowRegistry()
        service = MacosUseService(
            stateStore: stateStore,
            operationStore: operationStore,
            windowRegistry: windowRegistry,
        )
    }

    // MARK: - computeElementChanges Tests

    /// Test that identical elements produce no changes.
    func testIdenticalElementsProduceNoChanges() {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.text = "Click me"
            $0.x = 100
            $0.y = 200
            $0.width = 80
            $0.height = 30
            $0.enabled = true
            $0.focused = false
        }

        let changes = service.computeElementChanges(old: element, new: element)
        XCTAssertTrue(changes.isEmpty, "Identical elements should produce no changes")
    }

    /// Test that role changes are detected.
    func testRoleChangeDetected() {
        let old = Macosusesdk_Type_Element.with { $0.role = "button" }
        let new = Macosusesdk_Type_Element.with { $0.role = "checkbox" }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.attribute, "role")
        XCTAssertEqual(changes.first?.oldValue, "button")
        XCTAssertEqual(changes.first?.newValue, "checkbox")
    }

    /// Test that text changes are detected.
    func testTextChangeDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "staticText"
            $0.text = "Hello"
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "staticText"
            $0.text = "World"
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.attribute, "text")
        XCTAssertEqual(changes.first?.oldValue, "Hello")
        XCTAssertEqual(changes.first?.newValue, "World")
    }

    /// Test that position changes are detected.
    func testPositionChangeDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 100
            $0.y = 200
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 150
            $0.y = 250
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 2, "Both x and y should be detected as changed")

        let xChange = changes.first { $0.attribute == "x" }
        XCTAssertNotNil(xChange)
        XCTAssertEqual(xChange?.oldValue, "100.0")
        XCTAssertEqual(xChange?.newValue, "150.0")

        let yChange = changes.first { $0.attribute == "y" }
        XCTAssertNotNil(yChange)
        XCTAssertEqual(yChange?.oldValue, "200.0")
        XCTAssertEqual(yChange?.newValue, "250.0")
    }

    /// Test that size changes are detected.
    func testSizeChangeDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "window"
            $0.width = 800
            $0.height = 600
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "window"
            $0.width = 1024
            $0.height = 768
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 2)

        let widthChange = changes.first { $0.attribute == "width" }
        XCTAssertNotNil(widthChange)
        XCTAssertEqual(widthChange?.oldValue, "800.0")
        XCTAssertEqual(widthChange?.newValue, "1024.0")

        let heightChange = changes.first { $0.attribute == "height" }
        XCTAssertNotNil(heightChange)
        XCTAssertEqual(heightChange?.oldValue, "600.0")
        XCTAssertEqual(heightChange?.newValue, "768.0")
    }

    /// Test that enabled state changes are detected.
    func testEnabledChangeDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.enabled = true
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.enabled = false
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.attribute, "enabled")
        XCTAssertEqual(changes.first?.oldValue, "true")
        XCTAssertEqual(changes.first?.newValue, "false")
    }

    /// Test that focused state changes are detected.
    func testFocusedChangeDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "textField"
            $0.focused = false
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "textField"
            $0.focused = true
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.attribute, "focused")
        XCTAssertEqual(changes.first?.oldValue, "false")
        XCTAssertEqual(changes.first?.newValue, "true")
    }

    /// Test that multiple changes are detected simultaneously.
    func testMultipleChangesDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.text = "Submit"
            $0.x = 100
            $0.y = 200
            $0.enabled = true
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.text = "Cancel"
            $0.x = 200
            $0.y = 200
            $0.enabled = false
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 3, "text, x, and enabled should all be changed")

        let attrs = Set(changes.map(\.attribute))
        XCTAssertTrue(attrs.contains("text"))
        XCTAssertTrue(attrs.contains("x"))
        XCTAssertTrue(attrs.contains("enabled"))
    }

    /// Test handling of missing optional fields in old element.
    func testMissingOptionalInOld() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            // text, x, y not set
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.text = "New text"
            $0.x = 100
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 2, "text and x should show as changed")

        let textChange = changes.first { $0.attribute == "text" }
        XCTAssertEqual(textChange?.oldValue, "")
        XCTAssertEqual(textChange?.newValue, "New text")
    }

    /// Test handling of missing optional fields in new element.
    func testMissingOptionalInNew() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.text = "Old text"
            $0.x = 100
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            // text, x not set
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 2, "text and x should show as changed")

        let textChange = changes.first { $0.attribute == "text" }
        XCTAssertEqual(textChange?.oldValue, "Old text")
        XCTAssertEqual(textChange?.newValue, "")
    }

    /// Test that element_id changes are NOT tracked (ephemeral).
    func testElementIdNotTracked() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.elementID = "old-id-123"
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.elementID = "new-id-456"
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertTrue(changes.isEmpty, "element_id is ephemeral and should not be tracked")
    }

    /// Test that path changes are NOT tracked (used as key).
    func testPathNotTracked() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.path = [0, 1, 2]
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.path = [0, 1, 3]
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertTrue(changes.isEmpty, "path is used as key, not as diffable attribute")
    }

    // MARK: - elementPathKey Tests

    /// Test that non-empty paths generate proper keys.
    func testElementPathKeyWithNonEmptyPath() {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.path = [0, 1, 2]
        }

        let key = MacosUseService.elementPathKey(element)
        XCTAssertEqual(key, "0/1/2")
    }

    /// Test that empty paths generate fallback keys using role and position.
    func testElementPathKeyWithEmptyPath() {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXApplication"
            $0.path = []
            $0.x = 0
            $0.y = 0
        }

        let key = MacosUseService.elementPathKey(element)
        XCTAssertTrue(key.hasPrefix("root:"), "Empty path should generate root: prefix")
        XCTAssertTrue(key.contains("AXApplication"), "Key should contain role")
        XCTAssertTrue(key.contains("@"), "Key should contain position separator")
    }

    /// Test that two elements with empty paths but different positions get different keys.
    func testElementPathKeyEmptyPathsWithDifferentPositions() {
        let element1 = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = 100
            $0.y = 200
        }
        let element2 = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = 300
            $0.y = 400
        }

        let key1 = MacosUseService.elementPathKey(element1)
        let key2 = MacosUseService.elementPathKey(element2)
        XCTAssertNotEqual(key1, key2, "Different positions should produce different keys")
    }

    /// Test that two elements with empty paths but different roles get different keys.
    func testElementPathKeyEmptyPathsWithDifferentRoles() {
        let element1 = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = 100
            $0.y = 200
        }
        let element2 = Macosusesdk_Type_Element.with {
            $0.role = "AXStaticText"
            $0.path = []
            $0.x = 100
            $0.y = 200
        }

        let key1 = MacosUseService.elementPathKey(element1)
        let key2 = MacosUseService.elementPathKey(element2)
        XCTAssertNotEqual(key1, key2, "Different roles should produce different keys")
    }

    // MARK: - Epsilon Comparison Tests

    /// Test that small floating-point differences (less than 1 pixel) are ignored.
    func testSmallPositionDifferenceIgnored() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 100.0
            $0.y = 200.0
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 100.5 // Less than 1 pixel difference
            $0.y = 200.3 // Less than 1 pixel difference
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertTrue(changes.isEmpty, "Sub-pixel differences should be ignored")
    }

    /// Test that significant position differences are detected.
    func testSignificantPositionDifferenceDetected() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 100.0
            $0.y = 200.0
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 102.0 // More than 1 pixel difference
            $0.y = 200.0
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.attribute, "x")
    }

    /// Test that small size differences are ignored.
    func testSmallSizeDifferenceIgnored() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "window"
            $0.width = 800.0
            $0.height = 600.0
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "window"
            $0.width = 800.4 // Less than 1 pixel
            $0.height = 599.7 // Less than 1 pixel
        }

        let changes = service.computeElementChanges(old: old, new: new)
        XCTAssertTrue(changes.isEmpty, "Sub-pixel size differences should be ignored")
    }

    // MARK: - Additional Edge Case Tests

    /// Test that two elements with empty paths, same position, but different sizes get different keys.
    func testElementPathKeyEmptyPathsWithDifferentSizes() {
        let element1 = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = 100
            $0.y = 200
            $0.width = 80
            $0.height = 30
        }
        let element2 = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = 100
            $0.y = 200
            $0.width = 120
            $0.height = 40
        }

        let key1 = MacosUseService.elementPathKey(element1)
        let key2 = MacosUseService.elementPathKey(element2)
        XCTAssertNotEqual(key1, key2, "Different sizes should produce different keys")
    }

    /// Test that NaN coordinates don't crash and produce safe keys.
    func testElementPathKeyWithNaNCoordinates() {
        let element = Macosusesdk_Type_Element.with {
            $0.role = "AXButton"
            $0.path = []
            $0.x = Double.nan
            $0.y = Double.infinity
            $0.width = -Double.infinity
            $0.height = Double.nan
        }

        // Should not crash and should produce a valid key
        let key = MacosUseService.elementPathKey(element)
        XCTAssertTrue(key.hasPrefix("root:"), "Should produce fallback key")
        XCTAssertTrue(key.contains("AXButton"), "Key should contain role")
        // NaN/Infinity should be converted to 0
        XCTAssertTrue(key.contains("0,0"), "NaN should be converted to 0")
    }

    /// Test that exact 1-pixel boundary is detected as a change.
    func testExactEpsilonBoundary() {
        let old = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 100.0
        }
        let new = Macosusesdk_Type_Element.with {
            $0.role = "button"
            $0.x = 101.0 // Exactly 1 pixel difference (at boundary)
        }

        let changes = service.computeElementChanges(old: old, new: new)
        // With < epsilon (not <=), a diff of exactly 1.0 IS detected as change
        XCTAssertEqual(changes.count, 1, "Exactly 1 pixel difference should be detected")
        XCTAssertEqual(changes.first?.attribute, "x")
    }
}
