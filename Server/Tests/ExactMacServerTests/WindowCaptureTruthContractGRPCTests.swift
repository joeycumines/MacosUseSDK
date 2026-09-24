import AppKit
import CoreGraphics
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftProtobuf
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct WindowCaptureTruthContractGRPCTests {
    @Test(arguments: [false, true])
    @MainActor
    func `production window configuration maps shadow intent to the ScreenCaptureKit shadow switch`(
        includeShadow: Bool,
    ) {
        let configuration = ScreenshotCapture.windowCaptureConfiguration(
            includeShadow: includeShadow,
        )
        #expect(configuration.ignoreShadowsSingleWindow == !includeShadow)
        #expect(!configuration.capturesShadowsOnly)
        #expect(configuration.ignoreGlobalClipSingleWindow)
    }

    @Test
    func `generated window capture forwards exact source and reports captured metadata`() async throws {
        let sink = WindowCaptureTruthSink(ocrResult: .text(""))
        let fixture = windowCaptureTruthFixture(sink: sink)

        try await withWindowCaptureTruthClient(fixture.composition) { client in
            let windowName = try await listWindowCaptureTruthName(
                client: client,
                parent: fixture.parent,
            )
            let response: Exactmac_V1_CaptureWindowScreenshotResponse = try await windowCaptureTruthUnary(
                client: client,
                request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                    $0.window = windowName
                    $0.format = .jpeg
                    $0.quality = 91
                    $0.shadowEnabled = true
                    $0.ocrEnabled = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
            )

            let invocation = try #require(await sink.lastInvocation)
            #expect(invocation.source.name == windowName)
            #expect(invocation.source.windowID == fixture.windowID)
            #expect(invocation.source.ownerPID == fixture.pid)
            #expect(invocation.source.processIdentity == nil)
            #expect(invocation.source.admittedFrame == fixture.frame)
            #expect(invocation.format == .jpeg)
            #expect(invocation.quality == 91)
            #expect(invocation.includeShadow)
            #expect(invocation.includeOCR)

            #expect(response.window == windowName)
            #expect(response.format == .jpeg)
            #expect(response.width == 208)
            #expect(response.height == 168)
            #expect(response.windowFrame == windowCaptureTruthRegion(fixture.frame))
            #expect(response.region == windowCaptureTruthRegion(fixture.frame.insetBy(dx: -2, dy: -2)))
            #expect(response.scale == 2)
            #expect(response.shadowIncluded)
            #expect(!response.clipped)
            #expect(response.ocrResult == .ocrText(""))
            #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
        }
    }

    @Test
    func `OCR not requested successful empty and partial failure remain distinct`() async throws {
        let statuses: [(Bool, ScreenshotOCRResult, WindowCaptureTruthOCRExpectation)] = [
            (false, .notRequested, .unset),
            (true, .text(""), .text("")),
            (
                true,
                .failure(.with {
                    $0.code = 13
                    $0.message = "OCR extraction failed"
                }),
                .failure(code: 13, message: "OCR extraction failed"),
            ),
        ]

        for (includeOCR, result, expectation) in statuses {
            let sink = WindowCaptureTruthSink(ocrResult: result)
            let fixture = windowCaptureTruthFixture(sink: sink)
            try await withWindowCaptureTruthClient(fixture.composition) { client in
                let windowName = try await listWindowCaptureTruthName(
                    client: client,
                    parent: fixture.parent,
                )
                let response: Exactmac_V1_CaptureWindowScreenshotResponse = try await windowCaptureTruthUnary(
                    client: client,
                    request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                        $0.window = windowName
                        $0.ocrEnabled = includeOCR
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                )

                switch expectation {
                case .unset:
                    #expect(response.ocrResult == nil)
                case let .text(text):
                    #expect(response.ocrResult == .ocrText(text))
                case let .failure(code, message):
                    guard case let .ocrError(status)? = response.ocrResult else {
                        Issue.record("Expected structured OCR failure")
                        return
                    }
                    #expect(status.code == code)
                    #expect(status.message == message)
                }
            }
        }
    }

    @Test
    func `OCR result must match whether extraction was requested`() async throws {
        let invalidResults: [(Bool, ScreenshotOCRResult)] = [
            (false, .text("unexpected")),
            (
                false,
                .failure(.with {
                    $0.code = 13
                    $0.message = "unexpected"
                }),
            ),
            (true, .notRequested),
            (true, .failure(.with { $0.code = 0 })),
            (true, .failure(.with { $0.code = 17 })),
        ]

        for (includeOCR, result) in invalidResults {
            let sink = WindowCaptureTruthSink(ocrResult: result)
            let fixture = windowCaptureTruthFixture(sink: sink)
            try await withWindowCaptureTruthClient(fixture.composition) { client in
                let windowName = try await listWindowCaptureTruthName(
                    client: client,
                    parent: fixture.parent,
                )
                await expectWindowCaptureTruthRPCError(.unavailable) {
                    let _: Exactmac_V1_CaptureWindowScreenshotResponse = try await windowCaptureTruthUnary(
                        client: client,
                        request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                            $0.window = windowName
                            $0.ocrEnabled = includeOCR
                        },
                        descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `mismatched captured source or output metadata fails unavailable`() async throws {
        for mismatch in WindowCaptureTruthMismatch.allCases {
            let sink = WindowCaptureTruthSink(mismatch: mismatch)
            let fixture = windowCaptureTruthFixture(sink: sink)
            try await withWindowCaptureTruthClient(fixture.composition) { client in
                let windowName = try await listWindowCaptureTruthName(
                    client: client,
                    parent: fixture.parent,
                )
                await expectWindowCaptureTruthRPCError(.unavailable) {
                    let _: Exactmac_V1_CaptureWindowScreenshotResponse = try await windowCaptureTruthUnary(
                        client: client,
                        request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                            $0.window = windowName
                            $0.shadowEnabled = true
                        },
                        descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `binding retirement while capture is blocked rejects late output`() async throws {
        let sink = WindowCaptureTruthSink(blocked: true)
        let fixture = windowCaptureTruthFixture(sink: sink)

        try await withWindowCaptureTruthClient(fixture.composition) { client in
            let windowName = try await listWindowCaptureTruthName(
                client: client,
                parent: fixture.parent,
            )
            let capture = Task {
                let response: Exactmac_V1_CaptureWindowScreenshotResponse = try await windowCaptureTruthUnary(
                    client: client,
                    request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                        $0.window = windowName
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                )
                return response
            }

            await sink.waitUntilEntered()
            fixture.system.cgWindowList = []
            try await fixture.composition.windowRegistry.refreshWindows(forPID: fixture.pid)
            await sink.release()

            do {
                _ = try await capture.value
                Issue.record("Expected stale window binding rejection")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
            #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
        }
    }

    @Test
    func `same public window cannot remap its private identity during capture`() async throws {
        let sink = WindowCaptureTruthSink(blocked: true)
        let fixture = windowCaptureTruthFixture(sink: sink)

        try await withWindowCaptureTruthClient(fixture.composition) { client in
            let windowName = try await listWindowCaptureTruthName(
                client: client,
                parent: fixture.parent,
            )
            let capture = Task {
                try await windowCaptureTruthUnary(
                    client: client,
                    request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                        $0.window = windowName
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                ) as Exactmac_V1_CaptureWindowScreenshotResponse
            }

            await sink.waitUntilEntered()
            fixture.system.axWindowIDHandler = { _ in fixture.windowID + 1 }
            await sink.release()

            do {
                _ = try await capture.value
                Issue.record("Expected exact window identity remap rejection")
            } catch let error as RPCError {
                #expect(error.code == .aborted || error.code == .failedPrecondition)
            }
            #expect(await fixture.composition.captureWorkOwner.activeCaptureCount() == 0)
        }
    }
}

private struct WindowCaptureTruthFixture {
    let parent: String
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let system: MockSystemOperations
    let composition: ExactMacServiceComposition
}

private func windowCaptureTruthFixture(
    sink: WindowCaptureTruthSink,
) -> WindowCaptureTruthFixture {
    let pid: pid_t = 5521
    let windowID: CGWindowID = 991
    let frame = CGRect(x: -30, y: -20, width: 100, height: 80)
    let windowElement = AXUIElementCreateApplication(pid_t(windowID))
    var position = frame.origin
    var size = frame.size
    let positionValue = AXValueCreate(.cgPoint, &position)!
    let sizeValue = AXValueCreate(.cgSize, &size)!
    let system = MockSystemOperations(
        cgWindowList: [
            [
                kCGWindowNumber as String: windowID,
                kCGWindowOwnerPID as String: pid,
                kCGWindowBounds as String: [
                    "X": frame.origin.x,
                    "Y": frame.origin.y,
                    "Width": frame.width,
                    "Height": frame.height,
                ],
                kCGWindowName as String: "Capture truth",
                kCGWindowLayer as String: Int32(0),
                kCGWindowIsOnscreen as String: true,
            ],
        ],
        axAttributes: [
            kAXWindowsAttribute as String: [windowElement],
            kAXRoleAttribute as String: kAXWindowRole as String,
            kAXPositionAttribute as String: positionValue,
            kAXSizeAttribute as String: sizeValue,
        ],
        axWindowIDHandler: { element in
            CFEqual(element, windowElement) ? windowID : nil
        },
    )
    let composition = ExactMacServiceComposition(
        system: system,
        legacyPIDResourceNamesForTests: true,
        screenshotCapture: sink,
    )
    return WindowCaptureTruthFixture(
        parent: "applications/\(pid)",
        pid: pid,
        windowID: windowID,
        frame: frame,
        system: system,
        composition: composition,
    )
}

private actor WindowCaptureTruthSink: ScreenshotCapturing {
    struct Invocation: Sendable {
        let source: WindowScreenshotCaptureSource
        let format: Exactmac_V1_ImageFormat
        let quality: Int32
        let includeShadow: Bool
        let includeOCR: Bool
    }

    private let mismatch: WindowCaptureTruthMismatch?
    private let ocrResult: ScreenshotOCRResult
    private let blocked: Bool
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var lastInvocation: Invocation?

    init(
        mismatch: WindowCaptureTruthMismatch? = nil,
        ocrResult: ScreenshotOCRResult = .notRequested,
        blocked: Bool = false,
    ) {
        self.mismatch = mismatch
        self.ocrResult = ocrResult
        self.blocked = blocked
    }

    func captureDisplay(
        _: DisplayTopologyDisplay,
        format _: Exactmac_V1_ImageFormat,
        quality _: Int32,
        includeOCR _: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        throw WindowCaptureTruthTestError.unexpectedCaptureKind
    }

    func captureRegion(
        _: CGRect,
        display _: DisplayTopologyDisplay,
        format _: Exactmac_V1_ImageFormat,
        quality _: Int32,
        includeOCR _: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        throw WindowCaptureTruthTestError.unexpectedCaptureKind
    }

    func captureWindow(
        _ source: WindowScreenshotCaptureSource,
        format: Exactmac_V1_ImageFormat,
        quality: Int32,
        includeShadow: Bool,
        includeOCR: Bool,
    ) async throws -> WindowScreenshotCaptureOutput {
        lastInvocation = Invocation(
            source: source,
            format: format,
            quality: quality,
            includeShadow: includeShadow,
            includeOCR: includeOCR,
        )
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if blocked {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        let windowFrame = mismatch == .windowFrame
            ? source.admittedFrame.offsetBy(dx: 1, dy: 0)
            : source.admittedFrame
        let logicalFrame = source.admittedFrame.insetBy(dx: -2, dy: -2)
        let outputScale = mismatch == .scale ? 1.5 : 2.0
        let pixelWidth: Int32 = mismatch == .pixelDimensions ? 207 : 208
        return try WindowScreenshotCaptureOutput(
            data: windowCaptureTruthImageData(
                format: format,
                width: 208,
                height: 168,
            ),
            format: mismatch == .format ? .tiff : format,
            pixelWidth: pixelWidth,
            pixelHeight: 168,
            sourceName: mismatch == .resourceName ? "applications/other/windows/other" : source.name,
            windowID: mismatch == .windowID ? source.windowID + 1 : source.windowID,
            ownerPID: mismatch == .ownerPID ? source.ownerPID + 1 : source.ownerPID,
            windowFrame: windowFrame,
            logicalFrame: mismatch == .logicalFrame
                ? logicalFrame.offsetBy(dx: 200, dy: 0)
                : logicalFrame,
            scale: outputScale,
            shadowIncluded: mismatch == .shadow ? !includeShadow : includeShadow,
            clipped: mismatch == .clipped,
            ocrResult: ocrResult,
        )
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func windowCaptureTruthImageData(
    format: Exactmac_V1_ImageFormat,
    width: Int,
    height: Int,
) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ), let image = context.makeImage()
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    let type: UTType = switch format {
    case .png:
        .png
    case .jpeg:
        .jpeg
    case .tiff:
        .tiff
    case .unspecified, .UNRECOGNIZED:
        throw CocoaError(.fileWriteUnknown)
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type.identifier as CFString,
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

private enum WindowCaptureTruthMismatch: CaseIterable, Sendable {
    case resourceName
    case windowID
    case ownerPID
    case format
    case windowFrame
    case logicalFrame
    case scale
    case pixelDimensions
    case shadow
    case clipped
}

private enum WindowCaptureTruthOCRExpectation {
    case unset
    case text(String)
    case failure(code: Int32, message: String)
}

private enum WindowCaptureTruthTestError: Error {
    case unexpectedCaptureKind
}

private func withWindowCaptureTruthClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let transport = InProcessTransport()
    let server = GRPCServer(transport: transport.server, services: [composition.exactMacService])
    let client = GRPCClient(transport: transport.client)
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

private func listWindowCaptureTruthName(
    client: GRPCClient<InProcessTransport.Client>,
    parent: String,
) async throws -> String {
    let response: Exactmac_V1_ListWindowsResponse = try await windowCaptureTruthUnary(
        client: client,
        request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
        descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
    )
    return try #require(response.windows.first?.name)
}

private func windowCaptureTruthUnary<
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

private func expectWindowCaptureTruthRPCError(
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

private func windowCaptureTruthRegion(_ frame: CGRect) -> Exactmac_Type_Region {
    .with {
        $0.x = frame.origin.x
        $0.y = frame.origin.y
        $0.width = frame.width
        $0.height = frame.height
    }
}
