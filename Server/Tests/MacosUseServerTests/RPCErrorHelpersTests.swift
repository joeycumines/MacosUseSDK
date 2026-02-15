import Foundation
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Tests for RPCErrorHelpers error creation and ErrorInfo details per AIP-193.
final class RPCErrorHelpersTests: XCTestCase {
    // MARK: - Basic Error Properties

    func testErrorCreatesRPCErrorWithCorrectCode() {
        let error = RPCErrorHelpers.error(
            code: .invalidArgument,
            message: "Test message",
            reason: "TEST_REASON",
        )

        XCTAssertEqual(error.code, .invalidArgument)
    }

    func testErrorCreatesRPCErrorWithCorrectMessage() {
        let message = "This is a test error message"
        let error = RPCErrorHelpers.error(
            code: .notFound,
            message: message,
            reason: "TEST_REASON",
        )

        XCTAssertEqual(error.message, message)
    }

    // MARK: - Metadata Presence

    func testErrorHasGrpcStatusDetailsBinMetadata() {
        let error = RPCErrorHelpers.error(
            code: .invalidArgument,
            message: "Test",
            reason: "TEST_REASON",
        )

        // Verify the metadata contains the grpc-status-details-bin key
        var foundBinaryValue = false
        for binaryData in error.metadata[binaryValues: "grpc-status-details-bin"] {
            foundBinaryValue = true
            XCTAssertFalse(binaryData.isEmpty, "Binary data should not be empty")
        }
        XCTAssertTrue(foundBinaryValue, "grpc-status-details-bin key should be present in metadata")
    }

    // MARK: - ErrorInfo Extraction

    func testErrorInfoContainsReason() throws {
        let expectedReason = "CUSTOM_TEST_REASON"
        let error = RPCErrorHelpers.error(
            code: .invalidArgument,
            message: "Test message",
            reason: expectedReason,
        )

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, expectedReason)
    }

    func testErrorInfoContainsDomain() throws {
        let error = RPCErrorHelpers.error(
            code: .invalidArgument,
            message: "Test message",
            reason: "TEST_REASON",
        )

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
    }

    func testErrorInfoContainsMetadata() throws {
        let customMetadata: [String: String] = [
            "field": "window_name",
            "value": "invalid-format",
            "hint": "Use applications/{pid}/windows/{id}",
        ]

        let error = RPCErrorHelpers.error(
            code: .invalidArgument,
            message: "Test message",
            reason: "TEST_REASON",
            metadata: customMetadata,
        )

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.metadata["field"], "window_name")
        XCTAssertEqual(errorInfo.metadata["value"], "invalid-format")
        XCTAssertEqual(errorInfo.metadata["hint"], "Use applications/{pid}/windows/{id}")
    }

    // MARK: - Convenience Method Tests

    func testInvalidResourceNameConvenienceMethod() throws {
        let error = RPCErrorHelpers.invalidResourceName(
            message: "Invalid window name format",
            resourceType: "window",
            value: "bad-name",
            expectedFormat: "applications/{pid}/windows/{windowId}",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.ResourceNameReason.invalidFormat)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
        XCTAssertEqual(errorInfo.metadata["resourceType"], "window")
        XCTAssertEqual(errorInfo.metadata["value"], "bad-name")
        XCTAssertEqual(errorInfo.metadata["expectedFormat"], "applications/{pid}/windows/{windowId}")
    }

    func testNotFoundConvenienceMethod() throws {
        let error = RPCErrorHelpers.notFound(
            message: "Window not found",
            reason: RPCErrorHelpers.NotFoundReason.windowNotFound,
            resourceName: "applications/1234/windows/5678",
        )

        XCTAssertEqual(error.code, .notFound)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.NotFoundReason.windowNotFound)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
        XCTAssertEqual(errorInfo.metadata["resourceName"], "applications/1234/windows/5678")
    }

    func testPermissionDeniedConvenienceMethod() throws {
        let error = RPCErrorHelpers.permissionDenied(
            message: "Accessibility permission required",
            reason: RPCErrorHelpers.PermissionReason.accessibilityPermissionDenied,
            resource: "applications/1234",
        )

        XCTAssertEqual(error.code, .permissionDenied)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.PermissionReason.accessibilityPermissionDenied)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
        XCTAssertEqual(errorInfo.metadata["resource"], "applications/1234")
    }

    func testPermissionDeniedConvenienceMethodWithoutResource() throws {
        let error = RPCErrorHelpers.permissionDenied(
            message: "Permission denied",
            reason: RPCErrorHelpers.PermissionReason.permissionDenied,
        )

        XCTAssertEqual(error.code, .permissionDenied)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.PermissionReason.permissionDenied)
        XCTAssertTrue(errorInfo.metadata.isEmpty, "Metadata should be empty when no resource provided")
    }

    func testInternalErrorConvenienceMethod() throws {
        let error = RPCErrorHelpers.internalError(
            message: "Failed to serialize response",
            reason: RPCErrorHelpers.InternalReason.serializationFailed,
            metadata: ["component": "WindowRegistry"],
        )

        XCTAssertEqual(error.code, .internalError)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.InternalReason.serializationFailed)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
        XCTAssertEqual(errorInfo.metadata["component"], "WindowRegistry")
    }

    func testValidationErrorConvenienceMethod() throws {
        let error = RPCErrorHelpers.validationError(
            message: "Page size must be between 1 and 100",
            reason: RPCErrorHelpers.ValidationReason.outOfRange,
            field: "page_size",
            value: "500",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.ValidationReason.outOfRange)
        XCTAssertEqual(errorInfo.domain, "macosusesdk.com")
        XCTAssertEqual(errorInfo.metadata["field"], "page_size")
        XCTAssertEqual(errorInfo.metadata["value"], "500")
    }

    func testValidationErrorConvenienceMethodWithoutValue() throws {
        let error = RPCErrorHelpers.validationError(
            message: "Field is required",
            reason: RPCErrorHelpers.ValidationReason.emptyField,
            field: "name",
        )

        XCTAssertEqual(error.code, .invalidArgument)

        let errorInfo = try extractErrorInfo(from: error)
        XCTAssertEqual(errorInfo.reason, RPCErrorHelpers.ValidationReason.emptyField)
        XCTAssertEqual(errorInfo.metadata["field"], "name")
        XCTAssertNil(errorInfo.metadata["value"], "Value should not be present when not provided")
    }

    // MARK: - Helper Methods

    /// Extracts the ErrorInfo from an RPCError's grpc-status-details-bin metadata.
    private func extractErrorInfo(from error: RPCError) throws -> Google_Rpc_ErrorInfo {
        // Get the binary data from the metadata
        var statusData: [UInt8]?
        for binaryData in error.metadata[binaryValues: "grpc-status-details-bin"] {
            statusData = binaryData
            break
        }

        guard let data = statusData else {
            throw TestError.missingMetadata("grpc-status-details-bin not found in metadata")
        }

        // Parse as Google_Rpc_Status
        let status = try Google_Rpc_Status(serializedBytes: data)

        // Ensure we have at least one detail
        guard !status.details.isEmpty else {
            throw TestError.missingDetails("No details in Google_Rpc_Status")
        }

        // Get the first detail (should be ErrorInfo)
        let anyDetail = status.details[0]

        // Verify it's an ErrorInfo before unpacking
        guard anyDetail.isA(Google_Rpc_ErrorInfo.self) else {
            throw TestError.typeMismatch("Detail is not a Google_Rpc_ErrorInfo")
        }

        // Unpack the ErrorInfo by deserializing from the Any's value field
        return try Google_Rpc_ErrorInfo(serializedBytes: anyDetail.value)
    }

    /// Test errors for the helper methods.
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
}
