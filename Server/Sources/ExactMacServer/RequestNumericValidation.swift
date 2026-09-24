import ExactMacProto
import GRPCCore
import SwiftProtobuf

enum RequestNumericValidation {
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    /// Largest whole-second value whose nanosecond representation fits UInt64.
    static let maximumTimeoutWholeSeconds = UInt64.max / nanosecondsPerSecond
    static let maximumTimeoutNanoseconds = maximumTimeoutWholeSeconds * nanosecondsPerSecond
    static let maximumTimeoutSeconds = Double(maximumTimeoutWholeSeconds)

    static func optionalTimeout(
        _ value: Double,
        default defaultValue: Double,
        field: String = "timeout",
    ) throws -> Double {
        try optionalPositiveSeconds(
            value,
            default: defaultValue,
            minimum: .leastNonzeroMagnitude,
            maximum: maximumTimeoutSeconds,
            field: field,
        )
    }

    static func optionalPollInterval(
        _ value: Double,
        default defaultValue: Double,
        field: String = "poll_interval",
    ) throws -> Double {
        try optionalPositiveSeconds(
            value,
            default: defaultValue,
            minimum: 0.1,
            maximum: 60,
            field: field,
        )
    }

    static func pageSize(
        _ value: Int32,
        default defaultValue: Int = 100,
        maximum: Int = 1000,
        field: String = "page_size",
    ) throws -> Int {
        precondition(defaultValue > 0 && defaultValue <= maximum)
        guard value >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) must not be negative",
                reason: "INVALID_PAGE_SIZE",
                field: field,
                value: String(value),
            )
        }
        return value == 0 ? defaultValue : min(Int(value), maximum)
    }

    static func skip(
        _ value: Int32,
        field: String = "skip",
    ) throws -> Int {
        guard value >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) must not be negative",
                reason: "INVALID_SKIP",
                field: field,
                value: String(value),
            )
        }
        return Int(value)
    }

    static func imageQuality(
        _ value: Int32,
        default defaultValue: Int32 = 85,
        field: String = "quality",
    ) throws -> Int32 {
        precondition((1 ... 100).contains(defaultValue))
        guard value == 0 || (1 ... 100).contains(value) else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) must be zero for the default or between 1 and 100",
                reason: "OUT_OF_RANGE",
                field: field,
                value: String(value),
            )
        }
        return value == 0 ? defaultValue : value
    }

    static func imageEncoding(
        format requestedFormat: Exactmac_V1_ImageFormat,
        quality requestedQuality: Int32,
    ) throws -> (format: Exactmac_V1_ImageFormat, quality: Int32) {
        // Validate the numeric range FIRST. An out-of-range quality (e.g. 101)
        // is an OUT_OF_RANGE error regardless of format, per Google AIP: a
        // value that parses but falls outside its valid bounds yields
        // OUT_OF_RANGE, while structurally/semantically malformed input
        // (quality set on a lossless format) yields INVALID_ARGUMENT. Checking
        // format-compatibility first misclassified 101-on-PNG as
        // INVALID_ARGUMENT.
        try validateQualityRange(requestedQuality)
        switch requestedFormat {
        case .unspecified, .png:
            guard requestedQuality == 0 else {
                throw invalidLosslessImageQuality(requestedQuality)
            }
            return (.png, 0)
        case .tiff:
            guard requestedQuality == 0 else {
                throw invalidLosslessImageQuality(requestedQuality)
            }
            return (.tiff, 0)
        case .jpeg:
            return try (.jpeg, imageQuality(requestedQuality))
        case .UNRECOGNIZED:
            throw RPCErrorHelpers.validationError(
                message: "format is not supported",
                reason: "INVALID_ENUM_VALUE",
                field: "format",
                value: String(requestedFormat.rawValue),
            )
        }
    }

    /// Validates that a quality value is either the sentinel zero (use the
    /// default) or within the JPEG quality bounds [1, 100]. Rejects anything
    /// else as OUT_OF_RANGE. Does NOT substitute the default — that is the
    /// caller's responsibility.
    private static func validateQualityRange(_ value: Int32) throws {
        guard value == 0 || (1 ... 100).contains(value) else {
            throw RPCErrorHelpers.validationError(
                message: "quality must be zero for the default or between 1 and 100",
                reason: "OUT_OF_RANGE",
                field: "quality",
                value: String(value),
            )
        }
    }

    private static func invalidLosslessImageQuality(_ value: Int32) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "quality must be zero unless format is JPEG",
            reason: "INVALID_ARGUMENT",
            field: "quality",
            value: String(value),
        )
    }

    static func protobufTimeoutNanoseconds(
        _ duration: Google_Protobuf_Duration,
        allowZero: Bool,
        maximumNanoseconds: UInt64 = UInt64.max,
        field: String = "timeout",
    ) throws -> UInt64 {
        guard duration.seconds >= 0,
              duration.nanos >= 0,
              duration.nanos < Int32(nanosecondsPerSecond)
        else {
            throw invalidProtobufTimeout(field: field, allowZero: allowZero)
        }

        let seconds = UInt64(duration.seconds)
        let (wholeNanoseconds, multiplicationOverflow) = seconds.multipliedReportingOverflow(
            by: nanosecondsPerSecond,
        )
        let (totalNanoseconds, additionOverflow) = wholeNanoseconds.addingReportingOverflow(
            UInt64(duration.nanos),
        )
        guard !multiplicationOverflow,
              !additionOverflow,
              totalNanoseconds <= maximumNanoseconds,
              allowZero || totalNanoseconds > 0
        else {
            throw invalidProtobufTimeout(field: field, allowZero: allowZero)
        }
        return totalNanoseconds
    }

    static func positiveProtobufTimeoutSeconds(
        _ duration: Google_Protobuf_Duration,
        field: String = "timeout",
    ) throws -> Double {
        let nanoseconds = try protobufTimeoutNanoseconds(
            duration,
            allowZero: false,
            maximumNanoseconds: maximumTimeoutNanoseconds,
            field: field,
        )
        return Double(nanoseconds) / Double(nanosecondsPerSecond)
    }

    private static func optionalPositiveSeconds(
        _ value: Double,
        default defaultValue: Double,
        minimum: Double,
        maximum: Double,
        field: String,
    ) throws -> Double {
        let resolved = value == 0 ? defaultValue : value
        guard resolved.isFinite,
              resolved >= minimum,
              resolved <= maximum
        else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) is outside the supported range",
                reason: "OUT_OF_RANGE",
                field: field,
                value: String(value),
            )
        }
        return resolved
    }

    private static func invalidProtobufTimeout(
        field: String,
        allowZero: Bool,
    ) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "\(field) must be a canonical \(allowZero ? "nonnegative" : "positive") protobuf Duration within the supported range",
            reason: "INVALID_TIMEOUT",
            field: field,
        )
    }
}
