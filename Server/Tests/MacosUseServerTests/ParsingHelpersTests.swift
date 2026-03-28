import GRPCCore
import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Tests for ParsingHelpers utility functions.
final class ParsingHelpersTests: XCTestCase {
    // MARK: - parsePID Tests

    func testParsePIDValidFormat() throws {
        let pid = try ParsingHelpers.parsePID(fromName: "applications/12345")
        XCTAssertEqual(pid, 12345)
    }

    func testParsePIDWithWindowSuffix() throws {
        // Should successfully extract PID even when there are more components (window suffix)
        let pid = try ParsingHelpers.parsePID(fromName: "applications/12345/windows/67890")
        XCTAssertEqual(pid, 12345)
    }

    func testParsePIDWithElementSuffix() throws {
        // Should successfully extract PID with element suffix
        let pid = try ParsingHelpers.parsePID(fromName: "applications/789/elements/abc123")
        XCTAssertEqual(pid, 789)
    }

    func testParsePIDZero() throws {
        // Zero is a valid PID (though typically reserved)
        let pid = try ParsingHelpers.parsePID(fromName: "applications/0")
        XCTAssertEqual(pid, 0)
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

    func testParsePIDInvalidFormatNegativePID() throws {
        // Note: Negative PIDs parse successfully because Int32 accepts negative values.
        // In practice, valid macOS PIDs are positive, but the parser doesn't enforce this.
        // This test documents the current behavior - it returns the negative value.
        let pid = try ParsingHelpers.parsePID(fromName: "applications/-1")
        XCTAssertEqual(pid, -1)
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

    func testParseOptionalPIDWithWindowSuffix() throws {
        let pid = try ParsingHelpers.parseOptionalPID(fromName: "applications/12345/windows/67890")
        XCTAssertEqual(pid, 12345)
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

    func testParseOptionalPIDWildcardWithSuffix() throws {
        // "applications/-/inputs/xyz" should still recognize wildcard
        let pid = try ParsingHelpers.parseOptionalPID(fromName: "applications/-/inputs/xyz")
        XCTAssertNil(pid, "Wildcard 'applications/-' with suffix should return nil")
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

    func testEncodePageTokenZero() {
        let token = ParsingHelpers.encodePageToken(offset: 0)
        XCTAssertFalse(token.isEmpty)
        // Token should be base64
        XCTAssertNotNil(Data(base64Encoded: token))
    }

    func testEncodePageTokenPositive() {
        let token = ParsingHelpers.encodePageToken(offset: 100)
        XCTAssertFalse(token.isEmpty)
    }

    func testDecodePageTokenRoundTrip() throws {
        // Test round-trip encoding/decoding
        for offset in [0, 1, 10, 100, 1000, 99999] {
            let token = ParsingHelpers.encodePageToken(offset: offset)
            let decoded = try ParsingHelpers.decodePageToken(token)
            XCTAssertEqual(decoded, offset, "Round-trip failed for offset \(offset)")
        }
    }

    func testDecodePageTokenValidToken() throws {
        // Manually construct a valid token: "offset:50" -> base64
        let validToken = Data("offset:50".utf8).base64EncodedString()
        let decoded = try ParsingHelpers.decodePageToken(validToken)
        XCTAssertEqual(decoded, 50)
    }

    func testDecodePageTokenInvalidBase64() {
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken("not!valid@base64")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testDecodePageTokenEmptyString() {
        // Empty string should fail (not valid base64)
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken("")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testDecodePageTokenWrongPrefix() {
        // Valid base64 but wrong prefix (not "offset:")
        let wrongPrefixToken = Data("index:50".utf8).base64EncodedString()
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken(wrongPrefixToken)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testDecodePageTokenNegativeOffset() {
        // Negative offsets should be rejected
        let negativeToken = Data("offset:-1".utf8).base64EncodedString()
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken(negativeToken)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testDecodePageTokenNotANumber() {
        // "offset:abc" should fail
        let notANumberToken = Data("offset:abc".utf8).base64EncodedString()
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken(notANumberToken)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    func testDecodePageTokenMalformedNoColon() {
        // "offset50" (no colon) should fail
        let malformedToken = Data("offset50".utf8).base64EncodedString()
        XCTAssertThrowsError(try ParsingHelpers.decodePageToken(malformedToken)) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
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
        let resource = try ParsingHelpers.parseDisplayName("displays/main")
        XCTAssertEqual(resource.displayName, "main")
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
        XCTAssertThrowsError(try ParsingHelpers.parseDisplayName("display/main")) { error in
            guard let rpcError = error as? RPCError else {
                XCTFail("Expected RPCError")
                return
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
    }

    // MARK: - FieldMask Window Tests (AIP-157)

    func testApplyFieldMaskWindowEmptyMaskReturnsAllFields() {
        // Given a full window and an empty mask
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.zIndex = 5
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
        XCTAssertEqual(result.zIndex, 5)
        XCTAssertTrue(result.visible)
        XCTAssertEqual(result.bundleID, "com.test.app")
    }

    func testApplyFieldMaskWindowTitleOnly() {
        // Given a full window and a mask for title only
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.zIndex = 5
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
        XCTAssertEqual(result.zIndex, 0) // default (not requested)
        XCTAssertFalse(result.visible) // default (not requested)
        XCTAssertEqual(result.bundleID, "") // default (not requested)
    }

    func testApplyFieldMaskWindowBoundsOnly() {
        // Given a full window and a mask for bounds only
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.zIndex = 5
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
        XCTAssertEqual(result.zIndex, 0) // default
        XCTAssertFalse(result.visible) // default
        XCTAssertEqual(result.bundleID, "") // default
    }

    func testApplyFieldMaskWindowMultipleFields() {
        // Given a full window and a mask for multiple fields
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = 100
                $0.y = 200
                $0.width = 300
                $0.height = 400
            }
            $0.zIndex = 5
            $0.visible = true
            $0.bundleID = "com.test.app"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["title", "visible", "z_index"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then only name and requested fields should be populated
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "Test Window")
        XCTAssertEqual(result.bounds.x, 0) // default (not requested)
        XCTAssertEqual(result.zIndex, 5)
        XCTAssertTrue(result.visible)
        XCTAssertEqual(result.bundleID, "") // default (not requested)
    }

    func testApplyFieldMaskWindowUnknownFieldIgnored() {
        // Given a full window and a mask with an unknown field
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
        }
        let mask = SwiftProtobuf.Google_Protobuf_FieldMask.with {
            $0.paths = ["title", "unknown_field", "another_unknown"]
        }

        // When applying the mask
        let result = ParsingHelpers.applyFieldMask(to: window, readMask: mask)

        // Then unknown fields are silently ignored
        XCTAssertEqual(result.name, "applications/123/windows/456")
        XCTAssertEqual(result.title, "Test Window")
    }

    func testApplyFieldMaskWindowNameAlwaysIncluded() {
        // Given a full window and a mask that does NOT include name
        let window = Macosusesdk_V1_Window.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let app = Macosusesdk_V1_Application.with {
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
        let window = Macosusesdk_V1_Window.with {
            $0.name = "applications/123/windows/456"
            $0.title = "Test Window"
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = 10
                $0.y = 20
                $0.width = 100
                $0.height = 200
            }
            $0.zIndex = 5
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
        XCTAssertEqual(result.zIndex, 5)
        XCTAssertEqual(result.visible, true)
        XCTAssertEqual(result.bundleID, "com.test.app")
    }

    func testApplyFieldMaskApplicationWildcardReturnsAllFields() {
        // Given a full application and a mask with "*"
        let app = Macosusesdk_V1_Application.with {
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
