import GRPCCore

/// Validates protobuf intent while the request is still raw wire bytes.
///
/// SwiftProtobuf intentionally omits explicitly encoded scalar defaults during
/// traversal and drops unknown fields inside map entries. This transport runs
/// before generated deserialization so those public request bytes cannot be
/// mistaken for absent client intent.
struct PublicRequestValidatingServerTransport<Base: ServerTransport>: ServerTransport {
    typealias Bytes = Base.Bytes

    let base: Base

    func configure(context: GRPCServerContext) {
        base.configure(context: context)
    }

    func listen(
        streamHandler: @escaping @Sendable (
            _ stream: RPCStream<Inbound, Outbound>,
            _ context: ServerContext,
        ) async -> Void,
    ) async throws {
        try await base.listen { stream, context in
            let descriptor = stream.descriptor
            let validatedInbound = stream.inbound.map { part in
                guard case let .message(bytes) = part,
                      PublicRequestValidationPolicy.validatedServices.contains(
                          descriptor.service.fullyQualifiedService,
                      )
                else {
                    return part
                }

                let policy = try PublicRequestValidationPolicy.descriptorPolicy.get()
                guard let messageName = policy.inputMessage(
                    methodName: descriptor.fullyQualifiedMethod,
                ) else {
                    throw RPCError(
                        code: .internalError,
                        message: "public request descriptor policy is missing \(descriptor.fullyQualifiedMethod)",
                    )
                }
                try bytes.withUnsafeBytes { buffer in
                    try PublicRequestWireValidator.validate(
                        buffer,
                        messageName: messageName,
                        policy: policy,
                    )
                }
                return part
            }
            await streamHandler(
                RPCStream(
                    descriptor: descriptor,
                    inbound: RPCAsyncSequence(wrapping: validatedInbound),
                    outbound: stream.outbound,
                ),
                context,
            )
        }
    }

    func beginGracefulShutdown() {
        base.beginGracefulShutdown()
    }
}

func productionServerTransport<Base: ServerTransport>(
    _ base: Base,
) -> PublicRequestValidatingServerTransport<Base> {
    PublicRequestValidatingServerTransport(base: base)
}

private enum PublicRequestWireValidator {
    private static let maximumDepth = 64
    private static let maximumFieldNumber = (1 << 29) - 1

    private final class MessageState {
        var seenOneofFields: [Int: Int] = [:]
        var mergedMessageFields: [Int: MessageState] = [:]
    }

    static func validate(
        _ buffer: UnsafeRawBufferPointer,
        messageName: String,
        policy: PublicRequestDescriptorPolicy,
    ) throws {
        try validate(
            buffer,
            messageName: messageName,
            path: [],
            depth: 0,
            policy: policy,
            state: MessageState(),
        )
    }

    private static func validate(
        _ buffer: UnsafeRawBufferPointer,
        messageName: String,
        path: [String],
        depth: Int,
        policy: PublicRequestDescriptorPolicy,
        state: MessageState,
    ) throws {
        guard depth <= maximumDepth else {
            throw malformedWireError()
        }
        guard let message = policy.message(messageName) else {
            throw RPCError(
                code: .internalError,
                message: "public request descriptor policy is missing \(messageName)",
            )
        }

        var index = 0
        while index < buffer.count {
            let tag = try readVarint(buffer, index: &index)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber > 0, fieldNumber <= maximumFieldNumber else {
                throw malformedWireError()
            }
            guard let field = message.fields[fieldNumber] else {
                throw RPCErrorHelpers.validationError(
                    message: "request contains unknown fields",
                    reason: "UNKNOWN_FIELD",
                    field: "request",
                )
            }
            guard !field.isOutputOnly else {
                throw RPCErrorHelpers.validationError(
                    message: "request sets an output-only field",
                    reason: "OUTPUT_ONLY_FIELD",
                    field: (path + [field.name]).joined(separator: "."),
                )
            }
            guard permits(wireType: wireType, field: field) else {
                throw malformedWireError()
            }
            if let oneofIndex = field.oneofIndex {
                guard let oneofName = message.realOneofs[oneofIndex] else {
                    throw RPCError(
                        code: .internalError,
                        message: "public request descriptor policy is missing oneof \(oneofIndex) for \(messageName)",
                    )
                }
                if let previousFieldNumber = state.seenOneofFields[oneofIndex],
                   previousFieldNumber != fieldNumber
                {
                    throw RPCErrorHelpers.validationError(
                        message: "request sets conflicting oneof fields",
                        reason: "CONFLICTING_ONEOF",
                        field: (path + [oneofName]).joined(separator: "."),
                    )
                }
                state.seenOneofFields[oneofIndex] = fieldNumber
            }

            switch wireType {
            case 0:
                _ = try readVarint(buffer, index: &index)
            case 1:
                try advance(8, buffer: buffer, index: &index)
            case 2:
                let length = try readLength(buffer, index: &index)
                let end = try boundedEnd(length: length, buffer: buffer, index: index)
                let payload = UnsafeRawBufferPointer(rebasing: buffer[index ..< end])
                if let nestedMessageName = field.messageName {
                    let nestedState: MessageState
                    if field.isRepeated {
                        nestedState = MessageState()
                    } else if let existing = state.mergedMessageFields[fieldNumber] {
                        nestedState = existing
                    } else {
                        nestedState = MessageState()
                        state.mergedMessageFields[fieldNumber] = nestedState
                    }
                    try validate(
                        payload,
                        messageName: nestedMessageName,
                        path: path + [field.name],
                        depth: depth + 1,
                        policy: policy,
                        state: nestedState,
                    )
                } else if field.isRepeated, field.isPackable {
                    try validatePacked(payload, kind: field.wireKind)
                }
                index = end
            case 5:
                try advance(4, buffer: buffer, index: &index)
            default:
                throw malformedWireError()
            }
        }
    }

    private static func permits(
        wireType: Int,
        field: PublicRequestDescriptorPolicy.Field,
    ) -> Bool {
        if wireType == nativeWireType(field.wireKind) {
            return true
        }
        return field.isRepeated && field.isPackable && wireType == 2
    }

    private static func nativeWireType(
        _ kind: PublicRequestDescriptorPolicy.WireKind,
    ) -> Int {
        switch kind {
        case .varint: 0
        case .fixed64: 1
        case .lengthDelimited: 2
        case .group: 3
        case .fixed32: 5
        }
    }

    private static func validatePacked(
        _ buffer: UnsafeRawBufferPointer,
        kind: PublicRequestDescriptorPolicy.WireKind,
    ) throws {
        switch kind {
        case .varint:
            var index = 0
            while index < buffer.count {
                _ = try readVarint(buffer, index: &index)
            }
        case .fixed64:
            guard buffer.count.isMultiple(of: 8) else { throw malformedWireError() }
        case .fixed32:
            guard buffer.count.isMultiple(of: 4) else { throw malformedWireError() }
        case .lengthDelimited, .group:
            throw malformedWireError()
        }
    }

    private static func readLength(
        _ buffer: UnsafeRawBufferPointer,
        index: inout Int,
    ) throws -> Int {
        let value = try readVarint(buffer, index: &index)
        guard value <= UInt64(Int.max) else { throw malformedWireError() }
        return Int(value)
    }

    private static func boundedEnd(
        length: Int,
        buffer: UnsafeRawBufferPointer,
        index: Int,
    ) throws -> Int {
        let (end, overflow) = index.addingReportingOverflow(length)
        guard !overflow, end <= buffer.count else { throw malformedWireError() }
        return end
    }

    private static func advance(
        _ count: Int,
        buffer: UnsafeRawBufferPointer,
        index: inout Int,
    ) throws {
        index = try boundedEnd(length: count, buffer: buffer, index: index)
    }

    private static func readVarint(
        _ buffer: UnsafeRawBufferPointer,
        index: inout Int,
    ) throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0 ..< 10 {
            guard index < buffer.count else { throw malformedWireError() }
            let byte = buffer[index]
            index += 1
            if byteIndex == 9, byte > 1 {
                throw malformedWireError()
            }
            value |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw malformedWireError()
    }

    private static func malformedWireError() -> RPCError {
        RPCErrorHelpers.validationError(
            message: "request contains malformed protobuf wire data",
            reason: "MALFORMED_PROTOBUF",
            field: "request",
        )
    }
}
