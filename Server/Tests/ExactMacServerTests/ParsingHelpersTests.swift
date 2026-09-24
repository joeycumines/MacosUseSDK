import ExactMacProto
@testable import ExactMacServer
import GRPCCore
import SwiftProtobuf
import XCTest

/// Tests for ParsingHelpers utility functions.
final class ParsingHelpersTests: XCTestCase {
    // MARK: - parsePID Tests

    func testParsePIDValidFormat() throws {
        let pid = try ParsingHelpers.parsePID(fromName: "applications/12345")
        XCTAssertEqual(pid, 12345)
    }

    func testParsePIDRejectsWindowSuffix() {
        XCTAssertThrowsError(
            try ParsingHelpers.parsePID(fromName: "applications/12345/windows/67890"),
        )
    }

    func testParsePIDRejectsElementSuffix() {
        XCTAssertThrowsError(
            try ParsingHelpers.parsePID(fromName: "applications/789/elements/abc123"),
        )
    }

    func testParsePIDRejectsZero() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "applications/0"))
    }

    func testParsePIDMaxInt32() throws {
        // Maximum valid pid_t on most systems
        let pid = try ParsingHelpers.parsePID(fromName: "applications/2147483647")
        XCTAssertEqual(pid, 2_147_483_647)
    }

    func testParsePIDInvalidFormatMissingPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "12345")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDInvalidFormatWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "windows/12345")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDInvalidFormatNotANumber() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "applications/notanumber")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDInvalidFormatEmpty() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDInvalidFormatOnlyPrefix() {
        // "applications/" with no PID should throw
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "applications/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDInvalidFormatNegativePID() {
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "applications/-1"))
    }

    func testParsePIDInvalidFormatDecimalPID() {
        // Decimal PIDs should fail
        XCTAssertThrowsError(try ParsingHelpers.parsePID(fromName: "applications/123.45")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParsePIDErrorMessageContainsOriginalName() {
        do {
            _ = try ParsingHelpers.parsePID(fromName: "invalid/format/name")
            XCTFail("Expected to throw")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.contains("invalid/format/name"))
        } catch {
            XCTFail("Expected RPCError, got \(error)")
        }
    }

    // MARK: - parseOptionalPID Tests (AIP-159 Wildcard)

    func testParseOptionalPIDValidFormat() throws {
        let pid = try ParsingHelpers.parseOptionalPID(fromName: "applications/12345")
        XCTAssertEqual(pid, 12345)
    }

    func testParseOptionalPIDRejectsWindowSuffix() {
        XCTAssertThrowsError(
            try ParsingHelpers.parseOptionalPID(fromName: "applications/12345/windows/67890"),
        )
    }

    func testParseOptionalPIDEmptyStringReturnsNil() throws {
        let pid = try ParsingHelpers.parseOptionalPID(fromName: "")
        XCTAssertNil(pid, "Empty string should return nil (desktop-level scope)")
    }

    func testParseOptionalPIDWildcardReturnsNil() throws {
        // AIP-159: "applications/-" means "all applications" (wildcard parent)
        let pid = try ParsingHelpers.parseOptionalPID(fromName: "applications/-")
        XCTAssertNil(pid, "Wildcard 'applications/-' should return nil")
    }

    func testParseOptionalPIDRejectsWildcardWithSuffix() {
        XCTAssertThrowsError(
            try ParsingHelpers.parseOptionalPID(fromName: "applications/-/inputs/xyz"),
        )
    }

    func testParseOptionalPIDInvalidPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseOptionalPID(fromName: "windows/12345")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseOptionalPIDInvalidNotANumber() {
        XCTAssertThrowsError(try ParsingHelpers.parseOptionalPID(fromName: "applications/notanumber")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseOptionalPIDInvalidOnlyPrefix() {
        // "applications/" with no PID should throw
        XCTAssertThrowsError(try ParsingHelpers.parseOptionalPID(fromName: "applications/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseOptionalPIDInvalidJustPrefix() {
        // "applications" with no slash should throw
        XCTAssertThrowsError(try ParsingHelpers.parseOptionalPID(fromName: "applications")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - Page Token Encoding Tests (AIP-158)

    func testQueryBoundPageTokenRoundTripsAndRejectsDifferentQuery() throws {
        let originalQuery = ParsingHelpers.pageTokenQuery(
            method: "ListElements",
            parameters: [("parent", "applications/123")],
        )
        let differentQuery = ParsingHelpers.pageTokenQuery(
            method: "ListElements",
            parameters: [("parent", "applications/456")],
        )
        let token = ParsingHelpers.encodePageToken(
            offset: 50,
            queryBinding: originalQuery,
        )

        XCTAssertEqual(
            try ParsingHelpers.decodePageToken(
                token,
                queryBinding: originalQuery,
            ),
            50,
        )
        XCTAssertThrowsError(
            try ParsingHelpers.decodePageToken(
                token,
                queryBinding: differentQuery,
            ),
        ) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testQueryBoundPageTokenRejectsMutationAndLegacyPlaintextFormats() throws {
        let query = ParsingHelpers.pageTokenQuery(method: "ListDisplays")
        let token = ParsingHelpers.encodePageToken(offset: 50, queryBinding: query)
        var mutatedBytes = Array(token.utf8)
        mutatedBytes[mutatedBytes.count / 2] ^= 1
        let mutated = try XCTUnwrap(String(bytes: mutatedBytes, encoding: .utf8))
        let invalidTokens = [
            mutated,
            Data("offset:50".utf8).base64EncodedString(),
            "not!valid@base64",
            "",
            Data("index:50".utf8).base64EncodedString(),
            Data("offset:-1".utf8).base64EncodedString(),
            Data("offset:abc".utf8).base64EncodedString(),
            Data("offset50".utf8).base64EncodedString(),
            token + "=",
            token + "==",
        ]
        for invalidToken in invalidTokens {
            XCTAssertThrowsError(
                try ParsingHelpers.decodePageToken(invalidToken, queryBinding: query),
            ) { error in
                XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
            }
        }
    }

    func testPageTokenDoesNotExposeItsPayload() throws {
        let query = ParsingHelpers.pageTokenQuery(
            method: "ListApplications",
            parameters: [("parent", "applications/123")],
        )
        let token = ParsingHelpers.encodePageToken(offset: 50, queryBinding: query)

        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))

        var normalized = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        let decoded = try XCTUnwrap(Data(base64Encoded: normalized))
        let decodedText = String(data: decoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decodedText.contains("v2:"))
        XCTAssertFalse(decodedText.contains(query))
        XCTAssertFalse(decodedText.contains("offset"))
    }

    func testPageCursorAddsSkipToTokenPosition() throws {
        let query = ParsingHelpers.pageTokenQuery(method: "ListApplications")
        let token = ParsingHelpers.encodePageToken(offset: 50, queryBinding: query)

        let cursor = try ParsingHelpers.pageCursor(
            token: token,
            skip: 30,
            queryBinding: query,
        )
        XCTAssertEqual(cursor.tokenOffset, 50)
        XCTAssertEqual(cursor.offset, 80)
        XCTAssertEqual(
            try ParsingHelpers.pageRange(cursor: cursor, pageSize: 2, totalCount: 100),
            80 ..< 82,
        )
    }

    func testPageCursorAppliesSkipToAnUnpagedRequest() throws {
        let query = ParsingHelpers.pageTokenQuery(method: "ListApplications")
        let cursor = try ParsingHelpers.pageCursor(token: "", skip: 30, queryBinding: query)

        XCTAssertEqual(cursor.tokenOffset, 0)
        XCTAssertEqual(cursor.offset, 30)
        XCTAssertEqual(
            try ParsingHelpers.pageRange(cursor: cursor, pageSize: 2, totalCount: 100),
            30 ..< 32,
        )
    }

    func testPageCursorAllowsOutOfRangeSkipButRejectsStaleToken() throws {
        let query = ParsingHelpers.pageTokenQuery(method: "ListApplications")
        let skipped = try ParsingHelpers.pageCursor(
            token: "",
            skip: Int(Int32.max),
            queryBinding: query,
        )
        XCTAssertEqual(
            try ParsingHelpers.pageRange(cursor: skipped, pageSize: 2, totalCount: 5),
            5 ..< 5,
        )

        let staleToken = ParsingHelpers.encodePageToken(offset: 6, queryBinding: query)
        let stale = try ParsingHelpers.pageCursor(
            token: staleToken,
            skip: 0,
            queryBinding: query,
        )
        XCTAssertThrowsError(
            try ParsingHelpers.pageRange(cursor: stale, pageSize: 1, totalCount: 5),
        ) { error in
            XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
        }
    }

    func testPageCursorRejectsTokenOffsetPlusSkipOverflow() throws {
        let query = ParsingHelpers.pageTokenQuery(method: "ListApplications")
        let token = ParsingHelpers.encodePageToken(offset: Int.max, queryBinding: query)

        XCTAssertThrowsError(
            try ParsingHelpers.pageCursor(token: token, skip: 1, queryBinding: query),
        ) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testPageTokenQueryLengthPrefixesPreventDelimiterCollisions() {
        let first = ParsingHelpers.pageTokenQuery(
            method: "ListInputs",
            parameters: [("parent", "a|filter=b"), ("filter", "c")],
        )
        let second = ParsingHelpers.pageTokenQuery(
            method: "ListInputs",
            parameters: [("parent", "a"), ("filter", "b|filter=c")],
        )
        XCTAssertNotEqual(first, second)
    }

    func testSelectorQueryIdentitySortsAttributeMapKeys() throws {
        let first = Exactmac_Type_ElementSelector.with {
            $0.attributes = Exactmac_Type_AttributeSelector.with {
                $0.attributes = ["z": "last", "a": "first", "m": "middle"]
            }
        }
        let second = Exactmac_Type_ElementSelector.with {
            $0.attributes = Exactmac_Type_AttributeSelector.with {
                $0.attributes = ["m": "middle", "z": "last", "a": "first"]
            }
        }
        let different = Exactmac_Type_ElementSelector.with {
            $0.attributes = Exactmac_Type_AttributeSelector.with {
                $0.attributes = ["z": "last", "a": "changed", "m": "middle"]
            }
        }

        XCTAssertEqual(
            ParsingHelpers.selectorQueryIdentity(first),
            ParsingHelpers.selectorQueryIdentity(second),
        )
        let token = ParsingHelpers.encodePageToken(
            offset: 1,
            queryBinding: ParsingHelpers.selectorQueryIdentity(first),
        )
        let cursor = try ParsingHelpers.pageCursor(
            token: token,
            skip: 0,
            queryBinding: ParsingHelpers.selectorQueryIdentity(second),
        )
        XCTAssertEqual(cursor.offset, 1)
        XCTAssertNotEqual(
            ParsingHelpers.selectorQueryIdentity(first),
            ParsingHelpers.selectorQueryIdentity(different),
        )
    }

    func testSelectorQueryIdentityPreservesPositionPresence() {
        let absent = Exactmac_Type_ElementSelector.with {
            $0.position = Exactmac_Type_PositionSelector.with { $0.tolerance = 3 }
        }
        let present = Exactmac_Type_ElementSelector.with {
            $0.position = Exactmac_Type_PositionSelector.with {
                $0.x = 0
                $0.tolerance = 3
            }
        }

        XCTAssertNotEqual(
            ParsingHelpers.selectorQueryIdentity(absent),
            ParsingHelpers.selectorQueryIdentity(present),
        )
    }

    func testPageRangeRejectsOffsetOutsideCurrentCollection() {
        XCTAssertThrowsError(
            try ParsingHelpers.pageRange(offset: 6, pageSize: 1, totalCount: 5),
        ) { error in
            XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
        }
    }

    // MARK: - parseApplicationName Tests

    func testParseApplicationNameValid() throws {
        let resource = try ParsingHelpers.parseApplicationName("applications/123")
        XCTAssertEqual(resource.pid, 123)
    }

    func testParseApplicationNameValidMinimumPID() throws {
        let resource = try ParsingHelpers.parseApplicationName("applications/1")
        XCTAssertEqual(resource.pid, 1)
    }

    func testParseApplicationNameInvalidEmptyString() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidMissingPID() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("applications")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidEmptyPID() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("applications/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidNonNumericPID() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("applications/abc")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidNegativePID() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("applications/-1")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("apps/123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseApplicationNameInvalidExtraSegments() {
        XCTAssertThrowsError(try ParsingHelpers.parseApplicationName("applications/123/extra")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseWindowName Tests

    func testParseWindowNameValid() throws {
        let resource = try ParsingHelpers.parseWindowName("applications/123/windows/456")
        XCTAssertEqual(resource.pid, 123)
        XCTAssertEqual(resource.windowId, 456)
    }

    func testParseWindowNameInvalidMissingWindowsSegment() {
        XCTAssertThrowsError(try ParsingHelpers.parseWindowName("applications/123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseWindowNameInvalidMissingWindowId() {
        XCTAssertThrowsError(try ParsingHelpers.parseWindowName("applications/123/windows")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseWindowNameInvalidNonNumericPID() {
        XCTAssertThrowsError(try ParsingHelpers.parseWindowName("applications/abc/windows/456")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseWindowNameInvalidNonNumericWindowId() {
        XCTAssertThrowsError(try ParsingHelpers.parseWindowName("applications/123/windows/abc")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseWindowNameInvalidMissingApplicationsPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseWindowName("windows/456")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseObservationName Tests

    func testParseObservationNameValid() throws {
        let resource = try ParsingHelpers.parseObservationName("applications/123/observations/obs1")
        XCTAssertEqual(resource.pid, 123)
        XCTAssertEqual(resource.observationId, "obs1")
    }

    func testParseObservationNameInvalidMissingObservationsSegment() {
        XCTAssertThrowsError(try ParsingHelpers.parseObservationName("applications/123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseObservationNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseObservationName("applications/123/observations/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseElementName Tests

    func testParseElementNameValid() throws {
        let resource = try ParsingHelpers.parseElementName("applications/123/elements/elem1")
        XCTAssertEqual(resource.pid, 123)
        XCTAssertEqual(resource.elementId, "elem1")
    }

    func testParseElementNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseElementName("applications/123/elements/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseSessionName Tests

    func testParseSessionNameValid() throws {
        let resource = try ParsingHelpers.parseSessionName("sessions/s123")
        XCTAssertEqual(resource.sessionId, "s123")
    }

    func testParseSessionNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseSessionName("sessions/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseSessionNameInvalidEmptyString() {
        XCTAssertThrowsError(try ParsingHelpers.parseSessionName("")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseSessionNameInvalidWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseSessionName("session/s123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseMacroName Tests

    func testParseMacroNameValid() throws {
        let resource = try ParsingHelpers.parseMacroName("macros/m123")
        XCTAssertEqual(resource.macroId, "m123")
    }

    func testParseMacroNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseMacroName("macros/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseMacroNameInvalidWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseMacroName("macro/m123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseOperationName Tests

    func testParseOperationNameValid() throws {
        let resource = try ParsingHelpers.parseOperationName("operations/op123")
        XCTAssertEqual(resource.operationId, "op123")
    }

    func testParseOperationNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseOperationName("operations/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseOperationNameInvalidWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseOperationName("operation/op123")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - parseDisplayName Tests

    func testParseDisplayNameValid() throws {
        let resource = try ParsingHelpers.parseDisplayName("displays/12345")
        XCTAssertEqual(resource.displayID, 12345)
    }

    func testParseDisplayNameInvalidEmptyId() {
        XCTAssertThrowsError(try ParsingHelpers.parseDisplayName("displays/")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseDisplayNameInvalidWrongPrefix() {
        XCTAssertThrowsError(try ParsingHelpers.parseDisplayName("display/12345")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testParseDisplayNameRejectsAliasesAndInvalidIdentifiers() {
        for name in [
            "displays/main",
            "displays/0",
            "displays/01",
            "/displays/1",
            "displays/1/extra",
            "displays/4294967296",
        ] {
            XCTAssertThrowsError(try ParsingHelpers.parseDisplayName(name), name) { error in
                guard let rpcError = error as? RPCError else {
                    XCTFail("Expected RPCError for \(name)")
                    return
                }
                XCTAssertEqual(rpcError.code, .invalidArgument)
            }
        }
    }

    // MARK: - FieldMask Window Tests (AIP-157)

    func testApplyFieldMaskWindowEmptyMaskReturnsAllFields() {
        // Given a full window and an empty mask
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Exactmac_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.layer = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let emptyMask = SwiftProtobuf.Google_Protobuf_FieldMask()

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: emptyMask)

        // Then all fields should be returned
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "Test Window")
        XCTAssertEqual(result.bounds.x, 100)
        XCTAssertEqual(result.bounds.y, 200)
        XCTAssertEqual(result.bounds.width, 300)
        XCTAssertEqual(result.bounds.height, 400)
        XCTAssertEqual(result.layer, 5)
        XCTAssertTrue(result.visible)
        XCTAssertEqual(result.bundleID, "com.test.app")
    }

    func testApplyFieldMaskWindowTitleOnly() {
        // Given a full window and a mask for title only
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Exactmac_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.layer = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["title"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then only name (identifier) and title should be populated
        XCTAssertEqual(result.name, "applications/123/windows/456") // identifier always included
        XCTAssertEqual(result.title, "Test Window")
        XCTAssertEqual(result.bounds.x, 0) // default (not requested)
        XCTAssertEqual(result.layer, 0) // default (not requested)
        XCTAssertFalse(result.visible) // default (not requested)
        XCTAssertEqual(result.bundleID, "") // default (not requested)
    }

    func testApplyFieldMaskWindowBoundsOnly() {
        // Given a full window and a mask for bounds only
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Exactmac_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.layer = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["bounds"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then only name (identifier) and bounds should be populated
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "") // default
        XCTAssertEqual(result.bounds.x, 100)
        XCTAssertEqual(result.bounds.y, 200)
        XCTAssertEqual(result.bounds.width, 300)
        XCTAssertEqual(result.bounds.height, 400)
        XCTAssertEqual(result.layer, 0) // default
        XCTAssertFalse(result.visible) // default
        XCTAssertEqual(result.bundleID, "") // default
    }

    func testApplyFieldMaskWindowMultipleFields() {
        // Given a full window and a mask for multiple fields
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Exactmac_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.layer = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["title", "visible", "layer"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then only name and requested fields should be populated
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "Test Window")
        XCTAssertEqual(result.bounds.x, 0) // default (not requested)
        XCTAssertEqual(result.layer, 5)
        XCTAssertTrue(result.visible)
        XCTAssertEqual(result.bundleID, "") // default (not requested)
    }

    func testValidateWindowReadMaskRejectsUnknownAndRemovedFields() {
        for paths in [
            ["title", "unknown_field"],
            ["z_index"],
        ] {
            let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
                $0.paths = paths
            }
            XCTAssertThrowsError(try ParsingHelpers.validateWindowReadMask(mask))
        }
    }

    func testApplyFieldMaskWindowNameAlwaysIncluded() {
        // Given a full window and a mask that does NOT include name
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["bundle_id"] // name not included
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then name (identifier) is ALWAYS included per AIP-157
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "") // default
        XCTAssertEqual(result.bundleID, "com.test.app")
    }

    // MARK: - FieldMask Application Tests (AIP-157)

    func testApplyFieldMaskApplicationEmptyMaskReturnsAllFields() {
        // Given a full application and an empty mask
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let emptyMask = SwiftProtobuf.Google_Protobuf_FieldMask()

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: emptyMask)

        // Then all fields should be returned
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 123)
        XCTAssertEqual(result.displayName, "Test App")
    }

    func testApplyFieldMaskApplicationPidOnly() {
        // Given a full application and a mask for pid only
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["pid"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then only name (identifier) and pid should be populated
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 123)
        XCTAssertEqual(result.displayName, "") // default (not requested)
    }

    func testApplyFieldMaskApplicationDisplayNameOnly() {
        // Given a full application and a mask for display_name only
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["display_name"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then only name (identifier) and display_name should be populated
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 0) // default (not requested)
        XCTAssertEqual(result.displayName, "Test App")
    }

    func testApplyFieldMaskApplicationAllFields() {
        // Given a full application and a mask for all fields
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["name", "pid", "display_name"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then all requested fields should be populated
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 123)
        XCTAssertEqual(result.displayName, "Test App")
    }

    func testApplyFieldMaskApplicationNameAlwaysIncluded() {
        // Given a full application and a mask that does NOT include name
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["display_name"] // name not included
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then name (identifier) is ALWAYS included per AIP-157
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 0) // default
        XCTAssertEqual(result.displayName, "Test App")
    }

    func testApplyFieldMaskApplicationUnknownFieldIgnored() {
        // Given a full application and a mask with an unknown field
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "Test App"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["pid", "bundle_id", "nonexistent"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then unknown fields are silently ignored
        XCTAssertEqual(result.name, "applications/123")
        XCTAssertEqual(result.pid, 123)
        XCTAssertEqual(result.displayName, "") // default
    }

    // MARK: - FieldMask Wildcard Tests (AIP-157)

    func testApplyFieldMaskWindowWildcardReturnsAllFields() {
        // Given a full window and a mask with "*"
        let window = Exactmac_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Exactmac_V1_Bounds.with {
                $0.x = 10
                $0.y = 20
                $0.width = 100
                $0.height = 200
            }
            $0.layer = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["*"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then all fields are returned per AIP-157 wildcard support
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "Test Window")
        XCTAssertEqual(result.bounds.x, 10)
        XCTAssertEqual(result.layer, 5)
        XCTAssertEqual(result.visible, true)
        XCTAssertEqual(result.bundleID, "com.test.app")
    }

    func testApplyFieldMaskApplicationWildcardReturnsAllFields() {
        // Given a full application and a mask with "*"
        let app = Exactmac_V1_Application.with {
            $0.name = "applications/789"
            $0.pid = 789
            $0.displayName = "Wildcard Test"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["*"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: app, readMask: mask)

        // Then all fields are returned per AIP-157 wildcard support
        XCTAssertEqual(result.name, "applications/789")
        XCTAssertEqual(result.pid, 789)
        XCTAssertEqual(result.displayName, "Wildcard Test")
    }
}
