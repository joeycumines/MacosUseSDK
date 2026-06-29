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

        // shouldBeOpaque controls the alpha channel:
        //   includeShadow == true  → alpha channel (shadow blends with background)
        //   includeShadow == false → fully opaque (no transparency)
        // Note: capturesShadowsOnly was incorrectly set to includeShadow,
        // which would capture ONLY the shadow (not the window content).
        // It is now left at the default (false) to always capture the window.
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
        // macOS 15 rejects width=0/height=0 (the old "use source dimension"
        // sentinel). Derive native pixel dimensions from the filter itself —
        // contentRect gives the source rect in screen points, and
        // pointPixelScale gives the pixel-per-point ratio (2.0 on Retina,
        // 1.0 on non-Retina, respects user-selected scaled display modes).
        // This is the canonical pattern from Apple's sample code.
        // Ref: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect
        // Ref: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)

        // Use SCScreenshotManager for single-frame captures (macOS 14+).
        // This replaces the SCStream + CaptureDelegate + continuation pattern,
        // eliminating the startCapture completion-handler race entirely.
        // Ref: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config,
        )
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
