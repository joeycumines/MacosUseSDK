@testable import MacosUseSDK
import XCTest

/// Comprehensive tests for `CombinedActions.calculateDiff`, `areDoublesEqual`,
/// and `AttributeChangeDetail` text diffing logic.
///
/// These tests exercise the pure, synchronous diff machinery without touching
/// any Accessibility or MainActor APIs.
final class TraversalDiffTests: XCTestCase {
    // MARK: - Test Helpers

    /// Factory identical to the one in `ElementDataEqualityTests` — kept local
    /// so this file is self-contained and import-order–independent.
    private func makeElement(
        role: String = "AXButton",
        text: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        attributes: [String: String] = [:],
        path: [Int32] = [],
    ) -> ElementData {
        ElementData(
            role: role,
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            axElement: nil,
            enabled: enabled,
            focused: focused,
            attributes: attributes,
            path: path,
        )
    }

    // MARK: - calculateDiff: Empty Inputs

    func testCalculateDiff_emptyBeforeAndAfter_noDiffs() {
        let diff = CombinedActions.calculateDiff(
            beforeElements: [],
            afterElements: [],
        )

        XCTAssertTrue(diff.added.isEmpty, "No elements should be added")
        XCTAssertTrue(diff.removed.isEmpty, "No elements should be removed")
        XCTAssertTrue(diff.modified.isEmpty, "No elements should be modified")
    }

    // MARK: - calculateDiff: Added Elements

    func testCalculateDiff_allElementsAdded() {
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
            makeElement(role: "AXTextField", text: "Name", x: 50, y: 60),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: [],
            afterElements: after,
        )

        XCTAssertEqual(diff.added.count, 2)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    func testCalculateDiff_singleElementAdded() {
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
            makeElement(role: "AXTextField", text: "Name", x: 50, y: 60),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.added.first?.role, "AXTextField")
        XCTAssertTrue(diff.removed.isEmpty)
    }

    // MARK: - calculateDiff: Removed Elements

    func testCalculateDiff_allElementsRemoved() {
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
            makeElement(role: "AXTextField", text: "Name", x: 50, y: 60),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: [],
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.count, 2)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    func testCalculateDiff_singleElementRemoved() {
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
            makeElement(role: "AXTextField", text: "Name", x: 50, y: 60),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.removed.first?.role, "AXTextField")
    }

    // MARK: - calculateDiff: Modified Elements — Text Change

    func testCalculateDiff_modifiedText_detectedAsModified() {
        let before = [
            makeElement(role: "AXStaticText", text: "Hello", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXStaticText", text: "Hello World", x: 100, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 1)

        let mod = diff.modified[0]
        XCTAssertEqual(mod.before.text, "Hello")
        XCTAssertEqual(mod.after.text, "Hello World")

        // Should contain a "text" change detail
        let textChange = mod.changes.first { $0.attributeName == "text" }
        XCTAssertNotNil(textChange, "Should have a text attribute change")
        XCTAssertEqual(textChange?.addedText, " World")
        XCTAssertNil(textChange?.removedText)
    }

    func testCalculateDiff_modifiedText_textRemoved() {
        let before = [
            makeElement(role: "AXStaticText", text: "Hello World", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXStaticText", text: "Hello", x: 100, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.modified.count, 1)
        let textChange = diff.modified[0].changes.first { $0.attributeName == "text" }
        XCTAssertNotNil(textChange)
        XCTAssertNil(textChange?.addedText)
        XCTAssertEqual(textChange?.removedText, " World")
    }

    // MARK: - calculateDiff: Modified Elements — Position Change (within tolerance)

    func testCalculateDiff_positionChange_withinTolerance_detectedAsModified() {
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100.0, y: 200.0),
        ]
        let after = [
            // Moved by 3.0 in x — within default positionTolerance (5.0) but exceeds
            // areDoublesEqual default tolerance (1.0), so it's matched AND detected as modified.
            makeElement(role: "AXButton", text: "OK", x: 103.0, y: 200.0),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 1)

        let xChange = diff.modified[0].changes.first { $0.attributeName == "x" }
        XCTAssertNotNil(xChange, "Should detect x position change")
    }

    // MARK: - calculateDiff: Modified Elements — Size Change

    func testCalculateDiff_sizeChange_detectedAsModified() {
        let before = [
            makeElement(role: "AXWindow", text: "Main", x: 0, y: 0, width: 800, height: 600),
        ]
        let after = [
            makeElement(role: "AXWindow", text: "Main", x: 0, y: 0, width: 1024, height: 768),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 1)

        let changes = diff.modified[0].changes
        let widthChange = changes.first { $0.attributeName == "width" }
        let heightChange = changes.first { $0.attributeName == "height" }
        XCTAssertNotNil(widthChange, "Should detect width change")
        XCTAssertNotNil(heightChange, "Should detect height change")
    }

    // MARK: - calculateDiff: Unchanged Elements

    func testCalculateDiff_unchangedElements_notInAnyCategory() {
        let elements = [
            makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30),
            makeElement(role: "AXTextField", text: "Name", x: 50, y: 60, width: 200, height: 25),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: elements,
            afterElements: elements,
        )

        XCTAssertTrue(diff.added.isEmpty, "Unchanged elements should not appear as added")
        XCTAssertTrue(diff.removed.isEmpty, "Unchanged elements should not appear as removed")
        XCTAssertTrue(diff.modified.isEmpty, "Unchanged elements should not appear as modified")
    }

    func testCalculateDiff_subpixelJitter_withinTolerance_notModified() {
        // areDoublesEqual has default tolerance of 1.0,
        // so a change < 1.0 should not register as modified.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100.0, y: 200.0),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 100.5, y: 200.3),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.modified.isEmpty,
                      "Sub-pixel jitter within areDoublesEqual tolerance should not cause a modification")
    }

    // MARK: - calculateDiff: Different Roles → Not Matched

    func testCalculateDiff_differentRoles_treatedAsRemoveAndAdd() {
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXStaticText", text: "OK", x: 100, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.removed.count, 1, "Old element should be removed")
        XCTAssertEqual(diff.added.count, 1, "New element should be added")
        XCTAssertTrue(diff.modified.isEmpty, "Different roles cannot be matched")
        XCTAssertEqual(diff.removed.first?.role, "AXButton")
        XCTAssertEqual(diff.added.first?.role, "AXStaticText")
    }

    // MARK: - calculateDiff: Position Tolerance Boundary

    func testCalculateDiff_exactlyAtPositionTolerance_stillMatched() {
        // positionTolerance = 5.0; element moved exactly 5.0 in x.
        // distanceSq = 25.0, tolerance² = 25.0; condition is `<=` so this matches.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 105, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        XCTAssertTrue(diff.added.isEmpty, "Should match at exact tolerance boundary")
        XCTAssertTrue(diff.removed.isEmpty, "Should match at exact tolerance boundary")
        // The x position change exceeds areDoublesEqual tolerance (1.0) so it's a modification.
        XCTAssertEqual(diff.modified.count, 1)
    }

    func testCalculateDiff_diagonalExactlyAtTolerance_matched() {
        // positionTolerance = 5.0; dx = 3.0, dy = 4.0 → distance = 5.0 (Pythagorean triple).
        // distanceSq = 25.0 == tolerance² = 25.0, so `<=` matches.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 103, y: 204),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 1, "Should match and detect modification at exact diagonal tolerance")
    }

    // MARK: - calculateDiff: Position Tolerance Exceeded

    func testCalculateDiff_positionToleranceExceeded_treatedAsRemoveAdd() {
        // positionTolerance = 5.0; element moved 6.0 in x → exceeds tolerance.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 106, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        XCTAssertEqual(diff.removed.count, 1, "Should be removed when beyond tolerance")
        XCTAssertEqual(diff.added.count, 1, "Should be added when beyond tolerance")
        XCTAssertTrue(diff.modified.isEmpty, "Should not match elements beyond tolerance")
    }

    func testCalculateDiff_customTightTolerance_exceedsEasily() {
        // With positionTolerance = 1.0, a 2-point move exceeds tolerance.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 102, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 1.0,
        )

        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    // MARK: - calculateDiff: Nil Coordinates Matching

    func testCalculateDiff_bothLackCoords_matchedByRoleAndText() {
        let before = [
            makeElement(role: "AXStaticText", text: "Label"),
        ]
        let after = [
            makeElement(role: "AXStaticText", text: "Label"),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.modified.isEmpty, "Identical nil-coord elements should match with no changes")
    }

    func testCalculateDiff_bothLackCoords_textDiffers_notMatched() {
        // When both lack coords, matching requires role AND text to be equal.
        let before = [
            makeElement(role: "AXStaticText", text: "Old Label"),
        ]
        let after = [
            makeElement(role: "AXStaticText", text: "New Label"),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.removed.count, 1, "Old element should be removed")
        XCTAssertEqual(diff.added.count, 1, "New element should be added")
        XCTAssertTrue(diff.modified.isEmpty, "Without coords, different text means no match")
    }

    func testCalculateDiff_bothLackCoords_nilText_matchedByRole() {
        // Both text are nil, both coords are nil. The nil-nil coord branch
        // checks `if let bt = beforeElement.text, let at = afterElement.text` which
        // will fail when text is nil, so they won't match.
        let before = [
            makeElement(role: "AXGroup"),
        ]
        let after = [
            makeElement(role: "AXGroup"),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        // The nil-coord path requires both texts to be non-nil and equal,
        // so nil text elements without coords won't match.
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
    }

    // MARK: - calculateDiff: Mixed Nil / Non-Nil Coordinates

    func testCalculateDiff_mixedNilNonNilCoords_notMatched() {
        // before has coords, after does not — should not match.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK"),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    func testCalculateDiff_mixedNilNonNilCoords_reversed_notMatched() {
        // before has no coords, after does.
        let before = [
            makeElement(role: "AXButton", text: "OK"),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 100, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    // MARK: - calculateDiff: Multiple Elements with Same Role — Closest Match Wins

    func testCalculateDiff_multipleWithSameRole_closestPositionMatchWins() {
        let before = [
            makeElement(role: "AXButton", text: "A", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "B", x: 200, y: 200), // far
            makeElement(role: "AXButton", text: "C", x: 101, y: 200), // closest
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        // The before element should match the closest after element (x=101).
        XCTAssertEqual(diff.modified.count, 1, "Should match closest element")
        XCTAssertEqual(diff.modified.first?.after.text, "C", "Should pick closest position match")
        XCTAssertEqual(diff.added.count, 1, "Unmatched after element should be added")
        XCTAssertEqual(diff.added.first?.text, "B")
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testCalculateDiff_twoBeforeTwoAfter_greedyMatching() {
        // Two before buttons, two after buttons at nearby positions.
        let before = [
            makeElement(role: "AXButton", text: "A", x: 100, y: 200),
            makeElement(role: "AXButton", text: "B", x: 200, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "A2", x: 101, y: 200),
            makeElement(role: "AXButton", text: "B2", x: 201, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 2, "Both elements should match and show text changes")
    }

    // MARK: - calculateDiff: Complex Mixed Scenario

    func testCalculateDiff_mixedAddRemoveModify() {
        let before = [
            makeElement(role: "AXButton", text: "Stay", x: 10, y: 10),
            makeElement(role: "AXButton", text: "ModifyMe", x: 50, y: 50),
            makeElement(role: "AXButton", text: "RemoveMe", x: 100, y: 100),
        ]
        let after = [
            makeElement(role: "AXButton", text: "Stay", x: 10, y: 10),
            makeElement(role: "AXButton", text: "Modified!", x: 50, y: 50),
            makeElement(role: "AXTextField", text: "NewField", x: 200, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        XCTAssertEqual(diff.added.count, 1, "One new element should be added")
        XCTAssertEqual(diff.added.first?.text, "NewField")

        XCTAssertEqual(diff.removed.count, 1, "One element should be removed")
        XCTAssertEqual(diff.removed.first?.text, "RemoveMe")

        XCTAssertEqual(diff.modified.count, 1, "One element should be modified")
        XCTAssertEqual(diff.modified.first?.before.text, "ModifyMe")
        XCTAssertEqual(diff.modified.first?.after.text, "Modified!")
    }

    // MARK: - calculateDiff: Partial Coordinate Nil

    func testCalculateDiff_beforeHasXOnly_afterHasXOnly_noYMatch() {
        // If only x is provided (y is nil), the positional matching branch
        // requires both x AND y to be non-nil, so this won't match by position.
        let before = [
            makeElement(role: "AXButton", text: "OK", x: 100),
        ]
        let after = [
            makeElement(role: "AXButton", text: "OK", x: 100),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        // The positional branch needs both x and y non-nil.
        // The nil-nil coord branch needs BOTH x and y to be nil.
        // With x=100, y=nil: neither branch fires → no match.
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
    }

    // MARK: - calculateDiff: Multiple Changes Detected

    func testCalculateDiff_multipleAttributeChanges_allReported() {
        let before = [
            makeElement(role: "AXWindow", text: "Old Title", x: 0, y: 0, width: 800, height: 600),
        ]
        let after = [
            makeElement(role: "AXWindow", text: "New Title", x: 0, y: 0, width: 1024, height: 768),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertEqual(diff.modified.count, 1)
        let changes = diff.modified[0].changes
        let changedAttrs = Set(changes.map(\.attributeName))
        XCTAssertTrue(changedAttrs.contains("text"), "Should detect text change")
        XCTAssertTrue(changedAttrs.contains("width"), "Should detect width change")
        XCTAssertTrue(changedAttrs.contains("height"), "Should detect height change")
        // x and y didn't change, so they should not be in the list
        XCTAssertFalse(changedAttrs.contains("x"), "x did not change")
        XCTAssertFalse(changedAttrs.contains("y"), "y did not change")
    }

    // MARK: - calculateDiff: Zero Position Tolerance

    func testCalculateDiff_zeroTolerance_onlyExactPositionMatches() {
        let before = [
            makeElement(role: "AXButton", text: "A", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "A", x: 100.001, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 0.0,
        )

        // distanceSq ≈ 0.000001, tolerance² = 0.0; condition is `<=`,
        // so only distanceSq == 0.0 actually matches.
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    func testCalculateDiff_zeroTolerance_exactMatchStillWorks() {
        let before = [
            makeElement(role: "AXButton", text: "A", x: 100, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "B", x: 100, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 0.0,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.modified.count, 1)
        XCTAssertEqual(diff.modified.first?.after.text, "B")
    }

    // MARK: - calculateDiff: Sorting of Results

    func testCalculateDiff_addedElements_sortedByPosition() {
        let after = [
            makeElement(role: "AXButton", text: "Bottom", x: 10, y: 300),
            makeElement(role: "AXButton", text: "Top", x: 10, y: 100),
            makeElement(role: "AXButton", text: "Middle", x: 10, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: [],
            afterElements: after,
        )

        XCTAssertEqual(diff.added.count, 3)
        // Should be sorted by y, then x
        XCTAssertEqual(diff.added[0].text, "Top")
        XCTAssertEqual(diff.added[1].text, "Middle")
        XCTAssertEqual(diff.added[2].text, "Bottom")
    }

    func testCalculateDiff_removedElements_sortedByPosition() {
        let before = [
            makeElement(role: "AXButton", text: "Bottom", x: 10, y: 300),
            makeElement(role: "AXButton", text: "Top", x: 10, y: 100),
            makeElement(role: "AXButton", text: "Middle", x: 10, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: [],
        )

        XCTAssertEqual(diff.removed.count, 3)
        XCTAssertEqual(diff.removed[0].text, "Top")
        XCTAssertEqual(diff.removed[1].text, "Middle")
        XCTAssertEqual(diff.removed[2].text, "Bottom")
    }

    // MARK: - ═══════════════════════════════════════════════════

    // MARK: - areDoublesEqual Tests

    // MARK: - ═══════════════════════════════════════════════════

    func testAreDoublesEqual_bothNil_returnsTrue() {
        XCTAssertTrue(areDoublesEqual(nil, nil))
    }

    func testAreDoublesEqual_bothEqual_returnsTrue() {
        XCTAssertTrue(areDoublesEqual(42.0, 42.0))
    }

    func testAreDoublesEqual_withinDefaultTolerance_returnsTrue() {
        // Default tolerance is 1.0; abs(100.0 - 100.5) = 0.5 < 1.0
        XCTAssertTrue(areDoublesEqual(100.0, 100.5))
    }

    func testAreDoublesEqual_outsideDefaultTolerance_returnsFalse() {
        // abs(100.0 - 102.0) = 2.0, which is NOT < 1.0
        XCTAssertFalse(areDoublesEqual(100.0, 102.0))
    }

    func testAreDoublesEqual_oneNil_returnsFalse() {
        XCTAssertFalse(areDoublesEqual(nil, 5.0))
        XCTAssertFalse(areDoublesEqual(5.0, nil))
    }

    func testAreDoublesEqual_exactlyAtDefaultTolerance_returnsFalse() {
        // abs(100.0 - 101.0) = 1.0; comparison is strict `<` so 1.0 < 1.0 is false.
        XCTAssertFalse(areDoublesEqual(100.0, 101.0))
    }

    func testAreDoublesEqual_justBelowDefaultTolerance_returnsTrue() {
        // abs(100.0 - 100.999) = 0.999 < 1.0
        XCTAssertTrue(areDoublesEqual(100.0, 100.999))
    }

    func testAreDoublesEqual_negativeValues_withinTolerance() {
        // abs(-50.0 - (-50.5)) = 0.5 < 1.0
        XCTAssertTrue(areDoublesEqual(-50.0, -50.5))
    }

    func testAreDoublesEqual_customTolerance_withinTolerance() {
        // Custom tolerance 0.01; abs(1.0 - 1.005) = 0.005 < 0.01
        XCTAssertTrue(areDoublesEqual(1.0, 1.005, tolerance: 0.01))
    }

    func testAreDoublesEqual_customTolerance_outsideTolerance() {
        // Custom tolerance 0.01; abs(1.0 - 1.02) = 0.02, NOT < 0.01
        XCTAssertFalse(areDoublesEqual(1.0, 1.02, tolerance: 0.01))
    }

    func testAreDoublesEqual_customTolerance_exactBoundary() {
        // Custom tolerance 0.5; abs(10.0 - 10.5) = 0.5; strict `<` so false.
        XCTAssertFalse(areDoublesEqual(10.0, 10.5, tolerance: 0.5))
    }

    func testAreDoublesEqual_zeroTolerance_exactMatch() {
        XCTAssertTrue(areDoublesEqual(7.0, 7.0, tolerance: 0.0))
    }

    func testAreDoublesEqual_zeroTolerance_anyDifference_returnsFalse() {
        XCTAssertFalse(areDoublesEqual(7.0, 7.0000001, tolerance: 0.0))
    }

    func testAreDoublesEqual_symmetry() {
        // areDoublesEqual(a, b) == areDoublesEqual(b, a) for all cases
        XCTAssertEqual(
            areDoublesEqual(100.0, 100.5),
            areDoublesEqual(100.5, 100.0),
        )
        XCTAssertEqual(
            areDoublesEqual(nil, 5.0),
            areDoublesEqual(5.0, nil),
        )
    }

    // MARK: - ═══════════════════════════════════════════════════

    // MARK: - AttributeChangeDetail Text Diffing Tests

    // MARK: - ═══════════════════════════════════════════════════

    func testAttributeChangeDetail_textAppended() {
        let detail = AttributeChangeDetail(textBefore: "Hello", textAfter: "Hello World")

        XCTAssertEqual(detail.attributeName, "text")
        XCTAssertEqual(detail.addedText, " World")
        XCTAssertNil(detail.removedText)
        // oldValue/newValue are nil for text changes per implementation
        XCTAssertNil(detail.oldValue)
        XCTAssertNil(detail.newValue)
    }

    func testAttributeChangeDetail_textPrepended() {
        let detail = AttributeChangeDetail(textBefore: "World", textAfter: "Hello World")

        XCTAssertEqual(detail.addedText, "Hello ")
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_textRemoved() {
        let detail = AttributeChangeDetail(textBefore: "Hello World", textAfter: "Hello")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, " World")
    }

    func testAttributeChangeDetail_textReplaced() {
        let detail = AttributeChangeDetail(textBefore: "cat", textAfter: "car")

        // 't' removed, 'r' added via CollectionDifference
        XCTAssertNotNil(detail.addedText, "Should detect added characters")
        XCTAssertNotNil(detail.removedText, "Should detect removed characters")
    }

    func testAttributeChangeDetail_bothNil_noDiff() {
        let detail = AttributeChangeDetail(textBefore: nil, textAfter: nil)

        XCTAssertEqual(detail.attributeName, "text")
        XCTAssertNil(detail.addedText, "No text added when both nil")
        XCTAssertNil(detail.removedText, "No text removed when both nil")
    }

    func testAttributeChangeDetail_nilToText() {
        let detail = AttributeChangeDetail(textBefore: nil, textAfter: "Hello")

        XCTAssertEqual(detail.addedText, "Hello")
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_textToNil() {
        let detail = AttributeChangeDetail(textBefore: "Hello", textAfter: nil)

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "Hello")
    }

    func testAttributeChangeDetail_emptyToNonEmpty() {
        let detail = AttributeChangeDetail(textBefore: "", textAfter: "Hello")

        XCTAssertEqual(detail.addedText, "Hello")
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_nonEmptyToEmpty() {
        let detail = AttributeChangeDetail(textBefore: "Hello", textAfter: "")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "Hello")
    }

    func testAttributeChangeDetail_identicalText_noDiff() {
        let detail = AttributeChangeDetail(textBefore: "Same", textAfter: "Same")

        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_singleCharInserted() {
        let detail = AttributeChangeDetail(textBefore: "Hllo", textAfter: "Hello")

        XCTAssertEqual(detail.addedText, "e")
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_singleCharDeleted() {
        let detail = AttributeChangeDetail(textBefore: "Hello", textAfter: "Hllo")

        XCTAssertNil(detail.addedText)
        XCTAssertEqual(detail.removedText, "e")
    }

    func testAttributeChangeDetail_unicodeText() {
        let detail = AttributeChangeDetail(textBefore: "日本", textAfter: "日本語")

        XCTAssertEqual(detail.addedText, "語")
        XCTAssertNil(detail.removedText)
    }

    // MARK: - AttributeChangeDetail: Non-Text Attributes

    func testAttributeChangeDetail_nonTextGeneric() {
        let detail = AttributeChangeDetail(attribute: "enabled", before: true, after: false)

        XCTAssertEqual(detail.attributeName, "enabled")
        XCTAssertEqual(detail.oldValue, "true")
        XCTAssertEqual(detail.newValue, "false")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_doubleAttribute() {
        let detail = AttributeChangeDetail(attribute: "x", before: 100.0, after: 105.5)

        XCTAssertEqual(detail.attributeName, "x")
        XCTAssertEqual(detail.oldValue, "100.0")
        XCTAssertEqual(detail.newValue, "105.5")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testAttributeChangeDetail_doubleAttribute_nilBefore() {
        let detail = AttributeChangeDetail(attribute: "width", before: nil as Double?, after: 200.0)

        XCTAssertEqual(detail.attributeName, "width")
        XCTAssertNil(detail.oldValue)
        XCTAssertEqual(detail.newValue, "200.0")
    }

    func testAttributeChangeDetail_doubleAttribute_nilAfter() {
        let detail = AttributeChangeDetail(attribute: "height", before: 600.0, after: nil as Double?)

        XCTAssertEqual(detail.attributeName, "height")
        XCTAssertEqual(detail.oldValue, "600.0")
        XCTAssertNil(detail.newValue)
    }

    // MARK: - ModifiedElement and TraversalDiff Structure

    func testModifiedElement_containsBeforeAfterAndChanges() {
        let before = makeElement(role: "AXButton", text: "Old", x: 10, y: 20)
        let after = makeElement(role: "AXButton", text: "New", x: 10, y: 20)

        let diff = CombinedActions.calculateDiff(
            beforeElements: [before],
            afterElements: [after],
        )

        XCTAssertEqual(diff.modified.count, 1)
        let mod = diff.modified[0]
        XCTAssertEqual(mod.before.text, "Old")
        XCTAssertEqual(mod.after.text, "New")
        XCTAssertFalse(mod.changes.isEmpty, "Should have at least one change detail")
    }

    func testTraversalDiff_isCodable() throws {
        let before = [makeElement(role: "AXButton", text: "A", x: 10, y: 20)]
        let after = [makeElement(role: "AXButton", text: "B", x: 10, y: 20)]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        // Verify it round-trips through JSON encoding/decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(diff)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TraversalDiff.self, from: data)

        XCTAssertEqual(decoded.added.count, diff.added.count)
        XCTAssertEqual(decoded.removed.count, diff.removed.count)
        XCTAssertEqual(decoded.modified.count, diff.modified.count)
        XCTAssertEqual(decoded.modified.first?.changes.first?.attributeName, "text")
    }

    // MARK: - calculateDiff: Large Element Count

    func testCalculateDiff_manyElements_performance() {
        // Verify the algorithm handles a reasonable number of elements without issues.
        // N² matching with 200 elements = 40,000 comparisons — should be fine.
        let count = 200
        var before: [ElementData] = []
        var after: [ElementData] = []
        for i in 0 ..< count {
            before.append(makeElement(
                role: "AXButton",
                text: "Button \(i)",
                x: Double(i * 10),
                y: Double(i * 10),
            ))
            // Shift one element to trigger a modification
            let xOffset: Double = (i == count / 2) ? 2.0 : 0.0
            after.append(makeElement(
                role: "AXButton",
                text: (i == count / 2) ? "Changed" : "Button \(i)",
                x: Double(i * 10) + xOffset,
                y: Double(i * 10),
            ))
        }

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
        )

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        // At minimum the middle element was modified (text changed).
        XCTAssertGreaterThanOrEqual(diff.modified.count, 1)
    }

    // MARK: - calculateDiff: Already-Matched Element Not Reused

    func testCalculateDiff_alreadyMatchedElement_notReusedForSecondBefore() {
        // Two before elements at same role, one after element.
        // Only one can match; the other should be "removed".
        let before = [
            makeElement(role: "AXButton", text: "A", x: 100, y: 200),
            makeElement(role: "AXButton", text: "B", x: 101, y: 200),
        ]
        let after = [
            makeElement(role: "AXButton", text: "C", x: 100.5, y: 200),
        ]

        let diff = CombinedActions.calculateDiff(
            beforeElements: before,
            afterElements: after,
            positionTolerance: 5.0,
        )

        // One before matches the after element; the other is removed.
        XCTAssertEqual(diff.modified.count, 1, "One before element should match")
        XCTAssertEqual(diff.removed.count, 1, "Other before element should be removed")
        XCTAssertTrue(diff.added.isEmpty)
    }
}
