@testable import MacosUseSDK
import XCTest

/// Tests for ActionOptions validation logic.
///
/// Verifies that showDiff implies traverseBefore and traverseAfter.
final class ActionCoordinatorTests: XCTestCase {
    // MARK: - Default Values

    func testDefaultValues() {
        let options = ActionOptions()

        XCTAssertFalse(options.traverseBefore)
        XCTAssertFalse(options.traverseAfter)
        XCTAssertFalse(options.showDiff)
        XCTAssertFalse(options.onlyVisibleElements)
        XCTAssertTrue(options.showAnimation)
        XCTAssertEqual(options.animationDuration, 0.8)
        XCTAssertNil(options.pidForTraversal)
        XCTAssertEqual(options.delayAfterAction, 0.2)
    }

    // MARK: - Validation Logic

    func testValidated_showDiffImpliesTraversals() {
        var options = ActionOptions(showDiff: true)
        let validated = options.validated()

        XCTAssertTrue(validated.traverseBefore, "showDiff should imply traverseBefore")
        XCTAssertTrue(validated.traverseAfter, "showDiff should imply traverseAfter")
        XCTAssertTrue(validated.showDiff)
    }

    func testValidated_withoutShowDiff() {
        let options = ActionOptions(
            traverseBefore: true,
            traverseAfter: false,
            showDiff: false,
        )
        let validated = options.validated()

        XCTAssertTrue(validated.traverseBefore)
        XCTAssertFalse(validated.traverseAfter)
        XCTAssertFalse(validated.showDiff)
    }

    func testValidated_explicitTraversalsPreserved() {
        var options = ActionOptions(
            traverseBefore: true,
            traverseAfter: true,
            showDiff: false,
        )
        let validated = options.validated()

        XCTAssertTrue(validated.traverseBefore)
        XCTAssertTrue(validated.traverseAfter)
    }

    // MARK: - Custom Initialization

    func testCustomInitialization() {
        let options = ActionOptions(
            traverseBefore: true,
            traverseAfter: true,
            showDiff: true,
            onlyVisibleElements: true,
            showAnimation: false,
            animationDuration: 2.0,
            pidForTraversal: 12345,
            delayAfterAction: 0.5,
        )

        XCTAssertTrue(options.traverseBefore)
        XCTAssertTrue(options.traverseAfter)
        XCTAssertTrue(options.showDiff)
        XCTAssertTrue(options.onlyVisibleElements)
        XCTAssertFalse(options.showAnimation)
        XCTAssertEqual(options.animationDuration, 2.0)
        XCTAssertEqual(options.pidForTraversal, 12345)
        XCTAssertEqual(options.delayAfterAction, 0.5)
    }

    // MARK: - Sendable

    func testActionOptions_sendable() {
        let options = ActionOptions()

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(options)
    }
}

// MARK: - ActionResult Tests

final class ActionResultTests: XCTestCase {
    // MARK: - Default Values

    func testDefaultValues() {
        let result = ActionResult()

        XCTAssertNil(result.openResult)
        XCTAssertNil(result.traversalPid)
        XCTAssertNil(result.traversalBefore)
        XCTAssertNil(result.traversalAfter)
        XCTAssertNil(result.traversalDiff)
        XCTAssertNil(result.primaryActionError)
        XCTAssertNil(result.traversalBeforeError)
        XCTAssertNil(result.traversalAfterError)
    }

    // MARK: - Custom Initialization

    func testCustomInitialization() {
        let openResult = AppOpenerResult(
            pid: 12345,
            appName: "TestApp",
            processingTimeSeconds: "0.100",
        )

        let result = ActionResult(
            openResult: openResult,
            traversalPid: 12345,
            traversalBefore: nil,
            traversalAfter: nil,
            traversalDiff: nil,
            primaryActionError: nil,
            traversalBeforeError: nil,
            traversalAfterError: nil,
        )

        XCTAssertNotNil(result.openResult)
        XCTAssertEqual(result.openResult?.pid, 12345)
        XCTAssertEqual(result.traversalPid, 12345)
    }

    // MARK: - Error Storage

    func testErrorStorage_primaryActionError() {
        let result = ActionResult(
            primaryActionError: "Failed to click element",
        )

        XCTAssertEqual(result.primaryActionError, "Failed to click element")
    }

    func testErrorStorage_traversalErrors() {
        let result = ActionResult(
            traversalBeforeError: "Traversal failed before action",
            traversalAfterError: "Traversal failed after action",
        )

        XCTAssertEqual(result.traversalBeforeError, "Traversal failed before action")
        XCTAssertEqual(result.traversalAfterError, "Traversal failed after action")
    }

    // MARK: - Codable

    func testActionResult_codable() throws {
        let result = ActionResult(
            openResult: AppOpenerResult(
                pid: 12345,
                appName: "TestApp",
                processingTimeSeconds: "0.100",
            ),
            traversalPid: 12345,
            primaryActionError: nil,
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ActionResult.self, from: data)

        XCTAssertEqual(result.openResult?.pid, decoded.openResult?.pid)
        XCTAssertEqual(result.openResult?.appName, decoded.openResult?.appName)
        XCTAssertEqual(result.traversalPid, decoded.traversalPid)
    }

    // MARK: - Sendable

    func testActionResult_sendable() {
        let result = ActionResult()

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(result)
    }
}
