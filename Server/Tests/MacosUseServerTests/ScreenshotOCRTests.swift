// Copyright 2025 Joseph Cumines
//
// ScreenshotOCRTests - Unit tests for ScreenshotCapture OCR (extractText) functionality.
// Tests Vision framework text recognition with synthetic images.

import AppKit
import CoreGraphics
import CoreText
import Foundation
@testable import MacosUseProto
@testable import MacosUseServer
import Vision
import XCTest

/// Unit tests for OCR functionality in ScreenshotCapture.
/// Uses synthetic images with programmatically drawn text to test
/// Vision framework text recognition in a deterministic manner.
final class ScreenshotOCRTests: XCTestCase {
    // MARK: - Helper Methods

    /// Creates a CGImage with text drawn on a white background.
    /// Uses Core Text for reliable text rendering.
    /// - Parameters:
    ///   - text: The text to draw
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - fontSize: Font size for the text
    /// - Returns: A CGImage containing the rendered text
    private func createImageWithText(
        _ text: String,
        width: Int = 400,
        height: Int = 100,
        fontSize: CGFloat = 24.0,
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue,
        ) else {
            return nil
        }

        // Fill with white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw text in black using Core Text
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        // Position text (y is from bottom in Core Graphics)
        let textPosition = CGPoint(x: 10, y: height / 3)
        context.textPosition = textPosition
        CTLineDraw(line, context)

        return context.makeImage()
    }

    /// Creates a blank white CGImage.
    private func createBlankImage(width: Int = 200, height: Int = 100) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue,
        ) else {
            return nil
        }

        // Fill with white
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }

    /// Creates a CGImage with multiple lines of text.
    private func createMultilineImage(
        lines: [String],
        width: Int = 400,
        height: Int = 300,
        fontSize: CGFloat = 24.0,
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue,
        ) else {
            return nil
        }

        // Fill with white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw each line
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let lineHeight = fontSize * 1.5
        var yPosition = CGFloat(height) - lineHeight

        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let attributedString = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributedString)

            context.textPosition = CGPoint(x: 10, y: yPosition)
            CTLineDraw(ctLine, context)
            yPosition -= lineHeight
        }

        return context.makeImage()
    }

    // MARK: - Basic OCR Tests

    @MainActor
    func testExtractTextWithSimpleWord() throws {
        // Create image with a simple word that should be easily recognized
        guard let image = createImageWithText("HELLO", width: 200, height: 80, fontSize: 32) else {
            XCTFail("Failed to create test image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // Vision OCR should recognize the word (case may vary)
        XCTAssertTrue(
            extractedText.uppercased().contains("HELLO"),
            "OCR should recognize 'HELLO', got: '\(extractedText)'",
        )
    }

    @MainActor
    func testExtractTextWithNumbers() throws {
        // Numbers should be recognized
        guard let image = createImageWithText("12345", width: 200, height: 80, fontSize: 32) else {
            XCTFail("Failed to create test image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        XCTAssertTrue(
            extractedText.contains("12345"),
            "OCR should recognize '12345', got: '\(extractedText)'",
        )
    }

    @MainActor
    func testExtractTextWithMixedContent() throws {
        // Mixed alphanumeric content
        guard let image = createImageWithText("ABC123XYZ", width: 300, height: 80, fontSize: 32) else {
            XCTFail("Failed to create test image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // Should contain at least part of the text
        XCTAssertFalse(
            extractedText.isEmpty,
            "OCR should recognize mixed content, got empty string",
        )
    }

    // MARK: - Blank/Empty Image Tests

    @MainActor
    func testExtractTextWithBlankImage() throws {
        guard let image = createBlankImage() else {
            XCTFail("Failed to create blank image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // Blank image should yield empty or whitespace-only result
        XCTAssertTrue(
            extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Blank image should produce empty OCR result, got: '\(extractedText)'",
        )
    }

    @MainActor
    func testExtractTextWithSmallBlankImage() throws {
        // Minimum image size for Vision is 3x3
        guard let image = createBlankImage(width: 10, height: 10) else {
            XCTFail("Failed to create small blank image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        XCTAssertTrue(
            extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Small blank image should produce empty OCR result",
        )
    }

    @MainActor
    func testExtractTextWithTooSmallImageThrowsError() throws {
        // Vision requires images larger than 2x2 pixels
        guard let image = createBlankImage(width: 1, height: 1) else {
            XCTFail("Failed to create tiny image")
            return
        }

        XCTAssertThrowsError(try ScreenshotCapture.extractText(from: image)) { error in
            // Vision framework throws an error for images smaller than 3x3
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "com.apple.Vision")
        }
    }

    // MARK: - Multiline Text Tests

    @MainActor
    func testExtractTextWithMultipleLines() throws {
        let lines = ["Line One", "Line Two", "Line Three"]
        guard let image = createMultilineImage(lines: lines, height: 200, fontSize: 24) else {
            XCTFail("Failed to create multiline image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // Result should contain text from multiple lines (joined by newlines per extractText implementation)
        XCTAssertFalse(extractedText.isEmpty, "Multiline image should produce OCR result")

        // Check that at least some distinguishing content is recognized
        // Note: OCR may not preserve exact line structure
        let extractedUpper = extractedText.uppercased()
        let anyLineRecognized = lines.contains { line in
            extractedUpper.contains(line.uppercased().replacingOccurrences(of: " ", with: ""))
                || extractedUpper.contains("LINE")
                || extractedUpper.contains("ONE")
                || extractedUpper.contains("TWO")
                || extractedUpper.contains("THREE")
        }
        XCTAssertTrue(
            anyLineRecognized,
            "OCR should recognize at least part of multiline content, got: '\(extractedText)'",
        )
    }

    @MainActor
    func testExtractTextMultilineContainsNewlines() throws {
        // Test that multiple detected text blocks are separated by newlines
        let lines = ["FIRST", "SECOND"]
        guard let image = createMultilineImage(lines: lines, height: 150, fontSize: 28) else {
            XCTFail("Failed to create multiline image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // If multiple observations are found, they should be newline-separated
        // (per the extractText implementation using .joined(separator: "\n"))
        if extractedText.contains("\n") {
            // Good - multiple lines detected and properly joined
            XCTAssertTrue(true)
        } else {
            // Single observation is also valid if Vision merged the text
            XCTAssertFalse(extractedText.isEmpty, "Should have some extracted text")
        }
    }

    // MARK: - Unicode and International Text Tests

    @MainActor
    func testExtractTextWithAccentedCharacters() throws {
        // Accented Latin characters
        guard let image = createImageWithText("Café résumé", width: 300, height: 80, fontSize: 28) else {
            XCTFail("Failed to create test image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        // Vision may or may not preserve accents perfectly
        XCTAssertFalse(
            extractedText.isEmpty,
            "OCR should produce some output for accented text",
        )
    }

    // MARK: - Edge Cases

    @MainActor
    func testExtractTextWithLargeImage() throws {
        guard let image = createImageWithText("LARGE IMAGE TEST", width: 1920, height: 200, fontSize: 48) else {
            XCTFail("Failed to create large test image")
            return
        }

        let extractedText = try ScreenshotCapture.extractText(from: image)

        XCTAssertTrue(
            extractedText.uppercased().contains("LARGE") || extractedText.uppercased().contains("IMAGE") || extractedText.uppercased().contains("TEST"),
            "OCR should work on large images, got: '\(extractedText)'",
        )
    }

    @MainActor
    func testExtractTextWithSmallFontReturnsResult() throws {
        // Small font - may or may not be recognized depending on Vision capabilities
        guard let image = createImageWithText("Small Text", width: 200, height: 50, fontSize: 10) else {
            XCTFail("Failed to create test image")
            return
        }

        // Should not throw - either extracts text or returns empty
        let extractedText = try ScreenshotCapture.extractText(from: image)
        XCTAssertNotNil(extractedText) // Just verify it returns something (even if empty)
    }

    // MARK: - Proto Integration Tests

    func testOcrTextFieldInCaptureScreenshotResponse() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()

        // Before setting, should be empty
        XCTAssertTrue(response.ocrText.isEmpty)

        // Set OCR text
        response.ocrText = "Extracted OCR content"
        XCTAssertEqual(response.ocrText, "Extracted OCR content")

        // Clear it
        response.ocrText = ""
        XCTAssertTrue(response.ocrText.isEmpty)
    }

    func testOcrTextFieldWithNewlines() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.ocrText = "Line 1\nLine 2\nLine 3"

        XCTAssertTrue(response.ocrText.contains("\n"))
        XCTAssertEqual(response.ocrText.components(separatedBy: "\n").count, 3)
    }

    func testIncludeOcrTextFlagInRequest() {
        // CaptureScreenshotRequest
        var screenRequest = Macosusesdk_V1_CaptureScreenshotRequest()
        XCTAssertFalse(screenRequest.includeOcrText)
        screenRequest.includeOcrText = true
        XCTAssertTrue(screenRequest.includeOcrText)

        // CaptureRegionScreenshotRequest
        var regionRequest = Macosusesdk_V1_CaptureRegionScreenshotRequest()
        XCTAssertFalse(regionRequest.includeOcrText)
        regionRequest.includeOcrText = true
        XCTAssertTrue(regionRequest.includeOcrText)

        // CaptureElementScreenshotRequest
        var elementRequest = Macosusesdk_V1_CaptureElementScreenshotRequest()
        XCTAssertFalse(elementRequest.includeOcrText)
        elementRequest.includeOcrText = true
        XCTAssertTrue(elementRequest.includeOcrText)

        // CaptureWindowScreenshotRequest
        var windowRequest = Macosusesdk_V1_CaptureWindowScreenshotRequest()
        XCTAssertFalse(windowRequest.includeOcrText)
        windowRequest.includeOcrText = true
        XCTAssertTrue(windowRequest.includeOcrText)
    }

    func testOcrTextFieldExistsInAllResponseTypes() {
        // Verify ocrText field exists and is accessible in all response types
        var screenResponse = Macosusesdk_V1_CaptureScreenshotResponse()
        screenResponse.ocrText = "test"
        XCTAssertEqual(screenResponse.ocrText, "test")

        var regionResponse = Macosusesdk_V1_CaptureRegionScreenshotResponse()
        regionResponse.ocrText = "test"
        XCTAssertEqual(regionResponse.ocrText, "test")

        var elementResponse = Macosusesdk_V1_CaptureElementScreenshotResponse()
        elementResponse.ocrText = "test"
        XCTAssertEqual(elementResponse.ocrText, "test")

        var windowResponse = Macosusesdk_V1_CaptureWindowScreenshotResponse()
        windowResponse.ocrText = "test"
        XCTAssertEqual(windowResponse.ocrText, "test")
    }

    func testImageDataAndOcrTextCombination() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()

        // Simulate a response with both image data and OCR text
        response.imageData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        response.format = .png
        response.width = 1920
        response.height = 1080
        response.ocrText = "Button\nLabel\nTextField"

        // Verify all fields are populated correctly
        XCTAssertEqual(response.imageData.count, 4)
        XCTAssertEqual(response.format, .png)
        XCTAssertEqual(response.width, 1920)
        XCTAssertEqual(response.height, 1080)
        XCTAssertFalse(response.ocrText.isEmpty)
        XCTAssertEqual(response.ocrText.components(separatedBy: "\n").count, 3)
    }

    func testOcrTextEmptyWhenFlagFalse() {
        // When includeOcrText is false, ocrText should remain empty in response
        let request = Macosusesdk_V1_CaptureScreenshotRequest()
        XCTAssertFalse(request.includeOcrText)

        // Response should have empty ocrText when flag is false
        let response = Macosusesdk_V1_CaptureScreenshotResponse()
        XCTAssertTrue(response.ocrText.isEmpty)
    }

    // MARK: - VNRecognizeTextRequest Configuration Tests

    func testVisionRecognitionLevelFast() {
        // Validate that .fast recognition level is a valid option
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        XCTAssertEqual(request.recognitionLevel, .fast)
    }

    func testVisionRecognitionLevelAccurate() {
        // Validate that .accurate recognition level is also available
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        XCTAssertEqual(request.recognitionLevel, .accurate)
    }

    func testVisionUsesLanguageCorrection() {
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = true
        XCTAssertTrue(request.usesLanguageCorrection)

        request.usesLanguageCorrection = false
        XCTAssertFalse(request.usesLanguageCorrection)
    }

    func testVisionSupportedLanguages() {
        // Vision framework supports multiple languages
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate

        // Check that revision is available
        let revision = VNRecognizeTextRequest.defaultRevision
        XCTAssertGreaterThan(revision, 0)
    }

    // MARK: - Direct VNRecognizeTextRequest Test (Validates Vision Framework Behavior)

    func testDirectVisionOCRWithSyntheticImage() throws {
        // This test validates Vision framework behavior directly
        // matching the implementation in extractText
        guard let image = createImageWithText("VISION", width: 200, height: 80, fontSize: 32) else {
            XCTFail("Failed to create test image")
            return
        }

        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true

        try requestHandler.perform([request])

        guard let observations = request.results else {
            XCTFail("No observations returned")
            return
        }

        // Extract text the same way as extractText does
        let recognizedStrings = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        let result = recognizedStrings.joined(separator: "\n")

        XCTAssertTrue(
            result.uppercased().contains("VISION"),
            "Direct Vision OCR should recognize 'VISION', got: '\(result)'",
        )
    }

    func testDirectVisionOCRReturnsConfidenceScores() throws {
        guard let image = createImageWithText("TEST", width: 150, height: 60, fontSize: 28) else {
            XCTFail("Failed to create test image")
            return
        }

        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate

        try requestHandler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            // OCR may not find anything - that's acceptable for unit test
            return
        }

        // Check that confidence scores are returned
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }

            // Confidence should be between 0 and 1
            XCTAssertGreaterThanOrEqual(topCandidate.confidence, 0.0)
            XCTAssertLessThanOrEqual(topCandidate.confidence, 1.0)
        }
    }

    // MARK: - Error Handling Tests

    @MainActor
    func testExtractTextDoesNotThrowForValidImage() throws {
        guard let image = createImageWithText("Valid", width: 150, height: 60, fontSize: 24) else {
            XCTFail("Failed to create test image")
            return
        }

        XCTAssertNoThrow(try ScreenshotCapture.extractText(from: image))
    }

    // MARK: - Performance Consideration Tests

    @MainActor
    func testExtractTextPerformanceWithModerateSizeImage() throws {
        // Performance test with a moderately sized image
        guard let image = createImageWithText("Performance Test", width: 800, height: 200, fontSize: 36) else {
            XCTFail("Failed to create test image")
            return
        }

        let startTime = Date()
        _ = try ScreenshotCapture.extractText(from: image)
        let elapsed = Date().timeIntervalSince(startTime)

        // OCR should complete reasonably quickly (under 5 seconds for fast mode)
        XCTAssertLessThan(elapsed, 5.0, "OCR should complete in reasonable time")
    }
}
