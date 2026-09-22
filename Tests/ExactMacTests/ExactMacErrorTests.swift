@testable import ExactMac
import XCTest

/// Tests for ExactMacError enum and its errorDescription implementations.
final class ExactMacErrorTests: XCTestCase {
    // MARK: - Error Conformance

    func testAccessibilityDenied_isError() {
        let error: Error = ExactMacError.accessibilityDenied
        XCTAssertNotNil(error)
    }

    func testAppNotFound_isError() {
        let error: Error = ExactMacError.appNotFound(pid: 123)
        XCTAssertNotNil(error)
    }

    func testJsonEncodingFailed_isError() {
        let underlying = NSError(domain: "test", code: 42)
        let error: Error = ExactMacError.jsonEncodingFailed(underlying)
        XCTAssertNotNil(error)
    }

    func testInternalError_isError() {
        let error: Error = ExactMacError.internalError("something went wrong")
        XCTAssertNotNil(error)
    }

    // MARK: - LocalizedError Conformance

    func testAccessibilityDenied_conformsToLocalizedError() {
        let error: LocalizedError = ExactMacError.accessibilityDenied
        XCTAssertNotNil(error.errorDescription)
    }

    func testAppNotFound_conformsToLocalizedError() {
        let error: LocalizedError = ExactMacError.appNotFound(pid: 123)
        XCTAssertNotNil(error.errorDescription)
    }

    func testJsonEncodingFailed_conformsToLocalizedError() {
        let underlying = NSError(domain: "test", code: 42)
        let error: LocalizedError = ExactMacError.jsonEncodingFailed(underlying)
        XCTAssertNotNil(error.errorDescription)
    }

    func testInternalError_conformsToLocalizedError() {
        let error: LocalizedError = ExactMacError.internalError("test message")
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - accessibilityDenied Tests

    func testAccessibilityDenied_descriptionContainsAccessibility() {
        let description = ExactMacError.accessibilityDenied.errorDescription
        XCTAssertTrue(description?.contains("Accessibility") == true)
    }

    func testAccessibilityDenied_descriptionContainsSystemSettings() {
        let description = ExactMacError.accessibilityDenied.errorDescription
        XCTAssertTrue(description?.contains("System Settings") == true)
    }

    func testAccessibilityDenied_descriptionContainsPrivacySecurity() {
        let description = ExactMacError.accessibilityDenied.errorDescription
        XCTAssertTrue(description?.contains("Privacy & Security") == true)
    }

    // MARK: - appNotFound Tests

    func testAppNotFound_descriptionContainsPid() {
        let description = ExactMacError.appNotFound(pid: 12345).errorDescription
        XCTAssertTrue(description?.contains("12345") == true)
    }

    func testAppNotFound_descriptionContainsNoRunningApplication() {
        let description = ExactMacError.appNotFound(pid: 99999).errorDescription
        XCTAssertTrue(description?.lowercased().contains("no running application") == true)
    }

    func testAppNotFound_withZeroPid() {
        let description = ExactMacError.appNotFound(pid: 0).errorDescription
        XCTAssertTrue(description?.contains("0") == true)
    }

    func testAppNotFound_withNegativePid() {
        let description = ExactMacError.appNotFound(pid: -1).errorDescription
        XCTAssertTrue(description?.contains("-1") == true)
    }

    func testAppNotFound_withMaxPid() {
        let description = ExactMacError.appNotFound(pid: Int32.max).errorDescription
        XCTAssertTrue(description?.contains("\(Int32.max)") == true)
    }

    // MARK: - jsonEncodingFailed Tests

    func testJsonEncodingFailed_descriptionContainsUnderlyingError() {
        let underlying = NSError(domain: "TestDomain", code: 123, userInfo: [
            NSLocalizedDescriptionKey: "Test error message",
        ])
        let description = ExactMacError.jsonEncodingFailed(underlying).errorDescription
        XCTAssertTrue(description?.contains("Test error message") == true)
    }

    func testJsonEncodingFailed_descriptionContainsJSON() {
        let underlying = NSError(domain: "test", code: 0)
        let description = ExactMacError.jsonEncodingFailed(underlying).errorDescription
        XCTAssertTrue(description?.contains("JSON") == true)
    }

    func testJsonEncodingFailed_descriptionContainsFailed() {
        let underlying = NSError(domain: "test", code: 0)
        let description = ExactMacError.jsonEncodingFailed(underlying).errorDescription
        XCTAssertTrue(description?.lowercased().contains("failed") == true)
    }

    func testJsonEncodingFailed_withEncodingError() {
        struct CodingKeyForTest: CodingKey {
            var stringValue: String
            var intValue: Int?

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue _: Int) {
                nil
            }
        }
        let codingKey = CodingKeyForTest(stringValue: "testKey")
        let context = EncodingError.Context(
            codingPath: [codingKey],
            debugDescription: "Test encoding context",
        )
        let underlyingError = EncodingError.invalidValue("test", context)
        let description = ExactMacError.jsonEncodingFailed(underlyingError).errorDescription

        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("JSON") == true)
    }

    // MARK: - internalError Tests

    func testInternalError_descriptionContainsMessage() {
        let message = "Something went terribly wrong"
        let description = ExactMacError.internalError(message).errorDescription
        XCTAssertTrue(description?.contains(message) == true)
    }

    func testInternalError_descriptionContainsSDKError() {
        let description = ExactMacError.internalError("test").errorDescription
        XCTAssertTrue(description?.contains("SDK error") == true)
    }

    func testInternalError_withEmptyMessage() {
        let description = ExactMacError.internalError("").errorDescription
        XCTAssertNotNil(description)
        // Should still be a valid description even with empty message
        XCTAssertTrue(description?.contains("SDK") == true)
    }

    func testInternalError_withLongMessage() {
        let longMessage = String(repeating: "x", count: 1000)
        let description = ExactMacError.internalError(longMessage).errorDescription
        XCTAssertTrue(description?.contains(longMessage) == true)
    }

    func testInternalError_withSpecialCharacters() {
        let message = "Error with special chars: <>&\"'\n\t"
        let description = ExactMacError.internalError(message).errorDescription
        XCTAssertTrue(description?.contains(message) == true)
    }

    func testInternalError_withUnicode() {
        let message = "エラー: 失敗しました 🔴"
        let description = ExactMacError.internalError(message).errorDescription
        XCTAssertTrue(description?.contains("エラー") == true)
        XCTAssertTrue(description?.contains("🔴") == true)
    }

    // MARK: - Equatable Behavior (if implemented)

    func testErrorCases_areDifferentiable() {
        // Verify each case produces a unique description prefix
        let denied = ExactMacError.accessibilityDenied.errorDescription ?? ""
        let notFound = ExactMacError.appNotFound(pid: 1).errorDescription ?? ""
        let jsonFailed = ExactMacError.jsonEncodingFailed(NSError(domain: "", code: 0)).errorDescription ?? ""
        let internalErr = ExactMacError.internalError("test").errorDescription ?? ""

        XCTAssertNotEqual(denied, notFound)
        XCTAssertNotEqual(denied, jsonFailed)
        XCTAssertNotEqual(denied, internalErr)
        XCTAssertNotEqual(notFound, jsonFailed)
        XCTAssertNotEqual(notFound, internalErr)
        XCTAssertNotEqual(jsonFailed, internalErr)
    }

    // MARK: - Usage in catch blocks

    func testCatchingAsLocalizedError() {
        func throwingFunction() throws {
            throw ExactMacError.appNotFound(pid: 42)
        }

        do {
            try throwingFunction()
            XCTFail("Should have thrown")
        } catch let error as LocalizedError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription?.contains("42") == true)
        } catch {
            XCTFail("Error should conform to LocalizedError")
        }
    }
}
