// Copyright 2025 Joseph Cumines
//
// ScreenshotCapture - Screenshot capture utilities for macOS

import AppKit
import ApplicationServices
import Foundation
import MacosUseProto
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Utility for capturing screenshots with various options.
@MainActor
struct ScreenshotCapture {
    fileprivate nonisolated static let ciContext = CIContext()

    /// Capture the entire screen or a specific display.
    /// - Parameters:
    ///   - displayID: Optional display ID (0 for main display, nil for all displays)
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
        let display = content.displays.first { $0.displayID == (displayID ?? CGMainDisplayID()) }
            ?? content.displays.first

        guard let display else {
            throw ScreenshotError.captureFailedScreen
        }

        let cgImage = try await capture(filter: .init(display: display, excludingWindows: []))

        let width = cgImage.width
        let height = cgImage.height
        let imageData = try encodeImage(cgImage, format: format, quality: quality)

        var ocrText: String?
        if includeOCR {
            ocrText = try? extractText(from: cgImage)
        }

        return (imageData, Int32(width), Int32(height), ocrText)
    }

    /// Capture a specific window by ID.
    /// - Parameters:
    ///   - windowID: CGWindowID to capture
    ///   - includeShadow: Whether to include window shadow
    ///   - format: Image format (PNG, JPEG, TIFF)
    ///   - quality: JPEG quality (1-100, only applicable for JPEG)
    ///   - includeOCR: Whether to extract text via OCR
    /// - Returns: Captured image data and metadata
    static func captureWindow(
        windowID: CGWindowID,
        includeShadow: Bool = false,
        format: Macosusesdk_V1_ImageFormat = .png,
        quality: Int32 = 85,
        includeOCR: Bool = false,
    ) async throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        let content = try await SCShareableContent.current
        guard
            let window = content.windows.first(where: {
                $0.windowID == windowID && $0.isOnScreen
            })
        else {
            throw ScreenshotError.windowNotFound(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        // Configure to capture only the window, excluding the frame.
        config.capturesShadowsOnly = includeShadow
        config.shouldBeOpaque = !includeShadow

        let cgImage = try await capture(filter: filter, config: config)

        let width = cgImage.width
        let height = cgImage.height
        let imageData = try encodeImage(cgImage, format: format, quality: quality)

        var ocrText: String?
        if includeOCR {
            ocrText = try? extractText(from: cgImage)
        }

        return (imageData, Int32(width), Int32(height), ocrText)
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
        let display = content.displays.first { $0.frame.intersects(bounds) }
            ?? content.displays.first { $0.displayID == (displayID ?? CGMainDisplayID()) }
            ?? content.displays.first

        guard let display else {
            throw ScreenshotError.captureFailedRegion(bounds)
        }

        // Capture the entire display containing the region
        let fullImage = try await capture(filter: .init(display: display, excludingWindows: []))

        // The bounds are in screen coordinates, so we need to convert them to image coordinates.
        // The display's frame is also in screen coordinates.
        let cropRect = CGRect(
            x: bounds.origin.x - display.frame.origin.x,
            y: bounds.origin.y - display.frame.origin.y,
            width: bounds.width,
            height: bounds.height,
        )

        // Crop the image to the requested bounds
        guard let croppedImage = fullImage.cropping(to: cropRect) else {
            throw ScreenshotError.captureFailedRegion(bounds)
        }

        let width = croppedImage.width
        let height = croppedImage.height
        let imageData = try encodeImage(croppedImage, format: format, quality: quality)

        var ocrText: String?
        if includeOCR {
            ocrText = try? extractText(from: croppedImage)
        }

        return (imageData, Int32(width), Int32(height), ocrText)
    }

    private static func capture(
        filter: SCContentFilter,
        config: SCStreamConfiguration = .init(),
    ) async throws -> CGImage {
        // Default configuration for a single frame.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.width = 0 // Use source dimension
        config.height = 0 // Use source dimension
        config.queueDepth = 1

        let delegate = CaptureDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .main)

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            stream.startCapture { error in
                if let error {
                    // CRITICAL FIX: Hop to MainActor to avoid race with delegate methods
                    Task { @MainActor in
                        continuation.resume(throwing: error)
                        delegate.continuation = nil
                    }
                }
            }
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

private final class CaptureDelegate: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    typealias Continuation = CheckedContinuation<CGImage, Error>
    var continuation: Continuation?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType,
    ) {
        // We only need the first frame.
        stream.stopCapture()

        guard let continuation else { return }
        self.continuation = nil

        guard sampleBuffer.isValid, type == .screen else {
            continuation.resume(throwing: ScreenshotError.captureFailedGeneric)
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            continuation.resume(throwing: ScreenshotError.captureFailedGeneric)
            return
        }

        // Create a CIImage from the image buffer.
        let ciImage = CIImage(cvImageBuffer: imageBuffer)

        // Create a CGImage from the CIImage.
        let context = ScreenshotCapture.ciContext
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            continuation.resume(throwing: ScreenshotError.captureFailedGeneric)
            return
        }

        continuation.resume(returning: cgImage)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
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
