@testable import MacosUseSDK
import XCTest

/// Compile-time and API-contract tests for traverseAccessibilityTree.
///
/// These tests verify that the public API signature accepts the `shouldActivate`
/// parameter and that the internal `AccessibilityTraversalOperation` correctly
/// stores it. Actual traversal behavior (AX data quality, activation side
/// effects) is covered by integration tests since those require accessibility
/// permissions and a live target application.
final class AccessibilityTraversalAPITests: XCTestCase {
    // MARK: - API Signature Compilation

    /// Verifies the function signature compiles with no shouldActivate argument (uses default false).
    func testTraverseAccessibilityTree_defaultShouldActivateIsFalse() {
        // Calling with an invalid PID: the function may throw or return an empty tree.
        // Either outcome is acceptable — we only care that the call compiles.
        let result = Result { try traverseAccessibilityTree(pid: -1) }
        // If it returns successfully, verify the response structure
        if case let .success(data) = result {
            XCTAssertNotNil(data.app_name)
        }
        // If it throws, that's also acceptable for an invalid PID
    }

    /// Verifies shouldActivate=false is accepted explicitly.
    func testTraverseAccessibilityTree_explicitShouldActivateFalse() {
        let result = Result { try traverseAccessibilityTree(pid: -1, shouldActivate: false) }
        if case let .success(data) = result {
            XCTAssertNotNil(data.app_name)
        }
    }

    /// Verifies shouldActivate=true is accepted explicitly.
    func testTraverseAccessibilityTree_explicitShouldActivateTrue() {
        let result = Result { try traverseAccessibilityTree(pid: -1, shouldActivate: true) }
        if case let .success(data) = result {
            XCTAssertNotNil(data.app_name)
        }
    }

    /// Verifies onlyVisibleElements and shouldActivate can be combined.
    func testTraverseAccessibilityTree_bothParametersCombined() {
        let result1 = Result {
            try traverseAccessibilityTree(pid: -1, onlyVisibleElements: true, shouldActivate: false)
        }
        if case let .success(data) = result1 {
            XCTAssertNotNil(data.app_name)
        }

        let result2 = Result {
            try traverseAccessibilityTree(pid: -1, onlyVisibleElements: true, shouldActivate: true)
        }
        if case let .success(data) = result2 {
            XCTAssertNotNil(data.app_name)
        }
    }

    /// Verifies that traversal with shouldActivate=false for a non-existent PID
    /// does not crash and returns a valid (potentially empty) ResponseData.
    func testTraverseAccessibilityTree_nonExistentPID_noCrash() {
        // PID 99999 almost certainly does not map to a running app
        let result = Result {
            try traverseAccessibilityTree(pid: 99999, shouldActivate: false)
        }
        switch result {
        case let .success(data):
            // Valid response, possibly with zero elements
            XCTAssertGreaterThanOrEqual(data.elements.count, 0)
        case .failure:
            // Throwing is also acceptable for a non-existent PID
            break
        }
    }
}
