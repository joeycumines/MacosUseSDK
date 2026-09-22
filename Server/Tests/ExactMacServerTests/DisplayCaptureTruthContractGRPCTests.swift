import CoreGraphics
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import ImageIO
import SwiftProtobuf
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct DisplayCaptureTruthContractGRPCTests {
    @Test
    func `ListDisplays returns one exact immutable topology snapshot`() async throws {
        let provider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            let response: Exactmac_V1_ListDisplaysResponse = try await displayCaptureTruthUnary(
                client: client,
                request: Exactmac_V1_ListDisplaysRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
            )

            #expect(response.displays.map(\.displayID) == [11, 22, 33])
            let left = try #require(response.displays.first { $0.displayID == 22 })
            #expect(left.name == "displays/22")
            #expect(left.frame == displayCaptureTruthRegion(displayCaptureTruthDisplays[1].frame))
            #expect(left.visibleFrame == displayCaptureTruthRegion(displayCaptureTruthDisplays[1].visibleFrame))
            #expect(left.scale == 1.5)
            #expect(!left.isMain)
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await sink.captureCount == 0)
    }

    @Test
    func `production topology reconciliation converts every dock edge and rejects missing screen metadata`() throws {
        let frame = CGRect(x: -1200, y: -200, width: 1200, height: 800)
        let appKitFrame = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let cases: [(CGRect, CGRect)] = [
            (
                CGRect(x: -1200, y: 100, width: 1200, height: 760),
                CGRect(x: -1200, y: -160, width: 1200, height: 760),
            ),
            (
                CGRect(x: -1200, y: 140, width: 1200, height: 760),
                CGRect(x: -1200, y: -200, width: 1200, height: 760),
            ),
            (
                CGRect(x: -1160, y: 100, width: 1160, height: 800),
                CGRect(x: -1160, y: -200, width: 1160, height: 800),
            ),
            (
                CGRect(x: -1200, y: 100, width: 1160, height: 800),
                CGRect(x: -1200, y: -200, width: 1160, height: 800),
            ),
        ]

        for (visibleFrame, expected) in cases {
            let snapshot = try DisplayTopologySnapshot.reconcile(
                activeDisplays: [
                    .init(displayID: 91, frame: frame, isMain: true),
                ],
                screens: [
                    .init(
                        displayID: 91,
                        frame: appKitFrame,
                        visibleFrame: visibleFrame,
                        scale: 2,
                    ),
                ],
            )
            #expect(snapshot.displays.first?.visibleFrame == expected)
        }

        #expect(throws: RPCError.self) {
            _ = try DisplayTopologySnapshot.reconcile(
                activeDisplays: [.init(displayID: 91, frame: frame, isMain: true)],
                screens: [],
            )
        }
    }

    @Test
    func `GetDisplay rejects an inactive parseable display without consulting capture`() async throws {
        let provider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            await expectDisplayCaptureTruthRPCError(.notFound) {
                let _: Exactmac_V1_Display = try await displayCaptureTruthUnary(
                    client: client,
                    request: Exactmac_V1_GetDisplayRequest.with { $0.name = "displays/999" },
                    descriptor: Exactmac_V1_ExactMac.Method.GetDisplay.descriptor,
                )
            }
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await sink.captureCount == 0)
    }

    @Test(arguments: ["", "displays/22"])
    func `CaptureScreenshot selects the snapshot main or exact explicit display and reports actual metadata`(
        display: String,
    ) async throws {
        let provider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            let response: Exactmac_V1_CaptureScreenshotResponse = try await displayCaptureTruthUnary(
                client: client,
                request: Exactmac_V1_CaptureScreenshotRequest.with {
                    $0.display = display
                    $0.format = .png
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
            )
            let expected = display.isEmpty ? displayCaptureTruthDisplays[0] : displayCaptureTruthDisplays[1]

            #expect(response.display == expected.name)
            #expect(response.region == displayCaptureTruthRegion(expected.frame))
            #expect(response.scale == expected.scale)
            #expect(response.format == .png)
            try assertDisplayCaptureTruthImage(
                response.imageData,
                width: Int(response.width),
                height: Int(response.height),
            )
            #expect(await sink.lastDisplayID == expected.displayID)
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await sink.captureCount == 1)
    }

    @Test(arguments: ["", "displays/22"])
    func `CaptureRegionScreenshot selects the same negative-origin source explicitly or by inference`(
        display: String,
    ) async throws {
        let provider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )
        let requested = CGRect(x: -3.6, y: -0.4, width: 1.1, height: 1.3)

        try await withDisplayCaptureTruthClient(composition) { client in
            let response: Exactmac_V1_CaptureRegionScreenshotResponse = try await displayCaptureTruthUnary(
                client: client,
                request: Exactmac_V1_CaptureRegionScreenshotRequest.with {
                    $0.display = display
                    $0.region = displayCaptureTruthRegion(requested)
                    $0.format = .png
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
            )

            #expect(response.display == "displays/22")
            #expect(response.scale == 1.5)
            #expect(response.region.x <= requested.minX)
            #expect(response.region.y <= requested.minY)
            #expect(response.region.x + response.region.width >= requested.maxX)
            #expect(response.region.y + response.region.height >= requested.maxY)
            try assertDisplayCaptureTruthImage(
                response.imageData,
                width: Int(response.width),
                height: Int(response.height),
            )
            #expect(await sink.lastDisplayID == 22)
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await sink.captureCount == 1)
    }

    @Test
    func `CaptureRegionScreenshot rejects crossing and mirrored ambiguity before capture`() async throws {
        let crossingProvider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let crossingSink = DisplayCaptureTruthSink()
        let crossingComposition = ExactMacServiceComposition(
            displayTopologyProvider: crossingProvider,
            screenshotCapture: crossingSink,
        )

        try await withDisplayCaptureTruthClient(crossingComposition) { client in
            await expectDisplayCaptureTruthRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureRegionScreenshotResponse = try await displayCaptureTruthUnary(
                    client: client,
                    request: displayCaptureTruthRegionRequest(CGRect(x: -0.5, y: 0, width: 1, height: 1)),
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                )
            }
        }
        #expect(await crossingSink.captureCount == 0)

        let mirrored = [
            DisplayTopologyDisplay(
                displayID: 41,
                frame: CGRect(x: 0, y: 0, width: 4, height: 3),
                visibleFrame: CGRect(x: 0, y: 0, width: 4, height: 3),
                isMain: true,
                scale: 2,
            ),
            DisplayTopologyDisplay(
                displayID: 42,
                frame: CGRect(x: 0, y: 0, width: 4, height: 3),
                visibleFrame: CGRect(x: 0, y: 0, width: 4, height: 3),
                isMain: false,
                scale: 2,
            ),
        ]
        let mirroredProvider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: mirrored))
        let mirroredSink = DisplayCaptureTruthSink()
        let mirroredComposition = ExactMacServiceComposition(
            displayTopologyProvider: mirroredProvider,
            screenshotCapture: mirroredSink,
        )

        try await withDisplayCaptureTruthClient(mirroredComposition) { client in
            await expectDisplayCaptureTruthRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureRegionScreenshotResponse = try await displayCaptureTruthUnary(
                    client: client,
                    request: displayCaptureTruthRegionRequest(CGRect(x: 1, y: 1, width: 1, height: 1)),
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                )
            }
        }
        #expect(await mirroredSink.captureCount == 0)
    }

    @Test
    func `endpoint-overflowing region rejects before topology or capture ownership`() async throws {
        let provider = DisplayCaptureTruthTopologyProvider(
            snapshot: .init(displays: displayCaptureTruthDisplays),
        )
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            await expectDisplayCaptureTruthRPCError(.invalidArgument) {
                let _: Exactmac_V1_CaptureRegionScreenshotResponse =
                    try await displayCaptureTruthUnary(
                        client: client,
                        request: displayCaptureTruthRegionRequest(
                            CGRect(
                                x: CGFloat.greatestFiniteMagnitude,
                                y: 0,
                                width: CGFloat.greatestFiniteMagnitude,
                                height: 1,
                            ),
                        ),
                        descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                    )
            }
        }

        #expect(await provider.snapshotCount == 0)
        #expect(await sink.captureCount == 0)
        #expect(await composition.captureWorkOwner.activeCaptureCount() == 0)
    }

    @Test
    func `display snapshot rejects finite components with overflowing endpoints`() throws {
        let overflow = CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: 1,
        )
        #expect(throws: RPCError.self) {
            try DisplayTopologySnapshot(
                displays: [
                    DisplayTopologyDisplay(
                        displayID: 1,
                        frame: overflow,
                        visibleFrame: overflow,
                        isMain: true,
                        scale: 1,
                    ),
                ],
            ).validated()
        }

        let collapsed = CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 0,
            width: 1,
            height: 1,
        )
        #expect(throws: RPCError.self) {
            try DisplayTopologySnapshot(
                displays: [
                    DisplayTopologyDisplay(
                        displayID: 1,
                        frame: collapsed,
                        visibleFrame: collapsed,
                        isMain: true,
                        scale: 1,
                    ),
                ],
            ).validated()
        }
    }

    @Test
    func `capture-source topology mismatch fails unavailable before image capture`() async throws {
        let provider = DisplayCaptureTruthTopologyProvider(snapshot: .init(displays: displayCaptureTruthDisplays))
        let sink = DisplayCaptureTruthSink(availableDisplayIDs: [22, 33])
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            await expectDisplayCaptureTruthRPCError(.unavailable) {
                let _: Exactmac_V1_CaptureScreenshotResponse = try await displayCaptureTruthUnary(
                    client: client,
                    request: Exactmac_V1_CaptureScreenshotRequest(),
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
                )
            }
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await sink.selectionCount == 1)
        #expect(await sink.captureCount == 0)
    }

    @Test
    func `CaptureCursorPosition resolves negative coordinates from the same snapshot`() async throws {
        let provider = DisplayCaptureTruthTopologyProvider(
            snapshot: .init(displays: displayCaptureTruthDisplays),
            cursorLocation: CGPoint(x: -2, y: 1),
        )
        let sink = DisplayCaptureTruthSink()
        let composition = ExactMacServiceComposition(
            displayTopologyProvider: provider,
            screenshotCapture: sink,
        )

        try await withDisplayCaptureTruthClient(composition) { client in
            let response: Exactmac_V1_CaptureCursorPositionResponse = try await displayCaptureTruthUnary(
                client: client,
                request: Exactmac_V1_CaptureCursorPositionRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.CaptureCursorPosition.descriptor,
            )
            #expect(response.x == -2)
            #expect(response.y == 1)
            #expect(response.display == "displays/22")
        }

        #expect(await provider.snapshotCount == 1)
        #expect(await provider.cursorReadCount == 1)
    }
}

private let displayCaptureTruthDisplays = [
    DisplayTopologyDisplay(
        displayID: 11,
        frame: CGRect(x: 0, y: 0, width: 4, height: 3),
        visibleFrame: CGRect(x: 0, y: 0.5, width: 4, height: 2.5),
        isMain: true,
        scale: 2,
    ),
    DisplayTopologyDisplay(
        displayID: 22,
        frame: CGRect(x: -4, y: -1, width: 4, height: 4),
        visibleFrame: CGRect(x: -3.5, y: -1, width: 3.5, height: 4),
        isMain: false,
        scale: 1.5,
    ),
    DisplayTopologyDisplay(
        displayID: 33,
        frame: CGRect(x: 4, y: -2, width: 2, height: 5),
        visibleFrame: CGRect(x: 4, y: -1.5, width: 2, height: 4.5),
        isMain: false,
        scale: 1,
    ),
]

private actor DisplayCaptureTruthTopologyProvider: DisplayTopologyProviding {
    private let storedSnapshot: DisplayTopologySnapshot
    private let storedCursorLocation: CGPoint
    private(set) var snapshotCount = 0
    private(set) var cursorReadCount = 0

    init(
        snapshot: DisplayTopologySnapshot,
        cursorLocation: CGPoint = .zero,
    ) {
        storedSnapshot = snapshot
        storedCursorLocation = cursorLocation
    }

    func snapshot() async throws -> DisplayTopologySnapshot {
        snapshotCount += 1
        return storedSnapshot
    }

    func cursorLocation() async throws -> CGPoint {
        cursorReadCount += 1
        return storedCursorLocation
    }
}

private actor DisplayCaptureTruthSink: ScreenshotCapturing {
    private let availableDisplayIDs: Set<CGDirectDisplayID>?
    private(set) var selectionCount = 0
    private(set) var captureCount = 0
    private(set) var lastDisplayID: CGDirectDisplayID?

    init(availableDisplayIDs: Set<CGDirectDisplayID>? = nil) {
        self.availableDisplayIDs = availableDisplayIDs
    }

    func captureDisplay(
        _ display: DisplayTopologyDisplay,
        format: Exactmac_V1_ImageFormat,
        quality _: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        selectionCount += 1
        try admit(display)
        captureCount += 1
        lastDisplayID = display.displayID
        let width = Int((display.frame.width * display.scale).rounded())
        let height = Int((display.frame.height * display.scale).rounded())
        return try output(
            display: display,
            logicalFrame: display.frame,
            pixelWidth: width,
            pixelHeight: height,
            format: format,
            includeOCR: includeOCR,
        )
    }

    func captureRegion(
        _ region: CGRect,
        display: DisplayTopologyDisplay,
        format: Exactmac_V1_ImageFormat,
        quality _: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        selectionCount += 1
        try admit(display)
        captureCount += 1
        lastDisplayID = display.displayID
        let scale = CGFloat(display.scale)
        let pixelRect = CGRect(
            x: (region.minX - display.frame.minX) * scale,
            y: (region.minY - display.frame.minY) * scale,
            width: region.width * scale,
            height: region.height * scale,
        ).integral
        let logicalFrame = CGRect(
            x: display.frame.minX + pixelRect.minX / scale,
            y: display.frame.minY + pixelRect.minY / scale,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale,
        )
        return try output(
            display: display,
            logicalFrame: logicalFrame,
            pixelWidth: Int(pixelRect.width),
            pixelHeight: Int(pixelRect.height),
            format: format,
            includeOCR: includeOCR,
        )
    }

    func captureWindow(
        _: WindowScreenshotCaptureSource,
        format _: Exactmac_V1_ImageFormat,
        quality _: Int32,
        includeShadow _: Bool,
        includeOCR _: Bool,
    ) async throws -> WindowScreenshotCaptureOutput {
        throw RPCError(code: .aborted, message: "Unexpected window capture")
    }

    private func admit(_ display: DisplayTopologyDisplay) throws {
        guard availableDisplayIDs?.contains(display.displayID) != false else {
            throw RPCError(code: .unavailable, message: "Capture topology changed")
        }
    }

    private func output(
        display: DisplayTopologyDisplay,
        logicalFrame: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        format: Exactmac_V1_ImageFormat,
        includeOCR: Bool,
    ) throws -> ScreenshotCaptureOutput {
        try ScreenshotCaptureOutput(
            data: displayCaptureTruthPNG(width: pixelWidth, height: pixelHeight),
            format: format,
            pixelWidth: Int32(pixelWidth),
            pixelHeight: Int32(pixelHeight),
            displayID: display.displayID,
            logicalFrame: logicalFrame,
            scale: display.scale,
            ocrResult: includeOCR ? .text("truth") : .notRequested,
        )
    }
}

private func withDisplayCaptureTruthClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let inProcess = InProcessTransport()
    let server = GRPCServer(transport: inProcess.server, services: [composition.exactMacService])
    let client = GRPCClient(transport: inProcess.client)
    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await server.serve() }
        group.addTask { try await client.runConnections() }
        defer {
            client.beginGracefulShutdown()
            server.beginGracefulShutdown()
        }
        try await operation(client)
    }
}

private func displayCaptureTruthUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: .defaults,
    ) { response in
        try response.message
    }
}

private func expectDisplayCaptureTruthRPCError(
    _ code: RPCError.Code,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected RPC error \(code)")
    } catch let error as RPCError {
        #expect(error.code == code, Comment(rawValue: String(describing: error)))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

private func displayCaptureTruthRegionRequest(
    _ region: CGRect,
) -> Exactmac_V1_CaptureRegionScreenshotRequest {
    .with {
        $0.region = displayCaptureTruthRegion(region)
        $0.format = .png
    }
}

private func displayCaptureTruthRegion(_ frame: CGRect) -> Exactmac_Type_Region {
    .with {
        $0.x = frame.origin.x
        $0.y = frame.origin.y
        $0.width = frame.width
        $0.height = frame.height
    }
}

private func displayCaptureTruthPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil,
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data as Data
}

private func assertDisplayCaptureTruthImage(
    _ data: Data,
    width: Int,
    height: Int,
) throws {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == width)
    #expect(image.height == height)
}
