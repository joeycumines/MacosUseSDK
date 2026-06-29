// Copyright 2025 Joseph Cumines
//
// ScreenshotScaleTests - Unit tests for ScreenshotCapture.pixelScaleFactors.
// Verifies the point-to-pixel conversion used by captureRegion on Retina.

import CoreGraphics
import Foundation
@testable import MacosUseServer
import XCTest

/// Unit tests for the pixel scale factor computation in ScreenshotCapture.
/// These tests do NOT require ScreenCaptureKit or TCC permissions — they
/// verify the pure math that converts screen-point coordinates to image-pixel
/// coordinates for cropping.
final class ScreenshotScaleTests: XCTestCase {
    func testPixelScaleFactors_Retina_2x() {
        // 1512×982 point display captured at 3024×1964 pixels (2x Retina)
        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
            imageWidth: 3024,
            imageHeight: 1964,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        )
        XCTAssertEqual(scaleX, 2.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 2.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_NonRetina_1x() {
        // 2560×1440 point display captured at 2560×1440 pixels (1x non-Retina)
        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
            imageWidth: 2560,
            imageHeight: 1440,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        )
        XCTAssertEqual(scaleX, 1.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 1.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_ScaledDisplayMode() {
        // User selected "More Space": 3456×2234 points, but hardware is
        // 3024×1964 pixels (pointPixelScale < 1 — fewer pixels than points)
        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
            imageWidth: 3024,
            imageHeight: 1964,
            frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
        )
        XCTAssertEqual(scaleX, 0.875, accuracy: 0.01)
        XCTAssertEqual(scaleY, 0.879, accuracy: 0.01)
    }

    func testPixelScaleFactors_MultiMonitor_OffsetFrame() {
        // Secondary display offset in global coordinates — frame origin
        // doesn't affect the scale (only width/height matter)
        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
            imageWidth: 6016,
            imageHeight: 3384,
            frame: CGRect(x: -1801, y: -1692, width: 3008, height: 1692),
        )
        XCTAssertEqual(scaleX, 2.0, accuracy: 0.01)
        XCTAssertEqual(scaleY, 2.0, accuracy: 0.01)
    }

    func testPixelScaleFactors_ZeroFrame_ReturnsUnity() {
        // Division by zero guard — returns (1.0, 1.0) so caller's
        // CGImage.cropping(to:) returns nil and the error path handles it
        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
            imageWidth: 100,
            imageHeight: 100,
            frame: .zero,
        )
        XCTAssertEqual(scaleX, 1.0)
        XCTAssertEqual(scaleY, 1.0)
    }

    func testPixelScaleFactors_CropRectComputation() {
        // End-to-end verification: given a 2x Retina display and a request
        // to crop a 200×100 point region at offset (100, 50), verify the
        // crop rect in pixel coordinates is correct.
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let bounds = CGRect(x: 100, y: 50, width: 200, height: 100)

        let (scaleX, scaleY) = ScreenshotCapture.pixelScaleFactors(
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
}
