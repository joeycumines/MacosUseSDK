@testable import MacosUseSDK
import XCTest

/// Tests for MacosUseSDKError.AppOpenerError enum and its errorDescription implementations.
final class AppOpenerErrorTests: XCTestCase {
    // MARK: - Error Conformance

    func testAppNotFound_isError() {
        let error: Error = MacosUseSDKError.AppOpenerError.appNotFound(identifier: "test.app")
        XCTAssertNotNil(error)
    }

    func testInvalidPath_isError() {
        let error: Error = MacosUseSDKError.AppOpenerError.invalidPath(path: "/test/path")
        XCTAssertNotNil(error)
    }

    func testActivationFailed_isError() {
        let error: Error = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "test.app",
            underlyingError: nil,
        )
        XCTAssertNotNil(error)
    }

    func testPidLookupFailed_isError() {
        let error: Error = MacosUseSDKError.AppOpenerError.pidLookupFailed(identifier: "test.app")
        XCTAssertNotNil(error)
    }

    func testUnexpectedNilURL_isError() {
        let error: Error = MacosUseSDKError.AppOpenerError.unexpectedNilURL
        XCTAssertNotNil(error)
    }

    // MARK: - LocalizedError Conformance

    func testAllCases_conformToLocalizedError() {
        let errors: [LocalizedError] = [
            MacosUseSDKError.AppOpenerError.appNotFound(identifier: "x"),
            MacosUseSDKError.AppOpenerError.invalidPath(path: "x"),
            MacosUseSDKError.AppOpenerError.activationFailed(identifier: "x", underlyingError: nil),
            MacosUseSDKError.AppOpenerError.pidLookupFailed(identifier: "x"),
            MacosUseSDKError.AppOpenerError.unexpectedNilURL,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
        }
    }

    // MARK: - appNotFound Tests

    func testAppNotFound_descriptionContainsIdentifier() {
        let identifier = "com.example.myapp"
        let description = MacosUseSDKError.AppOpenerError.appNotFound(
            identifier: identifier,
        ).errorDescription
        XCTAssertTrue(description?.contains(identifier) == true)
    }

    func testAppNotFound_descriptionContainsNotFound() {
        let description = MacosUseSDKError.AppOpenerError.appNotFound(
            identifier: "test",
        ).errorDescription
        XCTAssertTrue(description?.lowercased().contains("not found") == true)
    }

    func testAppNotFound_withEmptyIdentifier() {
        let description = MacosUseSDKError.AppOpenerError.appNotFound(identifier: "").errorDescription
        XCTAssertNotNil(description)
    }

    func testAppNotFound_withSpecialCharacters() {
        let identifier = "app.with.special-chars_v1.0"
        let description = MacosUseSDKError.AppOpenerError.appNotFound(
            identifier: identifier,
        ).errorDescription
        XCTAssertTrue(description?.contains(identifier) == true)
    }

    // MARK: - invalidPath Tests

    func testInvalidPath_descriptionContainsPath() {
        let path = "/Applications/NonExistent.app"
        let description = MacosUseSDKError.AppOpenerError.invalidPath(path: path).errorDescription
        XCTAssertTrue(description?.contains(path) == true)
    }

    func testInvalidPath_descriptionMentionsBundle() {
        let description = MacosUseSDKError.AppOpenerError.invalidPath(
            path: "/test",
        ).errorDescription
        XCTAssertTrue(description?.lowercased().contains("bundle") == true)
    }

    func testInvalidPath_withEmptyPath() {
        let description = MacosUseSDKError.AppOpenerError.invalidPath(path: "").errorDescription
        XCTAssertNotNil(description)
    }

    func testInvalidPath_withSpacesInPath() {
        let path = "/Applications/My App Name.app"
        let description = MacosUseSDKError.AppOpenerError.invalidPath(path: path).errorDescription
        XCTAssertTrue(description?.contains(path) == true)
    }

    // MARK: - activationFailed Tests

    func testActivationFailed_descriptionContainsIdentifier() {
        let identifier = "com.apple.Safari"
        let description = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: identifier,
            underlyingError: nil,
        ).errorDescription
        XCTAssertTrue(description?.contains(identifier) == true)
    }

    func testActivationFailed_withNilUnderlyingError() {
        let description = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "test",
            underlyingError: nil,
        ).errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.lowercased().contains("failed") == true)
    }

    func testActivationFailed_withUnderlyingError() {
        let underlying = NSError(domain: "TestDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Test underlying error",
        ])
        let description = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "test",
            underlyingError: underlying,
        ).errorDescription

        XCTAssertTrue(description?.contains("Test underlying error") == true)
    }

    func testActivationFailed_descriptionDiffersWithAndWithoutUnderlying() {
        let withoutError = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "app",
            underlyingError: nil,
        ).errorDescription ?? ""

        let underlying = NSError(domain: "", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Boom",
        ])
        let withError = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "app",
            underlyingError: underlying,
        ).errorDescription ?? ""

        XCTAssertNotEqual(withoutError, withError)
        XCTAssertTrue(withError.contains("Boom"))
        XCTAssertFalse(withoutError.contains("Boom"))
    }

    // MARK: - pidLookupFailed Tests

    func testPidLookupFailed_descriptionContainsIdentifier() {
        let identifier = "com.example.app"
        let description = MacosUseSDKError.AppOpenerError.pidLookupFailed(
            identifier: identifier,
        ).errorDescription
        XCTAssertTrue(description?.contains(identifier) == true)
    }

    func testPidLookupFailed_descriptionMentionsPID() {
        let description = MacosUseSDKError.AppOpenerError.pidLookupFailed(
            identifier: "test",
        ).errorDescription
        XCTAssertTrue(description?.contains("PID") == true)
    }

    func testPidLookupFailed_withEmptyIdentifier() {
        let description = MacosUseSDKError.AppOpenerError.pidLookupFailed(
            identifier: "",
        ).errorDescription
        XCTAssertNotNil(description)
    }

    // MARK: - unexpectedNilURL Tests

    func testUnexpectedNilURL_hasDescription() {
        let description = MacosUseSDKError.AppOpenerError.unexpectedNilURL.errorDescription
        XCTAssertNotNil(description)
    }

    func testUnexpectedNilURL_descriptionMentionsInternal() {
        let description = MacosUseSDKError.AppOpenerError.unexpectedNilURL.errorDescription
        XCTAssertTrue(description?.lowercased().contains("internal") == true)
    }

    func testUnexpectedNilURL_descriptionMentionsNil() {
        let description = MacosUseSDKError.AppOpenerError.unexpectedNilURL.errorDescription
        XCTAssertTrue(description?.lowercased().contains("nil") == true)
    }

    // MARK: - All Descriptions are Unique

    func testAllCases_haveUniqueDescriptions() {
        let descriptions = [
            MacosUseSDKError.AppOpenerError.appNotFound(identifier: "a").errorDescription,
            MacosUseSDKError.AppOpenerError.invalidPath(path: "a").errorDescription,
            MacosUseSDKError.AppOpenerError.activationFailed(
                identifier: "a",
                underlyingError: nil,
            ).errorDescription,
            MacosUseSDKError.AppOpenerError.pidLookupFailed(identifier: "a").errorDescription,
            MacosUseSDKError.AppOpenerError.unexpectedNilURL.errorDescription,
        ]

        let uniqueDescriptions = Set(descriptions)
        XCTAssertEqual(descriptions.count, uniqueDescriptions.count)
    }

    // MARK: - Edge Cases

    func testAppNotFound_withUnicodeIdentifier() {
        let identifier = "com.日本語.アプリ"
        let description = MacosUseSDKError.AppOpenerError.appNotFound(
            identifier: identifier,
        ).errorDescription
        XCTAssertTrue(description?.contains("日本語") == true)
        XCTAssertTrue(description?.contains("アプリ") == true)
    }

    func testActivationFailed_withDeepNestedError() {
        let inner = NSError(domain: "Inner", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Inner failure",
        ])
        let outer = NSError(domain: "Outer", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Outer failure",
            NSUnderlyingErrorKey: inner,
        ])
        let description = MacosUseSDKError.AppOpenerError.activationFailed(
            identifier: "test",
            underlyingError: outer,
        ).errorDescription

        // Should contain the outer error's localized description
        XCTAssertTrue(description?.contains("Outer failure") == true)
    }
}
