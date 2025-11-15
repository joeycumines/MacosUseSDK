// Copyright 2025 Joseph Cumines
//
// ScreenshotCapture - Screenshot capture utilities for macOS

import AppKit
import ApplicationServices
import Foundation
import MacosUseSDKProtos
import Vision

/// Utility for capturing screenshots with various options.
@MainActor
struct ScreenshotCapture {
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
    ) throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        // Get display ID
        let display = displayID ?? CGMainDisplayID()

        // Capture display
        guard let cgImage = CGDisplayCreateImage(display) else {
            throw ScreenshotError.captureFailedScreen
        }

        // Convert to NSImage
        let width = cgImage.width
        let height = cgImage.height

        // Encode to requested format
        let imageData = try encodeImage(cgImage, format: format, quality: quality)

        // Extract OCR text if requested
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
    ) throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        // Determine window list options
        let options: CGWindowListOption =
            includeShadow
                ? [.optionIncludingWindow]
                : [.optionIncludingWindow, .excludeDesktopElements]

        // Create window image
        guard
            let cgImage = CGWindowListCreateImage(
                .null,
                options,
                windowID,
                [.boundsIgnoreFraming, .bestResolution],
            )
        else {
            throw ScreenshotError.captureFailedWindow(windowID)
        }

        let width = cgImage.width
        let height = cgImage.height

        // Encode to requested format
        let imageData = try encodeImage(cgImage, format: format, quality: quality)

        // Extract OCR text if requested
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
    ) throws -> (data: Data, width: Int32, height: Int32, ocrText: String?) {
        // Validate bounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw ScreenshotError.invalidRegion
        }

        // Capture screen image for the specific display
        let display = displayID ?? CGMainDisplayID()

        // Create image from window list (more flexible than CGDisplayCreateImage for regions)
        guard
            let fullImage = CGWindowListCreateImage(
                bounds,
                [.optionOnScreenOnly],
                kCGNullWindowID,
                [.bestResolution],
            )
        else {
            throw ScreenshotError.captureFailedRegion(bounds)
        }

        let width = fullImage.width
        let height = fullImage.height

        // Encode to requested format
        let imageData = try encodeImage(fullImage, format: format, quality: quality)

        // Extract OCR text if requested
        var ocrText: String?
        if includeOCR {
            ocrText = try? extractText(from: fullImage)
        }

        return (imageData, Int32(width), Int32(height), ocrText)
    }

    // MARK: - Image Encoding

    /// Encode a CGImage to the requested format.
    private static func encodeImage(
        _ cgImage: CGImage,
        format: Macosusesdk_V1_ImageFormat,
        quality: Int32,
    ) throws -> Data {
        let data = NSMutableData()

        // Determine UTType for the format
        let utType: CFString =
            switch format {
            case .png, .unspecified:
                kUTTypePNG
            case .jpeg:
                kUTTypeJPEG
            case .tiff:
                kUTTypeTIFF
            case .UNRECOGNIZED:
                kUTTypePNG
            }

        // Create image destination
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                utType,
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

    // MARK: - OCR Text Extraction

    /// Extract text from a CGImage using Vision framework.
    private static func extractText(from cgImage: CGImage) throws -> String {
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

// MARK: - Screenshot Errors

enum ScreenshotError: Error, CustomStringConvertible {
    case captureFailedScreen
    case captureFailedWindow(CGWindowID)
    case captureFailedRegion(CGRect)
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
