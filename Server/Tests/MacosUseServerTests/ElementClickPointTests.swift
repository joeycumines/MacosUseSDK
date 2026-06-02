import CoreGraphics
import GRPCCore
import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for MacosUseService.elementClickPoint center calculation.
///
/// These tests verify that the click point is correctly calculated as the
/// geometric center of an element's bounds, and that zero-size elements
/// are properly rejected.
final class ElementClickPointTests: XCTestCase {
    // MARK: - Center Calculation

    func testClickPoint_standardElement_returnsCenter() throws {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = 30
        }
        let point = try MacosUseService.elementClickPoint(element)
        XCTAssertEqual(point.x, 125.0, accuracy: 0.001)
        XCTAssertEqual(point.y, 115.0, accuracy: 0.001)
    }

    func testClickPoint_largeElement_returnsCenter() throws {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 0
            $0.y = 0
            $0.width = 1920
            $0.height = 1080
        }
        let point = try MacosUseService.elementClickPoint(element)
        XCTAssertEqual(point.x, 960.0, accuracy: 0.001)
        XCTAssertEqual(point.y, 540.0, accuracy: 0.001)
    }

    func testClickPoint_oddDimensions_returnsFractionalCenter() throws {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 10
            $0.y = 20
            $0.width = 31
            $0.height = 47
        }
        let point = try MacosUseService.elementClickPoint(element)
        XCTAssertEqual(point.x, 25.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 43.5, accuracy: 0.001)
    }

    func testClickPoint_negativeCoordinates_returnsCorrectCenter() throws {
        // Multi-monitor setups can have negative coordinates
        let element = Macosusesdk_Type_Element.with {
            $0.x = -1920
            $0.y = -100
            $0.width = 800
            $0.height = 600
        }
        let point = try MacosUseService.elementClickPoint(element)
        XCTAssertEqual(point.x, -1520.0, accuracy: 0.001)
        XCTAssertEqual(point.y, 200.0, accuracy: 0.001)
    }

    func testClickPoint_zeroWidthAndHeight_throwsFailedPrecondition() throws {
        // Zero-size elements have no determinable click point and are rejected
        let element = Macosusesdk_Type_Element.with {
            $0.x = 500
            $0.y = 500
            $0.width = 0
            $0.height = 0
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    // MARK: - Zero-Size Rejection

    func testClickPoint_zeroWidth_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = 0
            $0.height = 50
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
            let msg = rpcError?.message ?? ""
            XCTAssertTrue(msg.contains("zero size"), "Error message should mention zero size")
        }
    }

    func testClickPoint_zeroHeight_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = 0
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    func testClickPoint_missingWidth_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            // width not set
            $0.height = 50
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    func testClickPoint_missingHeight_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = 50
            // height not set
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    func testClickPoint_missingX_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            // x not set
            $0.y = 100
            $0.width = 50
            $0.height = 30
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    func testClickPoint_missingY_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            // y not set
            $0.width = 50
            $0.height = 30
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    // MARK: - Float/Double Precision

    func testClickPoint_precisionMaintained() throws {
        // Ensure floating point precision is maintained in center calculation
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100.25
            $0.y = 200.75
            $0.width = 50.5
            $0.height = 30.5
        }
        let point = try MacosUseService.elementClickPoint(element)
        XCTAssertEqual(point.x, 125.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 216.0, accuracy: 0.001)
    }

    // MARK: - Negative Width/Height (Edge Cases)

    func testClickPoint_negativeWidth_throwsFailedPrecondition() {
        // Negative width is invalid for click targeting
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = -50
            $0.height = 30
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }

    func testClickPoint_negativeHeight_throwsFailedPrecondition() {
        let element = Macosusesdk_Type_Element.with {
            $0.x = 100
            $0.y = 100
            $0.width = 50
            $0.height = -30
        }
        XCTAssertThrowsError(try MacosUseService.elementClickPoint(element)) { error in
            let rpcError = error as? RPCError
            XCTAssertEqual(rpcError?.code, .failedPrecondition)
        }
    }
}
