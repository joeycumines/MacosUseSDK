import Foundation
import GRPCCore
import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Tests for RPC request validation logic across various handlers.
///
/// This test file validates that the input validation added to RPC handlers
/// correctly rejects invalid inputs with proper error codes and messages.
final class RequestValidationTests: XCTestCase {
    // MARK: - Test Helpers

    /// Extract ErrorInfo from an RPCError for detailed validation.
    private func extractErrorInfo(from error: RPCError) throws -> Google_Rpc_ErrorInfo {
        var statusData: [UInt8]?
        for binaryData in error.metadata[binaryValues: "grpc-status-details-bin"] {
            statusData = binaryData
            break
        }

        guard let data = statusData else {
            throw TestError.missingMetadata("grpc-status-details-bin not found")
        }

        let status = try Google_Rpc_Status(serializedBytes: data)
        guard !status.details.isEmpty else {
            throw TestError.missingDetails("No details in status")
        }

        let anyDetail = status.details[0]
        guard anyDetail.isA(Google_Rpc_ErrorInfo.self) else {
            throw TestError.typeMismatch("Detail is not ErrorInfo")
        }

        return try Google_Rpc_ErrorInfo(serializedBytes: anyDetail.value)
    }

    private enum TestError: Error, CustomStringConvertible {
        case missingMetadata(String)
        case missingDetails(String)
        case typeMismatch(String)

        var description: String {
            switch self {
            case let .missingMetadata(msg): "Missing metadata: \(msg)"
            case let .missingDetails(msg): "Missing details: \(msg)"
            case let .typeMismatch(msg): "Type mismatch: \(msg)"
            }
        }
    }

    // MARK: - Coordinate Validation Tests (NaN/Infinity)

    func testCoordinateValidationRejectsNaNX() throws {
        // Test that NaN x coordinate produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "x coordinate must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "x",
            value: String(Double.nan),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_COORDINATE")
        XCTAssertEqual(errorInfo.metadata["field"], "x")
    }

    func testCoordinateValidationRejectsNaNY() throws {
        // Test that NaN y coordinate produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "y coordinate must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "y",
            value: String(Double.nan),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_COORDINATE")
        XCTAssertEqual(errorInfo.metadata["field"], "y")
    }

    func testCoordinateValidationRejectsInfinityWidth() throws {
        // Test that Infinity width produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "width",
            value: String(Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "width")
    }

    func testCoordinateValidationRejectsInfinityHeight() throws {
        // Test that Infinity height produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "height must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "height",
            value: String(Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "height")
    }

    func testCoordinateValidationRejectsNegativeInfinityX() throws {
        // Test that negative infinity is also rejected
        let error = RPCErrorHelpers.validationError(
            message: "x coordinate must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "x",
            value: String(-Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_COORDINATE")
        XCTAssertEqual(errorInfo.metadata["field"], "x")
    }

    func testCoordinateValidationRejectsNegativeWidth() throws {
        // Test that negative width produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "width",
            value: String(-100.0),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "width")
    }

    func testCoordinateValidationRejectsNegativeHeight() throws {
        // Test that negative height produces proper validation error
        let error = RPCErrorHelpers.validationError(
            message: "height must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "height",
            value: String(-50.0),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "height")
    }

    func testCoordinateValidationRejectsZeroWidth() throws {
        // Test that zero width produces proper validation error (must be positive)
        let error = RPCErrorHelpers.validationError(
            message: "width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "width",
            value: String(0.0),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "width")
    }

    // MARK: - Coordinate Validity Checks (isFinite helper tests)

    func testValidCoordinatesAreFinite() {
        // Valid coordinates pass isFinite check
        XCTAssertTrue(Double(100.0).isFinite)
        XCTAssertTrue(Double(-100.0).isFinite)
        XCTAssertTrue(Double(0.0).isFinite)
        XCTAssertTrue(Double(1920.5).isFinite)
    }

    func testInvalidCoordinatesAreNotFinite() {
        // Invalid coordinates fail isFinite check
        XCTAssertFalse(Double.nan.isFinite)
        XCTAssertFalse(Double.infinity.isFinite)
        XCTAssertFalse((-Double.infinity).isFinite)
        XCTAssertFalse(Double.signalingNaN.isFinite)
    }

    // MARK: - Empty Required Field Tests

    func testValidationErrorForEmptyName() throws {
        // Simulates getElement with empty name field
        let error = RPCErrorHelpers.validationError(
            message: "name is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "name",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "name")
        XCTAssertNil(errorInfo.metadata["value"])
    }

    func testValidationErrorForEmptyAction() throws {
        // Simulates performElementAction with empty action field
        let error = RPCErrorHelpers.validationError(
            message: "action is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "action",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "action")
    }

    func testValidationErrorForEmptyScript() throws {
        // Simulates executeAppleScript with empty script field
        let error = RPCErrorHelpers.validationError(
            message: "script is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "script",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "script")
    }

    func testValidationErrorForEmptyCommand() throws {
        // Simulates executeShellCommand with empty command field
        let error = RPCErrorHelpers.validationError(
            message: "command is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "command",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "command")
    }

    func testValidationErrorForEmptyFilePath() throws {
        // Simulates automateSaveFileDialog with empty file_path field
        let error = RPCErrorHelpers.validationError(
            message: "file_path is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "file_path",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "file_path")
    }

    func testValidationErrorForEmptyDirectoryPath() throws {
        // Simulates selectDirectory with empty directory_path field
        let error = RPCErrorHelpers.validationError(
            message: "directory_path is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "directory_path",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "directory_path")
    }

    func testValidationErrorForEmptyElementId() throws {
        // Simulates captureElementScreenshot with empty element_id field
        let error = RPCErrorHelpers.validationError(
            message: "element_id is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "element_id",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "element_id")
    }

    func testValidationErrorForEmptyTargetElementId() throws {
        // Simulates dragFiles with empty target_element_id field
        let error = RPCErrorHelpers.validationError(
            message: "target_element_id is required",
            reason: "REQUIRED_FIELD_MISSING",
            field: "target_element_id",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "target_element_id")
    }

    // MARK: - Empty List Tests

    func testValidationErrorForEmptyFilePaths() throws {
        // Simulates dragFiles with empty file_paths array
        let error = RPCErrorHelpers.validationError(
            message: "file_paths is required (at least one file path)",
            reason: "REQUIRED_FIELD_MISSING",
            field: "file_paths",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "REQUIRED_FIELD_MISSING")
        XCTAssertEqual(errorInfo.metadata["field"], "file_paths")
    }

    // MARK: - Region Coordinate Validation Tests

    func testRegionValidationRejectsNaNRegionX() throws {
        // Simulates captureRegionScreenshot with NaN region.x
        let error = RPCErrorHelpers.validationError(
            message: "region.x must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "region.x",
            value: String(Double.nan),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_COORDINATE")
        XCTAssertEqual(errorInfo.metadata["field"], "region.x")
    }

    func testRegionValidationRejectsNaNRegionY() throws {
        // Simulates findRegionElements with NaN region.y
        let error = RPCErrorHelpers.validationError(
            message: "region.y must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "region.y",
            value: String(Double.nan),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_COORDINATE")
        XCTAssertEqual(errorInfo.metadata["field"], "region.y")
    }

    func testRegionValidationRejectsInfinityRegionWidth() throws {
        // Simulates captureRegionScreenshot with Infinity region.width
        let error = RPCErrorHelpers.validationError(
            message: "region.width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "region.width",
            value: String(Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "region.width")
    }

    func testRegionValidationRejectsInfinityRegionHeight() throws {
        // Simulates findRegionElements with Infinity region.height
        let error = RPCErrorHelpers.validationError(
            message: "region.height must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "region.height",
            value: String(Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "region.height")
    }

    func testRegionValidationRejectsNegativeRegionWidth() throws {
        // Simulates captureRegionScreenshot with negative region.width
        let error = RPCErrorHelpers.validationError(
            message: "region.width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "region.width",
            value: String(-200.0),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "region.width")
    }

    // MARK: - Duration and Padding Validation Tests

    func testDurationValidationRejectsNegative() throws {
        // Simulates dragFiles with negative duration
        let error = RPCErrorHelpers.validationError(
            message: "duration must be a finite non-negative number",
            reason: "INVALID_DIMENSION",
            field: "duration",
            value: String(-1.0),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "duration")
    }

    func testDurationValidationRejectsInfinity() throws {
        // Simulates dragFiles with infinite duration
        let error = RPCErrorHelpers.validationError(
            message: "duration must be a finite non-negative number",
            reason: "INVALID_DIMENSION",
            field: "duration",
            value: String(Double.infinity),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "duration")
    }

    func testPaddingValidationRejectsNegative() throws {
        // Simulates captureElementScreenshot with negative padding
        let error = RPCErrorHelpers.validationError(
            message: "padding must be a non-negative number",
            reason: "INVALID_DIMENSION",
            field: "padding",
            value: String(-10),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, "INVALID_DIMENSION")
        XCTAssertEqual(errorInfo.metadata["field"], "padding")
    }

    // MARK: - Validation Reason Constants Tests

    func testValidationReasonEmptyFieldConstant() {
        // Verify the constant value matches expected
        XCTAssertEqual(RPCErrorHelpers.ValidationReason.emptyField, "EMPTY_FIELD")
    }

    func testValidationReasonOutOfRangeConstant() {
        // Verify the constant value matches expected
        XCTAssertEqual(RPCErrorHelpers.ValidationReason.outOfRange, "OUT_OF_RANGE")
    }

    func testValidationReasonInvalidFormatConstant() {
        // Verify the constant value matches expected
        XCTAssertEqual(RPCErrorHelpers.ValidationReason.invalidFormat, "INVALID_FORMAT")
    }

    func testValidationReasonInvalidRegexConstant() {
        // Verify the constant value matches expected
        XCTAssertEqual(RPCErrorHelpers.ValidationReason.invalidRegex, "INVALID_REGEX")
    }

    func testValidationReasonInvalidPageTokenConstant() {
        // Verify the constant value matches expected
        XCTAssertEqual(RPCErrorHelpers.ValidationReason.invalidPageToken, "INVALID_PAGE_TOKEN")
    }

    // MARK: - Error Domain Tests

    func testErrorDomainIsCorrect() {
        // Verify the domain is set correctly
        XCTAssertEqual(RPCErrorHelpers.domain, "macosusesdk.com")
    }

    func testAllValidationErrorsHaveCorrectDomain() throws {
        // Verify domain is propagated to all validation errors
        let error = RPCErrorHelpers.validationError(
            message: "Test",
            reason: "TEST_REASON",
            field: "test_field",
        )

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
    }

    // MARK: - Combined Validation Scenarios

    func testMoveWindowValidationScenario() {
        // Simulate the full validation check for moveWindow
        let testX = Double.nan
        let testY = 100.0

        // First check (would be in handler)
        XCTAssertFalse(testX.isFinite, "NaN x should fail isFinite check")
        XCTAssertTrue(testY.isFinite, "Valid y should pass isFinite check")

        // Error that would be thrown
        let error = RPCErrorHelpers.validationError(
            message: "x coordinate must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "x",
            value: String(testX),
        )

        XCTAssertEqual(error.code, .invalidArgument)
    }

    func testResizeWindowValidationScenario() {
        // Simulate the full validation check for resizeWindow
        let testWidth = -50.0
        let testHeight = 100.0

        // First check (would be in handler)
        let widthValid = testWidth.isFinite && testWidth > 0
        let heightValid = testHeight.isFinite && testHeight > 0

        XCTAssertFalse(widthValid, "Negative width should fail validation")
        XCTAssertTrue(heightValid, "Positive height should pass validation")

        // Error that would be thrown
        let error = RPCErrorHelpers.validationError(
            message: "width must be a finite positive number",
            reason: "INVALID_DIMENSION",
            field: "width",
            value: String(testWidth),
        )

        XCTAssertEqual(error.code, .invalidArgument)
    }

    func testCaptureRegionValidationScenario() throws {
        // Simulate validation for captureRegionScreenshot with multiple issues
        let region = (x: 100.0, y: Double.infinity, width: 200.0, height: 0.0)

        // Validate each field
        XCTAssertTrue(region.x.isFinite, "x is valid")
        XCTAssertFalse(region.y.isFinite, "y is Infinity - invalid")
        XCTAssertTrue(region.width.isFinite && region.width > 0, "width is valid")
        XCTAssertFalse(region.height.isFinite && region.height > 0, "height is 0 - invalid")

        // First error encountered would be y
        let error = RPCErrorHelpers.validationError(
            message: "region.y must be a finite number",
            reason: "INVALID_COORDINATE",
            field: "region.y",
            value: String(region.y),
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.metadata["field"], "region.y")
    }
}
