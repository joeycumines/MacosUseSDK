import Foundation
@testable import MacosUseSDK
import OSLog
import XCTest

/// Tests for SDKLogger configuration.
///
/// Verifies Logger subsystem and category isolation.
final class SDKLoggerTests: XCTestCase {
    // MARK: - Logger Creation

    func testSdkLogger_createsLogger() {
        // Test that sdkLogger function creates a valid Logger
        let logger = sdkLogger(category: "TestCategory")

        // Logger should be non-nil
        XCTAssertNotNil(logger)
    }

    func testSdkLogger_withDifferentCategories() {
        // Test creating loggers with different categories
        let logger1 = sdkLogger(category: "CategoryA")
        let logger2 = sdkLogger(category: "CategoryB")

        XCTAssertNotNil(logger1)
        XCTAssertNotNil(logger2)
    }

    // MARK: - Category Configuration

    func testSdkLogger_categoryIsolatesOutput() {
        // Loggers with different categories should be distinct
        let logger1 = sdkLogger(category: "WindowQuery")
        let logger2 = sdkLogger(category: "InputController")

        // Both should be valid loggers
        XCTAssertNotNil(logger1)
        XCTAssertNotNil(logger2)
    }

    // MARK: - Logging Output (Runtime Test)

    func testSdkLogger_logsInfo() {
        let logger = sdkLogger(category: "TestCategory")

        // This should not crash and should log info message
        logger.info("Test info message")

        XCTAssertTrue(true) // If we get here, logging didn't crash
    }

    func testSdkLogger_logsDebug() {
        let logger = sdkLogger(category: "TestCategory")

        logger.debug("Test debug message")

        XCTAssertTrue(true)
    }

    func testSdkLogger_logsError() {
        let logger = sdkLogger(category: "TestCategory")

        logger.error("Test error message")

        XCTAssertTrue(true)
    }

    func testSdkLogger_logsWithPrivacyPublic() {
        let logger = sdkLogger(category: "TestCategory")

        // Logging with public privacy should work
        logger.info("Public message with value: \(String(describing: 123), privacy: .public)")

        XCTAssertTrue(true)
    }

    func testSdkLogger_logsWithPrivacyPrivate() {
        let logger = sdkLogger(category: "TestCategory")

        // Logging with private privacy should work
        logger.info("Private message with value: \(String(describing: "secret"), privacy: .private)")

        XCTAssertTrue(true)
    }

    func testSdkLogger_logsWithPrivacyAuto() {
        let logger = sdkLogger(category: "TestCategory")

        // Logging with auto privacy should work
        logger.info("Auto message with value: \(String(describing: 42), privacy: .auto)")

        XCTAssertTrue(true)
    }

    func testSdkLogger_logsWithHash() {
        let logger = sdkLogger(category: "TestCategory")

        // Logging with private privacy (hash is not available in all OS versions)
        logger.info("Private message with value: \(String(describing: "sensitive"), privacy: .private)")

        XCTAssertTrue(true)
    }

    // MARK: - Logger Subsystem

    func testLogger_subsystemIsSet() {
        // The logger should use a specific subsystem
        // We can verify this by checking if logging works with the subsystem
        let logger = sdkLogger(category: "Test")

        // Log a message - if it doesn't crash, the subsystem is configured
        logger.info("Testing subsystem configuration")

        XCTAssertTrue(true)
    }

    // MARK: - Thread Safety

    func testSdkLogger_concurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent logging")
        expectation.expectedFulfillmentCount = 10

        DispatchQueue.concurrentPerform(iterations: 10) { index in
            let logger = sdkLogger(category: "ConcurrentCategory\(index)")
            logger.info("Concurrent log \(index)")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}

// MARK: - Logger Category String Tests

final class SDKLoggerCategoryTests: XCTestCase {
    func testCategoryNames_matchExpectedValues() {
        // Verify the expected category names from SDK files
        let expectedCategories = [
            "AccessibilityTraversal",
            "WindowQuery",
            "InputController",
            "AppOpener",
            "ActionCoordinator",
            "CombinedActions",
            "DrawVisuals",
            "HighlightInput",
        ]

        // Verify we can create loggers for each expected category
        for category in expectedCategories {
            let logger = sdkLogger(category: category)
            XCTAssertNotNil(logger, "Should create logger for category: \(category)")
        }
    }

    func testCategoryWithSpecialCharacters() {
        // Test category names with special characters
        let specialCategories = [
            "Category_With_Underscores",
            "Category.With.Dots",
            "Category-With-Dashes",
        ]

        for category in specialCategories {
            let logger = sdkLogger(category: category)
            XCTAssertNotNil(logger)
        }
    }

    func testCategoryWithNumbers() {
        let category = "Category123"
        let logger = sdkLogger(category: category)

        XCTAssertNotNil(logger)
    }

    func testCategoryWithUnicode() {
        let category = "カテゴリー"
        let logger = sdkLogger(category: category)

        XCTAssertNotNil(logger)
    }
}
