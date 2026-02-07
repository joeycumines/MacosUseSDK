import Foundation
@testable import MacosUseServer
import XCTest

/// Tests for ClipboardError enum descriptions.
final class ClipboardErrorTests: XCTestCase {
    // MARK: - Description Tests

    func testInvalidContentDescription() {
        let error = ClipboardError.invalidContent("No content specified")
        XCTAssertEqual(
            error.description,
            "Invalid clipboard content: No content specified",
        )
    }

    func testWriteFailedDescription() {
        let error = ClipboardError.writeFailed("Failed to write clipboard content")
        XCTAssertEqual(
            error.description,
            "Clipboard write failed: Failed to write clipboard content",
        )
    }

    func testReadFailedDescription() {
        let error = ClipboardError.readFailed("Pasteboard is empty")
        XCTAssertEqual(
            error.description,
            "Clipboard read failed: Pasteboard is empty",
        )
    }

    // MARK: - Error Conformance

    func testErrorConformance() {
        let error: any Error = ClipboardError.invalidContent("test")
        XCTAssertTrue(error is ClipboardError)
    }
}
