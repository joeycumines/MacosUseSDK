import ApplicationServices
@testable import ExactMacServer
import GRPCCore
import XCTest

final class InputTextConvergenceTests: XCTestCase {
    @MainActor
    func testWaitForChangeRetriesUntilExactFocusedElementStateChanges() async throws {
        let element = NSObject()
        let reader = InputTextStateSequenceReader(
            focusedElements: [element, element, element],
            values: ["before" as NSString, "before" as NSString, "after" as NSString],
            selectedRanges: [nil, nil, nil],
        )
        let verifier = InputTextConvergenceVerifier(
            pid: 73101,
            reader: reader,
            policy: InputTextConvergencePolicy(
                timeout: .seconds(1),
                pollInterval: .zero,
            ),
        )

        let baseline = try verifier.capture()
        try await verifier.waitForChange(from: baseline)

        XCTAssertGreaterThanOrEqual(reader.valueReadCount, 3)
    }

    @MainActor
    func testWaitForChangeRejectsFocusedElementReplacement() async throws {
        let original = NSObject()
        let replacement = NSObject()
        let reader = InputTextStateSequenceReader(
            focusedElements: [original, replacement],
            values: ["before" as NSString],
            selectedRanges: [nil],
        )
        let verifier = InputTextConvergenceVerifier(
            pid: 73102,
            reader: reader,
            policy: InputTextConvergencePolicy(
                timeout: .seconds(1),
                pollInterval: .zero,
            ),
        )

        let baseline = try verifier.capture()
        do {
            try await verifier.waitForChange(from: baseline)
            XCTFail("Expected focused element replacement to fail")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }
    }

    @MainActor
    func testCaptureRejectsFocusedElementWithoutObservableTextState() throws {
        let element = NSObject()
        let reader = InputTextStateSequenceReader(
            focusedElements: [element],
            values: [nil],
            selectedRanges: [nil],
        )
        let verifier = InputTextConvergenceVerifier(
            pid: 73103,
            reader: reader,
        )

        XCTAssertThrowsError(try verifier.capture()) { error in
            XCTAssertEqual((error as? RPCError)?.code, .failedPrecondition)
        }
    }
}

private final class InputTextStateSequenceReader:
    InputTextStateReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var focusedElements: [AnyObject]
    private var values: [AnyObject?]
    private var selectedRanges: [AnyObject?]
    private var _valueReadCount = 0

    init(
        focusedElements: [AnyObject],
        values: [AnyObject?],
        selectedRanges: [AnyObject?],
    ) {
        self.focusedElements = focusedElements
        self.values = values
        self.selectedRanges = selectedRanges
    }

    var valueReadCount: Int {
        lock.withLock { _valueReadCount }
    }

    func focusedElement(pid _: pid_t) -> AXElementRead {
        lock.withLock {
            guard !focusedElements.isEmpty else {
                return AXElementRead(
                    errorCode: AXError.cannotComplete.rawValue,
                    element: nil,
                )
            }
            let element = focusedElements.removeFirst()
            return AXElementRead(
                errorCode: AXError.success.rawValue,
                element: element,
            )
        }
    }

    func attribute(element _: AnyObject, attribute: String) -> AXAttributeRead {
        lock.withLock {
            switch attribute {
            case kAXValueAttribute as String:
                _valueReadCount += 1
                return nextRead(from: &values)
            case kAXSelectedTextRangeAttribute as String:
                return nextRead(from: &selectedRanges)
            default:
                return AXAttributeRead(
                    errorCode: AXError.attributeUnsupported.rawValue,
                    value: nil,
                )
            }
        }
    }

    private func nextRead(from values: inout [AnyObject?]) -> AXAttributeRead {
        guard !values.isEmpty else {
            return AXAttributeRead(
                errorCode: AXError.cannotComplete.rawValue,
                value: nil,
            )
        }
        let value = values.count == 1 ? values[0] : values.removeFirst()
        return AXAttributeRead(
            errorCode: value == nil
                ? AXError.attributeUnsupported.rawValue
                : AXError.success.rawValue,
            value: value,
        )
    }
}
