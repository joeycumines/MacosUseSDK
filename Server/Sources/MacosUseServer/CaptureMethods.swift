import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseService {
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

        // Validate element ID is not empty
        guard !req.elementID.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "element_id is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "element_id",
            )
        }

        // Validate padding is non-negative
        guard req.padding >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "padding must be a non-negative number",
                reason: "INVALID_DIMENSION",
                field: "padding",
                value: String(req.padding),
            )
        }

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

        // Validate region coordinates are finite
        guard req.region.x.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "region.x must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "region.x",
                value: String(req.region.x),
            )
        }
        guard req.region.y.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "region.y must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "region.y",
                value: String(req.region.y),
            )
        }
        guard req.region.width.isFinite, req.region.width > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "region.width must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "region.width",
                value: String(req.region.width),
            )
        }
        guard req.region.height.isFinite, req.region.height > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "region.height must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "region.height",
                value: String(req.region.height),
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
