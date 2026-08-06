// Copyright 2025 Joseph Cumines
//
// ScreenshotCapture - Screenshot capture utilities for macOS

import AppKit
import ApplicationServices
import Foundation
import GRPCCore
import MacosUseProto
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

enum ScreenshotOCRResult: Sendable {
    case notRequested
    case text(String)
    case failure(Google_Rpc_Status)

    func validate(requested: Bool) throws {
        switch (requested, self) {
        case (false, .notRequested), (true, .text):
            return
        case let (true, .failure(status)) where (1 ... 16).contains(status.code):
            return
        case (false, .text), (false, .failure), (true, .notRequested):
            throw RPCError(
                code: .unavailable,
                message: "Screenshot OCR metadata is inconsistent with the request",
            )
        case (true, .failure):
            throw RPCError(
                code: .unavailable,
                message: "Screenshot OCR failure contains a non-error status code",
            )
        }
    }
}

struct ScreenshotCaptureOutput: Sendable {
    let data: Data
    let format: Macosusesdk_V1_ImageFormat
    let pixelWidth: Int32
    let pixelHeight: Int32
    let displayID: CGDirectDisplayID
    let logicalFrame: CGRect
    let scale: Double
    let ocrResult: ScreenshotOCRResult
}

struct WindowScreenshotCaptureSource: Sendable {
    let name: String
    let windowID: CGWindowID
    let ownerPID: pid_t
    let processIdentity: ApplicationProcessIdentity?
    let admittedFrame: CGRect
}

struct WindowScreenshotCaptureOutput: Sendable {
    let data: Data
    let format: Macosusesdk_V1_ImageFormat
    let pixelWidth: Int32
    let pixelHeight: Int32
    let sourceName: String
    let windowID: CGWindowID
    let ownerPID: pid_t
    let windowFrame: CGRect
    let logicalFrame: CGRect
    let scale: Double
    let shadowIncluded: Bool
    let clipped: Bool
    let ocrResult: ScreenshotOCRResult
}

protocol ScreenshotCapturing: Sendable {
    func captureDisplay(
        _ display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput

    func captureRegion(
        _ region: CGRect,
        display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput

    func captureWindow(
        _ source: WindowScreenshotCaptureSource,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeShadow: Bool,
        includeOCR: Bool,
    ) async throws -> WindowScreenshotCaptureOutput
}

struct ProductionScreenshotCapturer: ScreenshotCapturing {
    func captureDisplay(
        _ display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        try await ScreenshotCapture.captureDisplay(
            display,
            format: format,
            quality: quality,
            includeOCR: includeOCR,
        )
    }

    func captureRegion(
        _ region: CGRect,
        display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        try await ScreenshotCapture.captureRegion(
            region,
            display: display,
            format: format,
            quality: quality,
            includeOCR: includeOCR,
        )
    }

    func captureWindow(
        _ source: WindowScreenshotCaptureSource,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeShadow: Bool,
        includeOCR: Bool,
    ) async throws -> WindowScreenshotCaptureOutput {
        try await ScreenshotCapture.captureWindow(
            source,
            format: format,
            quality: quality,
            includeShadow: includeShadow,
            includeOCR: includeOCR,
        )
    }
}

/// Utility for capturing screenshots with various options.
@MainActor
struct ScreenshotCapture {
    static func captureDisplay(
        _ display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        let content = try await SCShareableContent.current
        let source = try exactDisplay(display, in: content)
        let filter = SCContentFilter(display: source, excludingWindows: [])
        try validateCaptureFilter(filter, against: display)
        let image = try await capture(filter: filter)
        try await revalidateCaptureDisplay(display)
        return try captureOutput(
            image: image,
            display: display,
            logicalFrame: display.frame,
            format: format,
            quality: quality,
            includeOCR: includeOCR,
        )
    }

    static func captureRegion(
        _ region: CGRect,
        display: DisplayTopologyDisplay,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) async throws -> ScreenshotCaptureOutput {
        guard EndpointSafeGeometry.containsValidEndpoints(
            region,
            requiresPositiveSize: true,
        ),
            display.frame.containsWithTolerance(region)
        else {
            throw RPCError(code: .invalidArgument, message: "Capture region is outside its display")
        }

        let content = try await SCShareableContent.current
        let source = try exactDisplay(display, in: content)
        let filter = SCContentFilter(display: source, excludingWindows: [])
        try validateCaptureFilter(filter, against: display)
        let fullImage = try await capture(filter: filter)
        try await revalidateCaptureDisplay(display)
        let scaleX = CGFloat(fullImage.width) / display.frame.width
        let scaleY = CGFloat(fullImage.height) / display.frame.height
        guard nearlyEqual(scaleX, CGFloat(display.scale)),
              nearlyEqual(scaleY, CGFloat(display.scale))
        else {
            throw RPCError(code: .unavailable, message: "Capture pixel scale changed")
        }

        let requestedPixels = CGRect(
            x: (region.minX - display.frame.minX) * scaleX,
            y: (region.minY - display.frame.minY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY,
        )
        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let pixelFrame = requestedPixels.integral.intersection(imageBounds)
        guard !pixelFrame.isNull,
              pixelFrame.width > 0,
              pixelFrame.height > 0,
              pixelFrame.containsWithTolerance(requestedPixels),
              let image = fullImage.cropping(to: pixelFrame)
        else {
            throw RPCError(code: .unavailable, message: "Capture region could not be quantized")
        }
        let logicalFrame = CGRect(
            x: display.frame.minX + pixelFrame.minX / scaleX,
            y: display.frame.minY + pixelFrame.minY / scaleY,
            width: pixelFrame.width / scaleX,
            height: pixelFrame.height / scaleY,
        )
        return try captureOutput(
            image: image,
            display: display,
            logicalFrame: logicalFrame,
            format: format,
            quality: quality,
            includeOCR: includeOCR,
        )
    }

    /// Capture the entire screen or a specific display.
    /// - Parameters:
    ///   - displayID: Exact display ID, or nil for the main display.
    ///   - format: Image format (PNG, JPEG, TIFF)
    ///   - quality: JPEG quality (1-100, only applicable for JPEG)
    ///   - includeOCR: Whether to extract text via OCR
    /// - Returns: Captured image data and metadata
    static func captureScreen(
        displayID: CGDirectDisplayID? = nil,
        format: Macosusesdk_V1_ImageFormat = .png,
        quality: Int32 = 85,
        includeOCR: Bool = false,
    ) async throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        let content = try await SCShareableContent.current
        let display = content.displays.first {
            $0.displayID == (displayID ?? CGMainDisplayID())
        }

        guard let display else {
            throw ScreenshotError.captureFailedScreen
        }

        let cgImage = try await capture(filter: .init(display: display, excludingWindows: []))

        let dimensions = try checkedImageDimensions(cgImage)
        let imageData = try encodeImage(cgImage, format: format, quality: quality)

        let ocrText = includeOCR ? try extractText(from: cgImage) : nil

        return (imageData, dimensions.width, dimensions.height, ocrText)
    }

    /// Capture one exact process-owned window.
    /// - Parameters:
    ///   - source: Exact public binding, CG ID, owner PID, process identity,
    ///     and admitted frame.
    ///   - includeShadow: Whether to include window shadow
    ///   - format: Image format (PNG, JPEG, TIFF)
    ///   - quality: JPEG quality (1-100, only applicable for JPEG)
    ///   - includeOCR: Whether to extract text via OCR
    /// - Returns: Captured image data and metadata
    static func captureWindow(
        _ source: WindowScreenshotCaptureSource,
        format: Macosusesdk_V1_ImageFormat = .png,
        quality: Int32 = 85,
        includeShadow: Bool = false,
        includeOCR: Bool = false,
    ) async throws -> WindowScreenshotCaptureOutput {
        let content = try await SCShareableContent.current
        guard
            let window = content.windows.first(where: {
                $0.windowID == source.windowID &&
                    $0.owningApplication?.processID == source.ownerPID &&
                    $0.isOnScreen
            }),
            window.frame.nearlyEquals(source.admittedFrame)
        else {
            throw RPCError(code: .unavailable, message: "Exact capture window source changed")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = windowCaptureConfiguration(includeShadow: includeShadow)
        let logicalFrame = filter.contentRect
        let scale = Double(filter.pointPixelScale)
        guard EndpointSafeGeometry.containsValidEndpoints(
            logicalFrame,
            requiresPositiveSize: true,
        ),
            scale.isFinite,
            scale > 0
        else {
            throw RPCError(code: .unavailable, message: "Window capture geometry is unavailable")
        }
        let image = try await capture(filter: filter, config: configuration)
        let dimensions = try checkedImageDimensions(image)
        guard abs(Double(image.width) - Double(logicalFrame.width) * scale) < 1,
              abs(Double(image.height) - Double(logicalFrame.height) * scale) < 1
        else {
            throw RPCError(code: .unavailable, message: "Window capture pixel geometry changed")
        }
        let verifiedContent = try await SCShareableContent.current
        guard
            let verifiedWindow = verifiedContent.windows.first(where: {
                $0.windowID == source.windowID &&
                    $0.owningApplication?.processID == source.ownerPID &&
                    $0.isOnScreen
            }),
            verifiedWindow.frame.nearlyEquals(window.frame),
            verifiedWindow.frame.nearlyEquals(source.admittedFrame)
        else {
            throw RPCError(code: .unavailable, message: "Exact capture window source changed during capture")
        }
        let verifiedFilter = SCContentFilter(desktopIndependentWindow: verifiedWindow)
        guard verifiedFilter.contentRect.nearlyEquals(logicalFrame),
              nearlyEqual(
                  CGFloat(verifiedFilter.pointPixelScale),
                  CGFloat(filter.pointPixelScale),
              ),
              logicalFrame.containsWithTolerance(verifiedWindow.frame)
        else {
            throw RPCError(code: .unavailable, message: "Window capture geometry changed during capture")
        }

        return try WindowScreenshotCaptureOutput(
            data: encodeImage(image, format: format, quality: quality),
            format: format,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            sourceName: source.name,
            windowID: verifiedWindow.windowID,
            ownerPID: verifiedWindow.owningApplication?.processID ?? 0,
            windowFrame: verifiedWindow.frame,
            logicalFrame: logicalFrame,
            scale: scale,
            shadowIncluded: includeShadow,
            clipped: false,
            ocrResult: ocrResult(for: image, requested: includeOCR),
        )
    }

    static func windowCaptureConfiguration(includeShadow: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = !includeShadow
        configuration.capturesShadowsOnly = false
        configuration.ignoreGlobalClipSingleWindow = true
        return configuration
    }

    /// Capture a specific screen region.
    /// - Parameters:
    ///   - bounds: CGRect in screen coordinates
    ///   - displayID: Optional display ID (for multi-monitor setups)
    ///   - format: Image format (PNG, JPEG, TIFF)
    ///   - quality: JPEG quality (1-100, only applicable for JPEG)
    ///   - includeOCR: Whether to extract text via OCR
    /// - Returns: Captured image data and metadata
    static func captureRegion(
        bounds: CGRect,
        displayID: CGDirectDisplayID? = nil,
        format: Macosusesdk_V1_ImageFormat = .png,
        quality: Int32 = 85,
        includeOCR: Bool = false,
    ) async throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        guard bounds.width > 0, bounds.height > 0 else {
            throw ScreenshotError.invalidRegion
        }

        let content = try await SCShareableContent.current
        let display: SCDisplay? = if let displayID {
            content.displays.first { $0.displayID == displayID }
        } else {
            content.displays.first { $0.frame.contains(bounds) }
        }

        guard let display else {
            throw ScreenshotError.captureFailedRegion(bounds)
        }

        // Capture the entire display containing the region.
        // The captured image is in PIXELS (e.g. 3024×1964 on a 1512×982
        // Retina display), but bounds and display.frame are in screen POINTS.
        // We must scale the crop rect from points to pixels to match the image.
        let fullImage = try await capture(filter: .init(display: display, excludingWindows: []))

        let (scaleX, scaleY) = try Self.pixelScaleFactors(
            imageWidth: fullImage.width,
            imageHeight: fullImage.height,
            frame: display.frame,
        )

        // Convert the requested bounds (screen points, Global Display
        // Coordinates with top-left origin) to image pixel coordinates.
        let cropRect = CGRect(
            x: (bounds.origin.x - display.frame.origin.x) * scaleX,
            y: (bounds.origin.y - display.frame.origin.y) * scaleY,
            width: bounds.width * scaleX,
            height: bounds.height * scaleY,
        )

        // Crop the image to the requested bounds
        guard let croppedImage = fullImage.cropping(to: cropRect) else {
            throw ScreenshotError.captureFailedRegion(bounds)
        }

        let dimensions = try checkedImageDimensions(croppedImage)
        let imageData = try encodeImage(croppedImage, format: format, quality: quality)

        let ocrText = includeOCR ? try extractText(from: croppedImage) : nil

        return (imageData, dimensions.width, dimensions.height, ocrText)
    }

    /// Computes pixel-to-point scale factors for converting a screen-point
    /// CGRect to image-pixel coordinates. Used by `captureRegion` to crop
    /// the correct sub-rect on Retina displays where the captured image is
    /// in pixels but the requested bounds are in screen points.
    ///
    nonisolated static func pixelScaleFactors(
        imageWidth: Int,
        imageHeight: Int,
        frame: CGRect,
    ) throws -> (scaleX: CGFloat, scaleY: CGFloat) {
        guard imageWidth > 0,
              imageHeight > 0,
              EndpointSafeGeometry.containsValidEndpoints(
                  frame,
                  requiresPositiveSize: true,
              )
        else {
            throw RPCError(
                code: .unavailable,
                message: "Capture pixel geometry is unavailable",
            )
        }
        let scaleX = CGFloat(imageWidth) / frame.width
        let scaleY = CGFloat(imageHeight) / frame.height
        guard scaleX.isFinite, scaleX > 0, scaleY.isFinite, scaleY > 0 else {
            throw RPCError(
                code: .unavailable,
                message: "Capture pixel scale is unavailable",
            )
        }
        return (scaleX, scaleY)
    }

    nonisolated static func checkedNativePixelDimensions(
        frame: CGRect,
        scale: CGFloat,
    ) throws -> (width: Int, height: Int) {
        guard EndpointSafeGeometry.containsValidEndpoints(
            frame,
            requiresPositiveSize: true,
        ),
            scale.isFinite,
            scale > 0
        else {
            throw RPCError(
                code: .unavailable,
                message: "Capture source geometry is unavailable",
            )
        }

        let rawWidth = frame.width * scale
        let rawHeight = frame.height * scale
        guard rawWidth.isFinite, rawWidth > 0, rawHeight.isFinite, rawHeight > 0 else {
            throw RPCError(
                code: .unavailable,
                message: "Capture pixel geometry is unavailable",
            )
        }
        guard rawWidth <= CGFloat(Int32.max), rawHeight <= CGFloat(Int32.max) else {
            throw RPCError(
                code: .resourceExhausted,
                message: "Capture pixel dimensions are too large",
            )
        }

        let width = Int(rawWidth.rounded())
        let height = Int(rawHeight.rounded())
        guard width > 0, height > 0 else {
            throw RPCError(
                code: .unavailable,
                message: "Capture pixel dimensions are unavailable",
            )
        }
        return (width, height)
    }

    private static func capture(
        filter: SCContentFilter,
        config: SCStreamConfiguration = .init(),
    ) async throws -> CGImage {
        // macOS 15 rejects width=0/height=0 (the old "use source dimension"
        // sentinel). Derive native pixel dimensions from the filter itself —
        // contentRect gives the source rect in screen points, and
        // pointPixelScale gives the pixel-per-point ratio (2.0 on Retina,
        // 1.0 on non-Retina, respects user-selected scaled display modes).
        // This is the canonical pattern from Apple's sample code.
        // Ref: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect
        // Ref: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale
        let scale = CGFloat(filter.pointPixelScale)
        let dimensions = try checkedNativePixelDimensions(
            frame: filter.contentRect,
            scale: scale,
        )
        config.width = dimensions.width
        config.height = dimensions.height

        // Use SCScreenshotManager for single-frame captures (macOS 14+).
        // This replaces the SCStream + CaptureDelegate + continuation pattern,
        // eliminating the startCapture completion-handler race entirely.
        // Ref: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config,
        )
    }

    private static func exactDisplay(
        _ expected: DisplayTopologyDisplay,
        in content: SCShareableContent,
    ) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == expected.displayID }),
              display.frame.nearlyEquals(expected.frame)
        else {
            throw RPCError(code: .unavailable, message: "Capture display topology changed")
        }
        return display
    }

    private static func revalidateCaptureDisplay(
        _ expected: DisplayTopologyDisplay,
    ) async throws {
        let content = try await SCShareableContent.current
        let source = try exactDisplay(expected, in: content)
        let filter = SCContentFilter(display: source, excludingWindows: [])
        try validateCaptureFilter(filter, against: expected)
    }

    private static func validateCaptureFilter(
        _ filter: SCContentFilter,
        against display: DisplayTopologyDisplay,
    ) throws {
        guard filter.contentRect.nearlyEquals(display.frame),
              nearlyEqual(CGFloat(filter.pointPixelScale), CGFloat(display.scale))
        else {
            throw RPCError(code: .unavailable, message: "Capture display geometry changed")
        }
    }

    private static func captureOutput(
        image: CGImage,
        display: DisplayTopologyDisplay,
        logicalFrame: CGRect,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
        includeOCR: Bool,
    ) throws -> ScreenshotCaptureOutput {
        let dimensions = try checkedImageDimensions(image)
        return try ScreenshotCaptureOutput(
            data: encodeImage(image, format: format, quality: quality),
            format: format,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            displayID: display.displayID,
            logicalFrame: logicalFrame,
            scale: display.scale,
            ocrResult: ocrResult(for: image, requested: includeOCR),
        )
    }

    private static func checkedImageDimensions(
        _ image: CGImage,
    ) throws -> (width: Int32, height: Int32) {
        guard image.width > 0, image.height > 0 else {
            throw RPCError(code: .unavailable, message: "Captured image dimensions are unavailable")
        }
        guard image.width <= Int(Int32.max), image.height <= Int(Int32.max) else {
            throw RPCError(code: .resourceExhausted, message: "Captured image dimensions are too large")
        }
        return (Int32(image.width), Int32(image.height))
    }

    private static func ocrResult(
        for image: CGImage,
        requested: Bool,
    ) -> ScreenshotOCRResult {
        guard requested else { return .notRequested }
        do {
            return try .text(extractText(from: image))
        } catch {
            return .failure(
                Google_Rpc_Status.with {
                    $0.code = 13
                    $0.message = "OCR extraction failed"
                },
            )
        }
    }

    /// Encode a CGImage to the requested format.
    private static func encodeImage(
        _ cgImage: CGImage,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
    ) throws -> Data {
        let data = NSMutableData()

        let utType: UTType =
            switch format {
            case .png, .unspecified:
                .png
            case .jpeg:
                .jpeg
            case .tiff:
                .tiff
            case .UNRECOGNIZED:
                .png
            }

        // Create image destination
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                utType.identifier as CFString,
                1,
                nil,
            )
        else {
            throw ScreenshotError.encodingFailed(format)
        }

        // Set JPEG quality if applicable
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            let clampedQuality = max(0, min(100, quality))
            properties[kCGImageDestinationLossyCompressionQuality] = Double(clampedQuality) / 100.0
        }

        // Add image to destination
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        // Finalize
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.encodingFailed(format)
        }

        return data as Data
    }

    /// Extract text from a CGImage using Vision framework.
    /// Note: Internal visibility to allow unit testing of OCR functionality.
    static func extractText(from cgImage: CGImage) throws -> String {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()

        // Configure for fast recognition (trade off some accuracy)
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true

        try requestHandler.perform([request])

        guard let observations = request.results else {
            return ""
        }

        // Concatenate all recognized text
        let recognizedStrings = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        return recognizedStrings.joined(separator: "\n")
    }
}

private extension CGRect {
    func nearlyEquals(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        nearlyEqual(minX, other.minX, tolerance: tolerance) &&
            nearlyEqual(minY, other.minY, tolerance: tolerance) &&
            nearlyEqual(width, other.width, tolerance: tolerance) &&
            nearlyEqual(height, other.height, tolerance: tolerance)
    }

    func containsWithTolerance(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        other.minX >= minX - tolerance &&
            other.minY >= minY - tolerance &&
            other.maxX <= maxX + tolerance &&
            other.maxY <= maxY + tolerance
    }
}

private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

enum ScreenshotError: Error, CustomStringConvertible {
    case captureFailedScreen
    case captureFailedWindow(CGWindowID)
    case captureFailedRegion(CGRect)
    case captureFailedGeneric
    case invalidRegion
    case encodingFailed(Macosusesdk_V1_ImageFormat)
    case windowNotFound(CGWindowID)
    case elementNotFound(String)

    var description: String {
        switch self {
        case .captureFailedScreen:
            "Failed to capture screen"
        case let .captureFailedWindow(windowID):
            "Failed to capture window \(windowID)"
        case let .captureFailedRegion(bounds):
            "Failed to capture region \(bounds)"
        case .captureFailedGeneric:
            "Screenshot capture failed for an unknown reason"
        case .invalidRegion:
            "Invalid region bounds (width/height must be > 0)"
        case let .encodingFailed(format):
            "Failed to encode image in format \(format)"
        case let .windowNotFound(windowID):
            "Window \(windowID) not found"
        case let .elementNotFound(elementID):
            "Element \(elementID) not found"
        }
    }
}
