// Copyright 2025 Joseph Cumines
//
// ScreenshotScaleTests - Unit tests for ScreenshotCapture.pixelScaleFactors.
// Verifies the point-to-pixel conversion used by captureRegion on Retina.

import CoreGraphics
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import ImageIO
import ScreenCaptureKit
import XCTest

/// Unit tests for the pixel scale factor computation in ScreenshotCapture.
/// These tests do NOT require ScreenCaptureKit or TCC permissions — they
/// verify the pure math that converts screen-point coordinates to image-pixel
/// coordinates for cropping.
@MainActor
final class ScreenshotScaleTests: XCTestCase {
    func testPixelScaleFactors_Retina_2x() throws {
        // 1512×982 point display captured at 3024×1964 pixels (2x Retina)
        let (scaleX, scaleY) = try ScreenshotCapture.pixelScaleFactors(
            imageWidth: 3024,
            imageHeight: 1964,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        )
        XCTAssertEqual(scaleX, 2.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 2.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_NonRetina_1x() throws {
        // 2560×1440 point display captured at 2560×1440 pixels (1x non-Retina)
        let (scaleX, scaleY) = try ScreenshotCapture.pixelScaleFactors(
            imageWidth: 2560,
            imageHeight: 1440,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        )
        XCTAssertEqual(scaleX, 1.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 1.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_ScaledDisplayMode() throws {
        // User selected "More Space": 3456×2234 points, but hardware is
        // 3024×1964 pixels (pointPixelScale < 1 — fewer pixels than points)
        let (scaleX, scaleY) = try ScreenshotCapture.pixelScaleFactors(
            imageWidth: 3024,
            imageHeight: 1964,
            frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
        )
        XCTAssertEqual(scaleX, 0.875, accuracy: 0.01)
        XCTAssertEqual(scaleY, 0.879, accuracy: 0.01)
    }

    func testPixelScaleFactors_MultiMonitor_OffsetFrame() throws {
        // Secondary display offset in global coordinates — frame origin
        // doesn't affect the scale (only width/height matter)
        let (scaleX, scaleY) = try ScreenshotCapture.pixelScaleFactors(
            imageWidth: 6016,
            imageHeight: 3384,
            frame: CGRect(x: -1801, y: -1692, width: 3008, height: 1692),
        )
        XCTAssertEqual(scaleX, 2.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 2.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_RejectsInvalidFrame() {
        XCTAssertThrowsError(
            try ScreenshotCapture.pixelScaleFactors(
                imageWidth: 100,
                imageHeight: 100,
                frame: .zero,
            ),
        )
        XCTAssertThrowsError(
            try ScreenshotCapture.pixelScaleFactors(
                imageWidth: 100,
                imageHeight: 100,
                frame: CGRect(
                    x: CGFloat.greatestFiniteMagnitude,
                    y: 0,
                    width: CGFloat.greatestFiniteMagnitude,
                    height: 1,
                ),
            ),
        )
        XCTAssertThrowsError(
            try ScreenshotCapture.pixelScaleFactors(
                imageWidth: 100,
                imageHeight: 100,
                frame: CGRect(
                    x: CGFloat.greatestFiniteMagnitude,
                    y: 0,
                    width: 1,
                    height: 1,
                ),
            ),
        )
    }

    func testCheckedNativePixelDimensions() throws {
        let dimensions = try ScreenshotCapture.checkedNativePixelDimensions(
            frame: CGRect(x: -100, y: -50, width: 1512, height: 982),
            scale: 2,
        )
        XCTAssertEqual(dimensions.width, 3024)
        XCTAssertEqual(dimensions.height, 1964)
    }

    func testCheckedNativePixelDimensionsRejectsRepresentationalExcess() {
        XCTAssertThrowsError(
            try ScreenshotCapture.checkedNativePixelDimensions(
                frame: CGRect(x: 0, y: 0, width: CGFloat(Int32.max), height: 1),
                scale: 2,
            ),
        ) { error in
            XCTAssertEqual((error as? RPCError)?.code, .resourceExhausted)
        }
    }

    func testPixelScaleFactors_CropRectComputation() throws {
        // End-to-end verification: given a 2x Retina display and a request
        // to crop a 200×100 point region at offset (100, 50), verify the
        // crop rect in pixel coordinates is correct.
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let bounds = CGRect(x: 100, y: 50, width: 200, height: 100)

        let (scaleX, scaleY) = try ScreenshotCapture.pixelScaleFactors(
            imageWidth: 3024,
            imageHeight: 1964,
            frame: displayFrame,
        )

        let cropRect = CGRect(
            x: (bounds.origin.x - displayFrame.origin.x) * scaleX,
            y: (bounds.origin.y - displayFrame.origin.y) * scaleY,
            width: bounds.width * scaleX,
            height: bounds.height * scaleY,
        )

        XCTAssertEqual(cropRect.origin.x, 200, accuracy: 0.1)
        XCTAssertEqual(cropRect.origin.y, 100, accuracy: 0.1)
        XCTAssertEqual(cropRect.width, 400, accuracy: 0.1)
        XCTAssertEqual(cropRect.height, 200, accuracy: 0.1)
    }

    func testCaptureConfigurationDoesNotDisableAlpha() {
        for includeShadow in [false, true] {
            let configuration = ScreenshotCapture.windowCaptureConfiguration(
                includeShadow: includeShadow,
            )
            XCTAssertFalse(
                configuration.shouldBeOpaque,
                "Alpha must not depend on shadow selection (includeShadow=\(includeShadow))",
            )
        }
    }

    func testPNGAndTIFFPreserveAlphaWhileJPEGIsOpaque() throws {
        let source = try makeAlphaImage()

        let lossless = try [Exactmac_V1_ImageFormat.png, .tiff].map { format in
            try ScreenshotCapture.encodeImage(source, format: format, quality: 0)
        }
        for data in lossless {
            let decoded = try decodeImage(data)
            let alpha = try alphaValues(decoded)
            XCTAssertTrue(alpha.contains(0), "Lossless output must retain transparent pixels")
            XCTAssertTrue(alpha.contains(255), "Lossless output must retain opaque pixels")
        }

        let jpeg = try ScreenshotCapture.encodeImage(source, format: .jpeg, quality: 85)
        let jpegAlpha = try alphaValues(decodeImage(jpeg))
        XCTAssertTrue(
            jpegAlpha.allSatisfy { $0 == 255 },
            "JPEG output must be opaque because JPEG has no alpha channel",
        )
    }

    private func makeAlphaImage() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue,
            ),
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    private func decodeImage(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func alphaValues(_ image: CGImage) throws -> [UInt8] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue,
            ),
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data)
        let bytes = pointer.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return (0 ..< image.width * image.height).map { bytes[$0 * 4 + 3] }
    }
}
