import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

final class MacosUseService: Macosusesdk_V1_MacosUse.ServiceProtocol {
    static let logger = MacosUseSDK.sdkLogger(category: "MacosUseService")
    let stateStore: AppStateStore
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry
    let system: SystemOperations

    init(stateStore: AppStateStore, operationStore: OperationStore, windowRegistry: WindowRegistry, system: SystemOperations = ProductionSystemOperations.shared) {
        self.stateStore = stateStore
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
        self.system = system
    }

    /// Resolve bundle ID from PID using NSRunningApplication.
    func resolveBundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Encode an offset into an opaque page token per AIP-158.
    /// The token is base64-encoded to prevent clients from relying on its structure.
    func encodePageToken(offset: Int) -> String {
        let tokenString = "offset:\(offset)"
        return Data(tokenString.utf8).base64EncodedString()
    }

    /// Decode an opaque page token to retrieve the offset per AIP-158.
    /// Throws invalidArgument if the token is malformed.
    func decodePageToken(_ token: String) throws -> Int {
        guard let data = Data(base64Encoded: token),
              let tokenString = String(data: data, encoding: .utf8)
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }

        let components = tokenString.split(separator: ":")
        guard components.count == 2, components[0] == "offset",
              let parsedOffset = Int(components[1]), parsedOffset >= 0
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }
        return parsedOffset
    }

    func createInput(request: ServerRequest<Macosusesdk_V1_CreateInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("createInput called")

        let inputId = req.inputID.isEmpty ? UUID().uuidString : req.inputID
        let pid: pid_t? = req.parent.isEmpty ? nil : try parsePID(fromName: req.parent)
        let name =
            req.parent.isEmpty ? "desktopInputs/\(inputId)" : "\(req.parent)/inputs/\(inputId)"

        let input = Macosusesdk_V1_Input.with {
            $0.name = name
            $0.action = req.input.action
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        }

        await stateStore.addInput(input)

        // Update to executing
        var executingInput = input
        executingInput.state = .executing
        await stateStore.addInput(executingInput)

        do {
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: req.input.action,
                pid: pid,
                showAnimation: req.input.action.showAnimation,
                animationDuration: req.input.action.animationDuration,
            )
            // Update to completed
            var completedInput = executingInput
            completedInput.state = .completed
            completedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(completedInput)
            return ServerResponse(message: completedInput)
        } catch {
            // Update to failed
            var failedInput = executingInput
            failedInput.state = .failed
            failedInput.error = error.localizedDescription
            failedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(failedInput)
            return ServerResponse(message: failedInput)
        }
    }

    func getInput(request: ServerRequest<Macosusesdk_V1_GetInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("getInput called")
        guard let input = await stateStore.getInput(name: req.name) else {
            throw RPCError(code: .notFound, message: "Input not found")
        }
        return ServerResponse(message: input)
    }

    func listInputs(request: ServerRequest<Macosusesdk_V1_ListInputsRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_ListInputsResponse>
    {
        let req = request.message
        Self.logger.info("listInputs called")
        let allInputs = await stateStore.listInputs(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedInputs = allInputs.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedInputs.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageInputs = Array(sortedInputs[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListInputsResponse.with {
            $0.inputs = pageInputs
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func captureScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureScreenshot] Capturing screen screenshot")

        // Determine display ID (0 = main display, nil = all displays)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture screen
        let result = try await ScreenshotCapture.captureScreen(
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) screenshot")
        return ServerResponse(message: response)
    }

    func captureElementScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureElementScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureElementScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureElementScreenshot] Capturing element screenshot")

        // Get element from registry
        guard let element = await ElementRegistry.shared.getElement(req.elementID) else {
            throw RPCError(
                code: .notFound,
                message: "Element not found: \(req.elementID)",
            )
        }

        // Check element has bounds (x, y, width, height)
        guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element has no bounds: \(req.elementID)",
            )
        }

        // Apply padding if specified
        let padding = CGFloat(req.padding)
        let bounds = CGRect(
            x: element.x - padding,
            y: element.y - padding,
            width: element.width + (padding * 2),
            height: element.height + (padding * 2),
        )

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture element region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureElementScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        response.elementID = req.elementID
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureElementScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) element screenshot")
        return ServerResponse(message: response)
    }

    func captureRegionScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureRegionScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureRegionScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureRegionScreenshot] Capturing region screenshot")

        // Validate region
        guard req.hasRegion else {
            throw RPCError(
                code: .invalidArgument,
                message: "Region is required",
            )
        }

        // Convert proto Region to CGRect
        let bounds = CGRect(
            x: req.region.x,
            y: req.region.y,
            width: req.region.width,
            height: req.region.height,
        )

        // Determine display ID (for multi-monitor setups)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureRegionScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureRegionScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) region screenshot")
        return ServerResponse(message: response)
    }
}
