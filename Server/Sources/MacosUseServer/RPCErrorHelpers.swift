import Foundation
import GRPCCore
import MacosUseProto
import SwiftProtobuf

/// Helpers for creating RPCError with google.rpc.ErrorInfo details per AIP-193.
///
/// This enum provides factory methods for creating gRPC errors that include
/// structured error information in the `grpc-status-details-bin` trailing metadata.
/// The ErrorInfo message contains a machine-readable reason code, domain, and
/// optional metadata for programmatic error handling.
///
/// Usage:
/// ```swift
/// throw RPCErrorHelpers.error(
///     code: .invalidArgument,
///     message: "Invalid window name format",
///     reason: "INVALID_RESOURCE_NAME",
///     metadata: ["field": "name", "format": "applications/{pid}/windows/{windowId}"]
/// )
/// ```
///
/// Clients can extract the ErrorInfo from the trailing metadata by reading
/// the `grpc-status-details-bin` key and parsing it as a `google.rpc.Status` message.
public enum RPCErrorHelpers {
    /// The domain for all MacosUseSDK errors.
    /// Per AIP-193, this should be a globally unique identifier for the service.
    public static let domain = "macosusesdk.com"

    // MARK: - Standard Error Reason Codes

    /// Error reasons for resource name validation failures.
    public enum ResourceNameReason {
        /// The resource name format is invalid.
        public static let invalidFormat = "INVALID_RESOURCE_NAME"
        /// A required field in the resource name is missing.
        public static let missingField = "MISSING_RESOURCE_NAME_FIELD"
    }

    /// Error reasons for resource not found errors.
    public enum NotFoundReason {
        /// The requested application was not found.
        public static let applicationNotFound = "APPLICATION_NOT_FOUND"
        /// The requested window was not found.
        public static let windowNotFound = "WINDOW_NOT_FOUND"
        /// The requested element was not found.
        public static let elementNotFound = "ELEMENT_NOT_FOUND"
        /// The requested session was not found.
        public static let sessionNotFound = "SESSION_NOT_FOUND"
        /// The requested macro was not found.
        public static let macroNotFound = "MACRO_NOT_FOUND"
        /// The requested observation was not found.
        public static let observationNotFound = "OBSERVATION_NOT_FOUND"
        /// The requested operation was not found.
        public static let operationNotFound = "OPERATION_NOT_FOUND"
        /// The requested display was not found.
        public static let displayNotFound = "DISPLAY_NOT_FOUND"
    }

    /// Error reasons for permission and precondition failures.
    public enum PermissionReason {
        /// Accessibility permission is not granted.
        public static let accessibilityPermissionDenied = "ACCESSIBILITY_PERMISSION_DENIED"
        /// The operation requires a permission that was not granted.
        public static let permissionDenied = "PERMISSION_DENIED"
    }

    /// Error reasons for precondition failures.
    public enum PreconditionReason {
        /// The window match is ambiguous (multiple candidates).
        public static let ambiguousWindowMatch = "AMBIGUOUS_WINDOW_MATCH"
        /// A transaction is already in progress.
        public static let transactionInProgress = "TRANSACTION_IN_PROGRESS"
        /// No transaction is in progress.
        public static let noTransactionInProgress = "NO_TRANSACTION_IN_PROGRESS"
    }

    /// Error reasons for validation failures.
    public enum ValidationReason {
        /// A required field is empty or missing.
        public static let emptyField = "EMPTY_FIELD"
        /// A field value is out of valid range.
        public static let outOfRange = "OUT_OF_RANGE"
        /// A field value has an invalid format.
        public static let invalidFormat = "INVALID_FORMAT"
        /// A regex pattern is invalid.
        public static let invalidRegex = "INVALID_REGEX"
        /// A page token is invalid or corrupted.
        public static let invalidPageToken = "INVALID_PAGE_TOKEN"
    }

    /// Error reasons for internal errors.
    public enum InternalReason {
        /// Failed to serialize a protobuf message.
        public static let serializationFailed = "SERIALIZATION_FAILED"
        /// An accessibility API call failed.
        public static let accessibilityApiFailed = "ACCESSIBILITY_API_FAILED"
        /// A timeout occurred during the operation.
        public static let timeout = "TIMEOUT"
    }

    // MARK: - Factory Methods

    /// Creates an RPCError with google.rpc.ErrorInfo in trailing metadata.
    ///
    /// This method constructs a gRPC error that includes structured error details
    /// per AIP-193. The ErrorInfo is packed into a `google.rpc.Status` message
    /// and serialized into the `grpc-status-details-bin` trailing metadata key.
    ///
    /// - Parameters:
    ///   - code: The gRPC status code (e.g., `.invalidArgument`, `.notFound`).
    ///   - message: Human-readable error message suitable for logging/debugging.
    ///   - reason: Machine-readable error reason in UPPER_SNAKE_CASE format.
    ///   - errorMetadata: Additional key-value metadata for programmatic handling.
    /// - Returns: An RPCError with ErrorInfo packed in grpc-status-details-bin.
    public static func error(
        code: RPCError.Code,
        message: String,
        reason: String,
        metadata errorMetadata: [String: String] = [:],
    ) -> RPCError {
        // Build ErrorInfo
        var errorInfo = Google_Rpc_ErrorInfo()
        errorInfo.reason = reason
        errorInfo.domain = domain
        errorInfo.metadata = errorMetadata

        // Build google.rpc.Status with the ErrorInfo packed as Any
        var status = Google_Rpc_Status()
        status.code = Int32(code.rawValue)
        status.message = message
        do {
            let anyMessage = try Google_Protobuf_Any(message: errorInfo)
            status.details = [anyMessage]
        } catch {
            // If packing fails, return error without details
            return RPCError(code: code, message: message)
        }

        // Serialize and add to metadata
        do {
            let statusData = try status.serializedData()
            var grpcMetadata = Metadata()
            // Binary metadata keys must end in "-bin"
            grpcMetadata.addBinary(Array(statusData), forKey: "grpc-status-details-bin")
            return RPCError(code: code, message: message, metadata: grpcMetadata)
        } catch {
            // If serialization fails, return error without details
            return RPCError(code: code, message: message)
        }
    }

    // MARK: - Convenience Factory Methods

    /// Creates an invalid argument error for resource name validation failures.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - resourceType: The type of resource (e.g., "window", "application").
    ///   - value: The invalid resource name value.
    ///   - expectedFormat: The expected format of the resource name.
    /// - Returns: An RPCError with INVALID_RESOURCE_NAME reason.
    public static func invalidResourceName(
        message: String,
        resourceType: String,
        value: String,
        expectedFormat: String,
    ) -> RPCError {
        error(
            code: .invalidArgument,
            message: message,
            reason: ResourceNameReason.invalidFormat,
            metadata: [
                "resourceType": resourceType,
                "value": value,
                "expectedFormat": expectedFormat,
            ],
        )
    }

    /// Creates a not found error for missing resources.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - reason: The specific not found reason (e.g., `NotFoundReason.windowNotFound`).
    ///   - resourceName: The name of the resource that was not found.
    /// - Returns: An RPCError with the specified not found reason.
    public static func notFound(
        message: String,
        reason: String,
        resourceName: String,
    ) -> RPCError {
        error(
            code: .notFound,
            message: message,
            reason: reason,
            metadata: [
                "resourceName": resourceName,
            ],
        )
    }

    /// Creates a permission denied error.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - reason: The specific permission reason (e.g., `PermissionReason.accessibilityPermissionDenied`).
    ///   - resource: Optional resource that access was denied for.
    /// - Returns: An RPCError with the specified permission reason.
    public static func permissionDenied(
        message: String,
        reason: String,
        resource: String? = nil,
    ) -> RPCError {
        var metadata: [String: String] = [:]
        if let resource {
            metadata["resource"] = resource
        }
        return error(
            code: .permissionDenied,
            message: message,
            reason: reason,
            metadata: metadata,
        )
    }

    /// Creates a failed precondition error.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - reason: The specific precondition reason.
    ///   - metadata: Additional metadata about the precondition failure.
    /// - Returns: An RPCError with the specified precondition reason.
    public static func failedPrecondition(
        message: String,
        reason: String,
        metadata: [String: String] = [:],
    ) -> RPCError {
        error(
            code: .failedPrecondition,
            message: message,
            reason: reason,
            metadata: metadata,
        )
    }

    /// Creates an internal error.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - reason: The specific internal error reason.
    ///   - metadata: Additional metadata about the internal error.
    /// - Returns: An RPCError with the specified internal reason.
    public static func internalError(
        message: String,
        reason: String,
        metadata: [String: String] = [:],
    ) -> RPCError {
        error(
            code: .internalError,
            message: message,
            reason: reason,
            metadata: metadata,
        )
    }

    /// Creates a validation error for invalid field values.
    ///
    /// - Parameters:
    ///   - message: Human-readable error message.
    ///   - reason: The specific validation reason.
    ///   - field: The field that failed validation.
    ///   - value: Optional string representation of the invalid value.
    /// - Returns: An RPCError with the specified validation reason.
    public static func validationError(
        message: String,
        reason: String,
        field: String,
        value: String? = nil,
    ) -> RPCError {
        var metadata: [String: String] = ["field": field]
        if let value {
            metadata["value"] = value
        }
        return error(
            code: .invalidArgument,
            message: message,
            reason: reason,
            metadata: metadata,
        )
    }
}
