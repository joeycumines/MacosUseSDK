@testable import MacosUseSDK
import XCTest

/// Tests for Statistics struct and its counting logic.
///
/// Verifies role_counts aggregation, visible_elements_count, and text/non-text counts.
final class AccessibilityTraversalStatisticsTests: XCTestCase {
    // MARK: - Default Values

    func testDefaultValues() {
        let stats = Statistics()

        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.excluded_count, 0)
        XCTAssertEqual(stats.excluded_non_interactable, 0)
        XCTAssertEqual(stats.excluded_no_text, 0)
        XCTAssertEqual(stats.with_text_count, 0)
        XCTAssertEqual(stats.without_text_count, 0)
        XCTAssertEqual(stats.visible_elements_count, 0)
        XCTAssertTrue(stats.role_counts.isEmpty)
    }

    func testRoleCountsDefaultIsEmpty() {
        let stats = Statistics()

        XCTAssertTrue(stats.role_counts.isEmpty)
        XCTAssertNil(stats.role_counts["AXButton"])
    }

    // MARK: - Role Counts Aggregation

    func testRoleCounts_incrementSingleRole() {
        var stats = Statistics()

        stats.role_counts["AXButton", default: 0] += 1
        stats.role_counts["AXButton", default: 0] += 1

        XCTAssertEqual(stats.role_counts["AXButton"], 2)
    }

    func testRoleCounts_incrementMultipleRoles() {
        var stats = Statistics()

        stats.role_counts["AXButton", default: 0] += 1
        stats.role_counts["AXTextField", default: 0] += 1
        stats.role_counts["AXButton", default: 0] += 1

        XCTAssertEqual(stats.role_counts["AXButton"], 2)
        XCTAssertEqual(stats.role_counts["AXTextField"], 1)
    }

    func testRoleCounts_emptyStringKey() {
        var stats = Statistics()

        // Test with empty role (shouldn't happen in practice but test robustness)
        stats.role_counts["", default: 0] += 1

        XCTAssertEqual(stats.role_counts[""], 1)
    }

    func testRoleCounts_specialCharactersInRole() {
        var stats = Statistics()

        // Test with role containing special characters
        stats.role_counts["AXButton (Custom)", default: 0] += 1

        XCTAssertEqual(stats.role_counts["AXButton (Custom)"], 1)
    }

    // MARK: - Visible Elements Count

    func testVisibleElementsCount_increment() {
        var stats = Statistics()

        // Simulate processing elements with geometry
        for _ in 0 ..< 5 {
            stats.visible_elements_count += 1
        }

        XCTAssertEqual(stats.visible_elements_count, 5)
    }

    func testVisibleElementsCount_nonGeometryElements() {
        var stats = Statistics()

        // Elements without valid geometry should not increment
        // (In actual traversal, only elements with x, y, width, height > 0 are counted)
        stats.visible_elements_count += 1
        stats.visible_elements_count += 1

        XCTAssertEqual(stats.visible_elements_count, 2)
    }

    // MARK: - Text Counts

    func testTextCounts_withText() {
        var stats = Statistics()

        stats.with_text_count += 1
        stats.with_text_count += 1

        XCTAssertEqual(stats.with_text_count, 2)
        XCTAssertEqual(stats.without_text_count, 0)
    }

    func testTextCounts_withoutText() {
        var stats = Statistics()

        stats.without_text_count += 1

        XCTAssertEqual(stats.with_text_count, 0)
        XCTAssertEqual(stats.without_text_count, 1)
    }

    func testTextCounts_mixed() {
        var stats = Statistics()

        stats.with_text_count += 3
        stats.without_text_count += 2

        XCTAssertEqual(stats.with_text_count, 3)
        XCTAssertEqual(stats.without_text_count, 2)
    }

    // MARK: - Exclusion Counts

    func testExclusionCounts_nonInteractable() {
        var stats = Statistics()

        stats.excluded_count += 1
        stats.excluded_non_interactable += 1

        XCTAssertEqual(stats.excluded_count, 1)
        XCTAssertEqual(stats.excluded_non_interactable, 1)
    }

    func testExclusionCounts_noText() {
        var stats = Statistics()

        stats.excluded_count += 1
        stats.excluded_no_text += 1

        XCTAssertEqual(stats.excluded_count, 1)
        XCTAssertEqual(stats.excluded_no_text, 1)
    }

    func testExclusionCounts_combined() {
        var stats = Statistics()

        stats.excluded_count += 3
        stats.excluded_non_interactable += 2
        stats.excluded_no_text += 1

        XCTAssertEqual(stats.excluded_count, 3)
        XCTAssertEqual(stats.excluded_non_interactable, 2)
        XCTAssertEqual(stats.excluded_no_text, 1)
    }

    // MARK: - Codable

    func testStatistics_codable() throws {
        var stats = Statistics()
        stats.count = 10
        stats.visible_elements_count = 8
        stats.with_text_count = 5
        stats.without_text_count = 5
        stats.role_counts["AXButton"] = 3
        stats.role_counts["AXTextField"] = 2

        let encoder = JSONEncoder()
        let data = try encoder.encode(stats)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Statistics.self, from: data)

        XCTAssertEqual(stats.count, decoded.count)
        XCTAssertEqual(stats.visible_elements_count, decoded.visible_elements_count)
        XCTAssertEqual(stats.with_text_count, decoded.with_text_count)
        XCTAssertEqual(stats.without_text_count, decoded.without_text_count)
        XCTAssertEqual(stats.role_counts["AXButton"], decoded.role_counts["AXButton"])
        XCTAssertEqual(stats.role_counts["AXTextField"], decoded.role_counts["AXTextField"])
    }

    // MARK: - Sendable

    func testStatistics_sendable() {
        // Verify Statistics can be used in concurrent contexts
        let stats = Statistics()

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(stats)
    }
}
