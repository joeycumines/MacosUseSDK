import ApplicationServices
@testable import MacosUseSDK
import XCTest

final class AccessibilityTraversalContractTests: XCTestCase {
    func testUnavailableOptionalMetadataDoesNotInvalidateTraversal() {
        for error in [
            AXError.failure,
            .cannotComplete,
            .attributeUnsupported,
            .noValue,
        ] {
            XCTAssertTrue(
                isUnavailableOptionalTraversalMetadataError(error),
                "\(error) should omit only the unavailable optional metadata",
            )
        }

        for error in [
            AXError.invalidUIElement,
            .apiDisabled,
            .illegalArgument,
        ] {
            XCTAssertFalse(
                isUnavailableOptionalTraversalMetadataError(error),
                "\(error) must still invalidate traversal",
            )
        }
    }

    func testStableTraversalOrderPreservesIdenticalSiblingsAndUsesPathAsFinalTieBreaker() {
        let first = makeElement(path: [0], axPID: 71001)
        let second = makeElement(path: [1], axPID: 71002)

        let ordered = stableTraversalElements([second, first])

        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered.map(\.path), [[0], [1]])
        XCTAssertFalse(CFEqual(ordered[0].axElement?.element, ordered[1].axElement?.element))
    }

    func testTraversalBudgetFailsClosedAtDepthNodeAndDeadlineBoundaries() throws {
        var deadlineExceeded = false
        let budget = AccessibilityTraversalBudget(
            maxDepth: 2,
            maxNodes: 2,
            deadlineExceeded: { deadlineExceeded },
        )

        try budget.beginElement(depth: 0)
        try budget.checkAXStep()
        try budget.beginElement(depth: 2)

        XCTAssertThrowsError(try budget.beginElement(depth: 3)) {
            XCTAssertEqual($0 as? AccessibilityTraversalLimitError, .depthExceeded)
        }
        XCTAssertThrowsError(try budget.beginElement(depth: 1)) {
            XCTAssertEqual($0 as? AccessibilityTraversalLimitError, .nodeLimitExceeded)
        }

        deadlineExceeded = true
        XCTAssertThrowsError(try budget.checkAXStep()) {
            XCTAssertEqual($0 as? AccessibilityTraversalLimitError, .deadlineExceeded)
        }
    }

    private func makeElement(path: [Int32], axPID: pid_t) -> ElementData {
        ElementData(
            role: "AXButton",
            text: "Identical",
            x: 10,
            y: 20,
            width: 100,
            height: 40,
            axElement: SendableAXUIElement(AXUIElementCreateApplication(axPID)),
            enabled: true,
            focused: false,
            attributes: [:],
            path: path,
        )
    }
}
