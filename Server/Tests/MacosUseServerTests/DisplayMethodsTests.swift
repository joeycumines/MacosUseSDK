import CoreGraphics
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for DisplayMethods (listDisplays, getDisplay).
/// These tests verify display enumeration, frame properties, visible frames,
/// scale factors, and main display detection.
final class DisplayMethodsTests: XCTestCase {
    var service: MacosUseService!

    override func setUp() async throws {
        let registry = WindowRegistry(system: ProductionSystemOperations.shared)
        service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
    }

    // MARK: - Helpers

    private func makeListDisplaysRequest(_ msg: Macosusesdk_V1_ListDisplaysRequest = Macosusesdk_V1_ListDisplaysRequest()) -> GRPCCore.ServerRequest<Macosusesdk_V1_ListDisplaysRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeGetDisplayRequest(_ msg: Macosusesdk_V1_GetDisplayRequest) -> GRPCCore.ServerRequest<Macosusesdk_V1_GetDisplayRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeListDisplaysContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ListDisplays.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeGetDisplayContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.GetDisplay.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    // MARK: - ListDisplays Tests

    func testListDisplaysReturnsAtLeastOneDisplay() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        XCTAssertGreaterThanOrEqual(
            msg.displays.count, 1,
            "At least one display should be returned on any macOS system",
        )
    }

    func testListDisplaysFrameHasPositiveWidthAndHeight() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        for display in msg.displays {
            XCTAssertGreaterThan(
                display.frame.width, 0,
                "Display \(display.displayID) frame width must be positive, got \(display.frame.width)",
            )
            XCTAssertGreaterThan(
                display.frame.height, 0,
                "Display \(display.displayID) frame height must be positive, got \(display.frame.height)",
            )
        }
    }

    func testListDisplaysVisibleFrameWithinOrEqualToFrame() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        for display in msg.displays {
            let frame = display.frame
            let visible = display.visibleFrame

            // Visible frame width and height must not exceed frame dimensions
            XCTAssertLessThanOrEqual(
                visible.width, frame.width,
                "Display \(display.displayID) visible width (\(visible.width)) should not exceed frame width (\(frame.width))",
            )
            XCTAssertLessThanOrEqual(
                visible.height, frame.height,
                "Display \(display.displayID) visible height (\(visible.height)) should not exceed frame height (\(frame.height))",
            )

            // Visible frame must have positive dimensions
            XCTAssertGreaterThan(
                visible.width, 0,
                "Display \(display.displayID) visible width must be positive",
            )
            XCTAssertGreaterThan(
                visible.height, 0,
                "Display \(display.displayID) visible height must be positive",
            )

            // Visible frame origin must be within or at the frame origin
            let visibleMaxX = visible.x + visible.width
            let visibleMaxY = visible.y + visible.height
            let frameMaxX = frame.x + frame.width
            let frameMaxY = frame.y + frame.height

            XCTAssertGreaterThanOrEqual(
                visible.x, frame.x,
                "Display \(display.displayID) visible x (\(visible.x)) should be >= frame x (\(frame.x))",
            )
            XCTAssertGreaterThanOrEqual(
                visible.y, frame.y,
                "Display \(display.displayID) visible y (\(visible.y)) should be >= frame y (\(frame.y))",
            )
            XCTAssertLessThanOrEqual(
                visibleMaxX, frameMaxX + 0.001,
                "Display \(display.displayID) visible maxX (\(visibleMaxX)) should be <= frame maxX (\(frameMaxX))",
            )
            XCTAssertLessThanOrEqual(
                visibleMaxY, frameMaxY + 0.001,
                "Display \(display.displayID) visible maxY (\(visibleMaxY)) should be <= frame maxY (\(frameMaxY))",
            )
        }
    }

    func testListDisplaysScaleFactorGreaterThanOrEqualToOne() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        for display in msg.displays {
            XCTAssertGreaterThanOrEqual(
                display.scale, 1.0,
                "Display \(display.displayID) scale factor must be >= 1.0, got \(display.scale)",
            )
        }
    }

    func testListDisplaysExactlyOneMainDisplay() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        let mainDisplays = msg.displays.filter(\.isMain)

        XCTAssertEqual(
            mainDisplays.count, 1,
            "Exactly one display should be marked as main, found \(mainDisplays.count)",
        )
    }

    func testListDisplaysMainDisplayHasValidFrame() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        guard let mainDisplay = msg.displays.first(where: { $0.isMain }) else {
            XCTFail("No main display found")
            return
        }

        XCTAssertGreaterThan(mainDisplay.frame.width, 0)
        XCTAssertGreaterThan(mainDisplay.frame.height, 0)
        XCTAssertGreaterThanOrEqual(mainDisplay.scale, 1.0)
    }

    func testListDisplaysDisplayIDsAreUnique() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        let displayIDs = msg.displays.map(\.displayID)
        let uniqueIDs = Set(displayIDs)

        XCTAssertEqual(
            displayIDs.count, uniqueIDs.count,
            "All display IDs should be unique",
        )
    }

    func testListDisplaysReturnsDeterministicOrder() async throws {
        let response1 = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg1 = try response1.message
        let response2 = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg2 = try response2.message

        XCTAssertEqual(msg1.displays.count, msg2.displays.count)

        for (d1, d2) in zip(msg1.displays, msg2.displays) {
            XCTAssertEqual(d1.displayID, d2.displayID, "Display order should be deterministic")
        }
    }

    // MARK: - ListDisplays Pagination Tests

    func testListDisplaysPaginationReturnsEmptyNextTokenForSmallSets() async throws {
        let response = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try response.message

        if msg.displays.count < 100 {
            XCTAssertTrue(
                msg.nextPageToken.isEmpty,
                "nextPageToken should be empty when all results fit in one page",
            )
        }
    }

    func testListDisplaysPaginationWithSmallPageSize() async throws {
        let fullResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let fullMsg = try fullResponse.message
        let totalCount = fullMsg.displays.count

        guard totalCount > 1 else {
            return
        }

        var paginatedRequest = Macosusesdk_V1_ListDisplaysRequest()
        paginatedRequest.pageSize = 1

        let page1Response = try await service.listDisplays(
            request: makeListDisplaysRequest(paginatedRequest), context: makeListDisplaysContext(),
        )
        let page1 = try page1Response.message

        XCTAssertEqual(page1.displays.count, 1, "Page 1 should have 1 display")
        XCTAssertFalse(page1.nextPageToken.isEmpty, "Should have next page token")

        paginatedRequest.pageToken = page1.nextPageToken
        let page2Response = try await service.listDisplays(
            request: makeListDisplaysRequest(paginatedRequest), context: makeListDisplaysContext(),
        )
        let page2 = try page2Response.message

        XCTAssertEqual(page2.displays.count, 1, "Page 2 should have 1 display")

        XCTAssertNotEqual(
            page1.displays[0].displayID,
            page2.displays[0].displayID,
            "Pages should contain different displays",
        )
    }

    // MARK: - GetDisplay Tests

    func testGetDisplayReturnsValidDisplay() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        guard let firstDisplay = listMsg.displays.first else {
            XCTFail("No displays found to test GetDisplay")
            return
        }

        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/\(firstDisplay.displayID)"

        let getResponse = try await service.getDisplay(
            request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
        )
        let getMsg = try getResponse.message

        XCTAssertEqual(getMsg.displayID, firstDisplay.displayID)
        XCTAssertEqual(getMsg.name, "displays/\(firstDisplay.displayID)")
    }

    func testGetDisplayFrameHasPositiveWidthAndHeight() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        guard let firstDisplay = listMsg.displays.first else {
            XCTFail("No displays found")
            return
        }

        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/\(firstDisplay.displayID)"

        let getResponse = try await service.getDisplay(
            request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
        )
        let getMsg = try getResponse.message

        XCTAssertGreaterThan(getMsg.frame.width, 0, "GetDisplay frame width must be positive")
        XCTAssertGreaterThan(getMsg.frame.height, 0, "GetDisplay frame height must be positive")
    }

    func testGetDisplayVisibleFrameWithinOrEqualToFrame() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        guard let firstDisplay = listMsg.displays.first else {
            XCTFail("No displays found")
            return
        }

        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/\(firstDisplay.displayID)"

        let response = try await service.getDisplay(
            request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
        )
        let msg = try response.message

        let frame = msg.frame
        let visible = msg.visibleFrame

        XCTAssertLessThanOrEqual(visible.width, frame.width, "Visible width should not exceed frame width")
        XCTAssertLessThanOrEqual(visible.height, frame.height, "Visible height should not exceed frame height")
        XCTAssertGreaterThanOrEqual(visible.x, frame.x, "Visible x should be >= frame x")
        XCTAssertGreaterThanOrEqual(visible.y, frame.y, "Visible y should be >= frame y")
    }

    func testGetDisplayScaleFactorGreaterThanOrEqualToOne() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        guard let firstDisplay = listMsg.displays.first else {
            XCTFail("No displays found")
            return
        }

        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/\(firstDisplay.displayID)"

        let response = try await service.getDisplay(
            request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
        )
        let msg = try response.message

        XCTAssertGreaterThanOrEqual(msg.scale, 1.0, "GetDisplay scale must be >= 1.0")
    }

    func testGetDisplayMainFlagMatchesListDisplays() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        for listedDisplay in listMsg.displays {
            var getRequest = Macosusesdk_V1_GetDisplayRequest()
            getRequest.name = "displays/\(listedDisplay.displayID)"

            let getResponse = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            let getMsg = try getResponse.message

            XCTAssertEqual(
                getMsg.isMain, listedDisplay.isMain,
                "GetDisplay isMain should match ListDisplays for display \(listedDisplay.displayID)",
            )
        }
    }

    func testGetDisplayConsistentWithListDisplays() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let listMsg = try listResponse.message

        for listedDisplay in listMsg.displays {
            var getRequest = Macosusesdk_V1_GetDisplayRequest()
            getRequest.name = "displays/\(listedDisplay.displayID)"

            let getResponse = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            let getMsg = try getResponse.message

            XCTAssertEqual(getMsg.frame.width, listedDisplay.frame.width, accuracy: 0.001, "Frame width should match")
            XCTAssertEqual(getMsg.frame.height, listedDisplay.frame.height, accuracy: 0.001, "Frame height should match")
            XCTAssertEqual(getMsg.frame.x, listedDisplay.frame.x, accuracy: 0.001, "Frame x should match")
            XCTAssertEqual(getMsg.frame.y, listedDisplay.frame.y, accuracy: 0.001, "Frame y should match")
            XCTAssertEqual(getMsg.scale, listedDisplay.scale, accuracy: 0.001, "Scale should match")
        }
    }

    // MARK: - GetDisplay Error Cases

    func testGetDisplayInvalidResourceNameFormat() async throws {
        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "invalid-format"

        do {
            _ = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            XCTFail("Expected error for invalid resource name format")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("Invalid display resource name"))
        }
    }

    func testGetDisplayInvalidDisplayID() async throws {
        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/not-a-number"

        do {
            _ = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            XCTFail("Expected error for invalid display ID")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("Invalid display ID"))
        }
    }

    func testGetDisplayNonExistentDisplayID() async throws {
        var getRequest = Macosusesdk_V1_GetDisplayRequest()
        getRequest.name = "displays/999999999"

        do {
            _ = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            XCTFail("Expected error for non-existent display ID")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("Display not found"))
        }
    }

    func testGetDisplayEmptyName() async throws {
        let getRequest = Macosusesdk_V1_GetDisplayRequest()

        do {
            _ = try await service.getDisplay(
                request: makeGetDisplayRequest(getRequest), context: makeGetDisplayContext(),
            )
            XCTFail("Expected error for empty resource name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - Display Frame Coordinate Tests

    func testMainDisplayOriginIsAtZeroZero() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try listResponse.message

        guard let mainDisplay = msg.displays.first(where: { $0.isMain }) else {
            XCTFail("No main display found")
            return
        }

        XCTAssertEqual(mainDisplay.frame.x, 0, "Main display frame x should be 0 (Global Display Coordinates)")
        XCTAssertEqual(mainDisplay.frame.y, 0, "Main display frame y should be 0 (Global Display Coordinates)")
    }

    func testDisplayVisibleFrameAccountsForMenuBarOrDock() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try listResponse.message

        guard let mainDisplay = msg.displays.first(where: { $0.isMain }) else {
            XCTFail("No main display found")
            return
        }

        let frameArea = mainDisplay.frame.width * mainDisplay.frame.height
        let visibleArea = mainDisplay.visibleFrame.width * mainDisplay.visibleFrame.height

        XCTAssertLessThanOrEqual(visibleArea, frameArea, "Visible frame area should not exceed frame area")
    }

    // MARK: - Common Display Resolution Tests

    func testDisplayResolutionIsReasonable() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try listResponse.message

        for display in msg.displays {
            XCTAssertGreaterThanOrEqual(display.frame.width, 640, "Display width should be at least 640 pixels")
            XCTAssertGreaterThanOrEqual(display.frame.height, 480, "Display height should be at least 480 pixels")
            XCTAssertLessThanOrEqual(display.frame.width, 16384, "Display width seems unreasonably large")
            XCTAssertLessThanOrEqual(display.frame.height, 16384, "Display height seems unreasonably large")
        }
    }

    func testDisplayScaleFactorIsReasonable() async throws {
        let listResponse = try await service.listDisplays(request: makeListDisplaysRequest(), context: makeListDisplaysContext())
        let msg = try listResponse.message

        for display in msg.displays {
            XCTAssertGreaterThanOrEqual(display.scale, 1.0, "Scale factor must be at least 1.0")
            XCTAssertLessThanOrEqual(display.scale, 4.0, "Scale factor seems unreasonably large (>4.0)")
        }
    }
}
