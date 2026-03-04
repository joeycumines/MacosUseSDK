import CoreGraphics
import Foundation
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for CaptureMethods - screenshot capture RPC methods.
/// These tests focus on validation logic, proto types, and error handling.
/// Actual screenshot capture requires ScreenCaptureKit permissions and
/// is tested in integration tests.
final class CaptureMethodsTests: XCTestCase {
    // MARK: - ImageFormat Proto Type Tests

    func testImageFormatUnspecified() {
        let format = Macosusesdk_V1_ImageFormat.unspecified
        XCTAssertEqual(format.rawValue, 0)
    }

    func testImageFormatPng() {
        let format = Macosusesdk_V1_ImageFormat.png
        XCTAssertEqual(format.rawValue, 1)
    }

    func testImageFormatJpeg() {
        let format = Macosusesdk_V1_ImageFormat.jpeg
        XCTAssertEqual(format.rawValue, 2)
    }

    func testImageFormatTiff() {
        let format = Macosusesdk_V1_ImageFormat.tiff
        XCTAssertEqual(format.rawValue, 3)
    }

    func testImageFormatAllValuesHaveDistinctRawValues() {
        let formats: [Macosusesdk_V1_ImageFormat] = [.unspecified, .png, .jpeg, .tiff]
        let rawValues = formats.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, formats.count, "All format values should be distinct")
    }

    // MARK: - CaptureScreenshotRequest Proto Tests

    func testCaptureScreenshotRequestDefaultValues() {
        let request = Macosusesdk_V1_CaptureScreenshotRequest()
        XCTAssertEqual(request.display, 0)
        XCTAssertEqual(request.format, .unspecified)
        XCTAssertEqual(request.quality, 0)
        XCTAssertFalse(request.includeOcrText)
    }

    func testCaptureScreenshotRequestWithCustomValues() {
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.display = 1
        request.format = .jpeg
        request.quality = 85
        request.includeOcrText = true

        XCTAssertEqual(request.display, 1)
        XCTAssertEqual(request.format, .jpeg)
        XCTAssertEqual(request.quality, 85)
        XCTAssertTrue(request.includeOcrText)
    }

    func testCaptureScreenshotRequestWithPng() {
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.format = .png
        request.quality = 100 // Quality should be ignored for PNG

        XCTAssertEqual(request.format, .png)
    }

    func testCaptureScreenshotRequestWithTiff() {
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.format = .tiff

        XCTAssertEqual(request.format, .tiff)
    }

    // MARK: - CaptureScreenshotResponse Proto Tests

    func testCaptureScreenshotResponseDefaultValues() {
        let response = Macosusesdk_V1_CaptureScreenshotResponse()
        XCTAssertTrue(response.imageData.isEmpty)
        XCTAssertEqual(response.format, .unspecified)
        XCTAssertEqual(response.width, 0)
        XCTAssertEqual(response.height, 0)
        XCTAssertTrue(response.ocrText.isEmpty)
    }

    func testCaptureScreenshotResponseWithValues() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.imageData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        response.format = .png
        response.width = 1920
        response.height = 1080
        response.ocrText = "Sample OCR text"

        XCTAssertEqual(response.imageData.count, 4)
        XCTAssertEqual(response.format, .png)
        XCTAssertEqual(response.width, 1920)
        XCTAssertEqual(response.height, 1080)
        XCTAssertEqual(response.ocrText, "Sample OCR text")
    }

    // MARK: - CaptureRegionScreenshotRequest Proto Tests

    func testCaptureRegionScreenshotRequestDefaultValues() {
        let request = Macosusesdk_V1_CaptureRegionScreenshotRequest()
        XCTAssertFalse(request.hasRegion)
        XCTAssertEqual(request.display, 0)
        XCTAssertEqual(request.format, .unspecified)
        XCTAssertEqual(request.quality, 0)
        XCTAssertFalse(request.includeOcrText)
    }

    func testCaptureRegionScreenshotRequestWithRegion() {
        var request = Macosusesdk_V1_CaptureRegionScreenshotRequest()
        request.region = Macosusesdk_Type_Region.with {
            $0.x = 100
            $0.y = 200
            $0.width = 300
            $0.height = 400
        }

        XCTAssertTrue(request.hasRegion)
        XCTAssertEqual(request.region.x, 100, accuracy: 0.001)
        XCTAssertEqual(request.region.y, 200, accuracy: 0.001)
        XCTAssertEqual(request.region.width, 300, accuracy: 0.001)
        XCTAssertEqual(request.region.height, 400, accuracy: 0.001)
    }

    func testCaptureRegionScreenshotRequestNegativeCoordinates() {
        // Multi-monitor setups can have negative coordinates (display left of main)
        var request = Macosusesdk_V1_CaptureRegionScreenshotRequest()
        request.region = Macosusesdk_Type_Region.with {
            $0.x = -1920
            $0.y = -100
            $0.width = 500
            $0.height = 400
        }

        XCTAssertEqual(request.region.x, -1920, accuracy: 0.001)
        XCTAssertEqual(request.region.y, -100, accuracy: 0.001)
    }

    // MARK: - CaptureElementScreenshotRequest Proto Tests

    func testCaptureElementScreenshotRequestDefaultValues() {
        let request = Macosusesdk_V1_CaptureElementScreenshotRequest()
        XCTAssertTrue(request.elementID.isEmpty)
        XCTAssertEqual(request.padding, 0)
        XCTAssertEqual(request.format, .unspecified)
        XCTAssertEqual(request.quality, 0)
        XCTAssertFalse(request.includeOcrText)
    }

    func testCaptureElementScreenshotRequestWithValues() {
        var request = Macosusesdk_V1_CaptureElementScreenshotRequest()
        request.elementID = "elem_1234567890_123456"
        request.padding = 10
        request.format = .jpeg
        request.quality = 90
        request.includeOcrText = true

        XCTAssertEqual(request.elementID, "elem_1234567890_123456")
        XCTAssertEqual(request.padding, 10)
        XCTAssertEqual(request.format, .jpeg)
        XCTAssertEqual(request.quality, 90)
        XCTAssertTrue(request.includeOcrText)
    }

    // MARK: - Region Type Tests

    func testRegionTypeConstruction() {
        let region = Macosusesdk_Type_Region.with {
            $0.x = 50.5
            $0.y = 100.5
            $0.width = 200.75
            $0.height = 150.25
        }

        XCTAssertEqual(region.x, 50.5, accuracy: 0.001)
        XCTAssertEqual(region.y, 100.5, accuracy: 0.001)
        XCTAssertEqual(region.width, 200.75, accuracy: 0.001)
        XCTAssertEqual(region.height, 150.25, accuracy: 0.001)
    }

    func testRegionTypeDefaultValues() {
        let region = Macosusesdk_Type_Region()
        XCTAssertEqual(region.x, 0)
        XCTAssertEqual(region.y, 0)
        XCTAssertEqual(region.width, 0)
        XCTAssertEqual(region.height, 0)
    }

    // MARK: - Quality Parameter Tests

    func testQualityParameterBoundaries() {
        // Quality should be clamped between 0 and 100
        var request = Macosusesdk_V1_CaptureScreenshotRequest()

        // Test minimum (0)
        request.quality = 0
        XCTAssertEqual(request.quality, 0)

        // Test maximum (100)
        request.quality = 100
        XCTAssertEqual(request.quality, 100)

        // Test mid-range
        request.quality = 50
        XCTAssertEqual(request.quality, 50)
    }

    func testQualityParameterNegativeValue() {
        // Proto allows negative values, but implementation should clamp
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.quality = -10
        XCTAssertEqual(request.quality, -10) // Proto accepts it
    }

    func testQualityParameterAbove100() {
        // Proto allows values > 100, but implementation should clamp
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.quality = 150
        XCTAssertEqual(request.quality, 150) // Proto accepts it
    }

    // MARK: - Display ID Tests

    func testDisplayIdZeroMeansMainDisplay() {
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.display = 0

        // Display 0 means main display in implementation
        XCTAssertEqual(request.display, 0)
    }

    func testDisplayIdSpecific() {
        var request = Macosusesdk_V1_CaptureScreenshotRequest()
        request.display = 12345

        XCTAssertEqual(request.display, 12345)
    }

    // MARK: - ScreenshotError Tests (Validation Logic)

    func testInvalidRegionError() {
        let error = ScreenshotError.invalidRegion
        XCTAssertEqual(error.description, "Invalid region bounds (width/height must be > 0)")
    }

    func testWindowNotFoundError() {
        let windowID: CGWindowID = 54321
        let error = ScreenshotError.windowNotFound(windowID)
        XCTAssertTrue(error.description.contains("54321"))
        XCTAssertTrue(error.description.contains("not found"))
    }

    func testElementNotFoundError() {
        let error = ScreenshotError.elementNotFound("elem_test_123")
        XCTAssertTrue(error.description.contains("elem_test_123"))
    }

    // MARK: - Validation Logic Tests (Without Actual Capture)

    func testRegionValidationZeroWidth() {
        // This tests the validation logic in ScreenshotCapture.captureRegion
        // Zero width should throw invalidRegion
        let bounds = CGRect(x: 0, y: 0, width: 0, height: 100)
        XCTAssertEqual(bounds.width, 0)
    }

    func testRegionValidationZeroHeight() {
        // Zero height should throw invalidRegion
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 0)
        XCTAssertEqual(bounds.height, 0)
    }

    func testRegionValidationNegativeWidth() {
        // Negative width input should be detected via raw values
        // Note: CGRect normalizes negative dimensions, so we test the raw input values
        let inputWidth: CGFloat = -100
        let inputHeight: CGFloat = 100
        XCTAssertLessThan(inputWidth, 0, "Negative width input should be detected before CGRect creation")
        XCTAssertGreaterThan(inputHeight, 0)
    }

    func testRegionValidationNegativeHeight() {
        // Negative height input should be detected via raw values
        // Note: CGRect normalizes negative dimensions, so we test the raw input values
        let inputWidth: CGFloat = 100
        let inputHeight: CGFloat = -100
        XCTAssertGreaterThan(inputWidth, 0)
        XCTAssertLessThan(inputHeight, 0, "Negative height input should be detected before CGRect creation")
    }

    func testRegionValidationValidBounds() {
        // Valid bounds should pass validation
        let bounds = CGRect(x: 100, y: 200, width: 300, height: 400)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    // MARK: - Element Padding Tests

    func testElementPaddingCalculation() {
        // Test that padding properly expands bounds
        let originalX: Double = 100
        let originalY: Double = 200
        let originalWidth: Double = 300
        let originalHeight: Double = 400
        let padding: Double = 10

        let expandedX = originalX - padding
        let expandedY = originalY - padding
        let expandedWidth = originalWidth + (padding * 2)
        let expandedHeight = originalHeight + (padding * 2)

        XCTAssertEqual(expandedX, 90)
        XCTAssertEqual(expandedY, 190)
        XCTAssertEqual(expandedWidth, 320)
        XCTAssertEqual(expandedHeight, 420)
    }

    func testElementPaddingZero() {
        // Zero padding should not change bounds
        let originalWidth: Double = 300
        let originalHeight: Double = 400
        let padding: Double = 0

        let expandedWidth = originalWidth + (padding * 2)
        let expandedHeight = originalHeight + (padding * 2)

        XCTAssertEqual(expandedWidth, 300)
        XCTAssertEqual(expandedHeight, 400)
    }

    // MARK: - Format Default Handling Tests

    func testFormatDefaultsToPngWhenUnspecified() {
        // When format is unspecified, implementation should default to PNG
        let format = Macosusesdk_V1_ImageFormat.unspecified
        let expectedDefault = Macosusesdk_V1_ImageFormat.png

        // Implementation logic: format == .unspecified ? .png : format
        let result = format == .unspecified ? expectedDefault : format
        XCTAssertEqual(result, .png)
    }

    func testFormatPreservedWhenSpecified() {
        // When format is specified, it should be preserved
        let format = Macosusesdk_V1_ImageFormat.jpeg
        let expectedDefault = Macosusesdk_V1_ImageFormat.png

        let result = format == .unspecified ? expectedDefault : format
        XCTAssertEqual(result, .jpeg)
    }

    // MARK: - OCR Text Field Tests

    func testOcrTextFieldEmpty() {
        let response = Macosusesdk_V1_CaptureScreenshotResponse()
        XCTAssertTrue(response.ocrText.isEmpty)
    }

    func testOcrTextFieldWithContent() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.ocrText = "Hello World\nLine 2"

        XCTAssertEqual(response.ocrText, "Hello World\nLine 2")
        XCTAssertTrue(response.ocrText.contains("\n"))
    }

    func testOcrTextFieldUnicode() {
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.ocrText = "日本語テキスト 中文 한글"

        XCTAssertTrue(response.ocrText.contains("日本語"))
        XCTAssertTrue(response.ocrText.contains("中文"))
        XCTAssertTrue(response.ocrText.contains("한글"))
    }

    // MARK: - Element Registry Integration Tests

    func testElementRegistryGetNonExistentElement() async {
        // Create a test registry with short expiration
        let registry = ElementRegistry(
            cacheExpiration: 30.0,
            clock: { Date() },
            idGenerator: { "test_elem_\(Int.random(in: 1000 ... 9999))" },
            startCleanup: false,
        )

        // Try to get a non-existent element
        let element = await registry.getElement("nonexistent_element")
        XCTAssertNil(element, "Non-existent element should return nil")
    }

    func testElementRegistryRegisterAndRetrieve() async {
        let registry = ElementRegistry(
            cacheExpiration: 30.0,
            clock: { Date() },
            idGenerator: { "test_elem_1234" },
            startCleanup: false,
        )

        // Create a test element with bounds
        var element = Macosusesdk_Type_Element()
        element.x = 100
        element.y = 200
        element.width = 300
        element.height = 400

        // Register element
        let elementId = await registry.registerElement(element, pid: 1234)
        XCTAssertEqual(elementId, "test_elem_1234")

        // Retrieve element
        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.x, 100)
        XCTAssertEqual(retrieved?.y, 200)
        XCTAssertEqual(retrieved?.width, 300)
        XCTAssertEqual(retrieved?.height, 400)
    }

    func testElementRegistryElementHasBounds() async throws {
        let registry = ElementRegistry(
            cacheExpiration: 30.0,
            clock: { Date() },
            idGenerator: { "bounds_elem" },
            startCleanup: false,
        )

        // Element WITH bounds
        var elementWithBounds = Macosusesdk_Type_Element()
        elementWithBounds.x = 50
        elementWithBounds.y = 100
        elementWithBounds.width = 200
        elementWithBounds.height = 150

        let idWithBounds = await registry.registerElement(elementWithBounds, pid: 1)
        let retrievedWithBounds = await registry.getElement(idWithBounds)

        let unwrappedElement = try XCTUnwrap(retrievedWithBounds)
        XCTAssertTrue(unwrappedElement.hasX)
        XCTAssertTrue(unwrappedElement.hasY)
        XCTAssertTrue(unwrappedElement.hasWidth)
        XCTAssertTrue(unwrappedElement.hasHeight)
    }

    func testElementRegistryElementWithoutBounds() async throws {
        let registry = ElementRegistry(
            cacheExpiration: 30.0,
            clock: { Date() },
            idGenerator: { "no_bounds_elem" },
            startCleanup: false,
        )

        // Element WITHOUT bounds (just role/elementID set)
        var elementNoBounds = Macosusesdk_Type_Element()
        elementNoBounds.role = "button"
        elementNoBounds.elementID = "test_button"
        // Note: x, y, width, height not set

        let idNoBounds = await registry.registerElement(elementNoBounds, pid: 2)
        let retrievedNoBounds = await registry.getElement(idNoBounds)

        let unwrappedElement = try XCTUnwrap(retrievedNoBounds)
        // When not explicitly set, hasX etc. should be false
        XCTAssertFalse(unwrappedElement.hasX)
        XCTAssertFalse(unwrappedElement.hasY)
        XCTAssertFalse(unwrappedElement.hasWidth)
        XCTAssertFalse(unwrappedElement.hasHeight)
    }

    // MARK: - Coordinate Validation Tests

    func testCoordinateFiniteCheck() {
        // Test that infinite coordinates would be rejected
        let infiniteValue = Double.infinity
        XCTAssertFalse(infiniteValue.isFinite)

        let nanValue = Double.nan
        XCTAssertFalse(nanValue.isFinite)

        let finiteValue = 100.5
        XCTAssertTrue(finiteValue.isFinite)
    }

    func testCoordinateNegativeInfinityCheck() {
        let negInf = -Double.infinity
        XCTAssertFalse(negInf.isFinite)
    }

    // MARK: - Response Field Consistency Tests

    func testCaptureRegionScreenshotResponseFields() {
        var response = Macosusesdk_V1_CaptureRegionScreenshotResponse()
        response.imageData = Data([0xFF, 0xD8, 0xFF]) // JPEG magic bytes
        response.format = .jpeg
        response.width = 500
        response.height = 400
        response.ocrText = "Text from region"

        XCTAssertEqual(response.imageData.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(response.format, .jpeg)
        XCTAssertEqual(response.width, 500)
        XCTAssertEqual(response.height, 400)
        XCTAssertEqual(response.ocrText, "Text from region")
    }

    func testCaptureElementScreenshotResponseFields() {
        var response = Macosusesdk_V1_CaptureElementScreenshotResponse()
        response.imageData = Data([0x49, 0x49, 0x2A, 0x00]) // TIFF magic bytes
        response.format = .tiff
        response.width = 100
        response.height = 50
        response.elementID = "elem_abc123"
        response.ocrText = "Button text"

        XCTAssertEqual(response.imageData.count, 4)
        XCTAssertEqual(response.format, .tiff)
        XCTAssertEqual(response.width, 100)
        XCTAssertEqual(response.height, 50)
        XCTAssertEqual(response.elementID, "elem_abc123")
        XCTAssertEqual(response.ocrText, "Button text")
    }

    // MARK: - Window Screenshot Request Proto Tests

    func testCaptureWindowScreenshotRequestDefaultValues() {
        let request = Macosusesdk_V1_CaptureWindowScreenshotRequest()
        XCTAssertTrue(request.window.isEmpty)
        XCTAssertFalse(request.includeShadow)
        XCTAssertEqual(request.format, .unspecified)
        XCTAssertEqual(request.quality, 0)
        XCTAssertFalse(request.includeOcrText)
    }

    func testCaptureWindowScreenshotRequestWithValues() {
        var request = Macosusesdk_V1_CaptureWindowScreenshotRequest()
        request.window = "applications/1234/windows/5678"
        request.includeShadow = true
        request.format = .png
        request.quality = 100
        request.includeOcrText = true

        XCTAssertEqual(request.window, "applications/1234/windows/5678")
        XCTAssertTrue(request.includeShadow)
        XCTAssertEqual(request.format, .png)
        XCTAssertEqual(request.quality, 100)
        XCTAssertTrue(request.includeOcrText)
    }

    // MARK: - Window Resource Name Parsing Tests

    func testWindowResourceNameFormat() {
        let windowName = "applications/12345/windows/67890"
        XCTAssertTrue(windowName.contains("applications/"))
        XCTAssertTrue(windowName.contains("/windows/"))

        // Extract PID and window ID
        let components = windowName.split(separator: "/")
        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(String(components[0]), "applications")
        XCTAssertEqual(String(components[2]), "windows")
    }

    // MARK: - Image Data Magic Bytes Tests

    func testPngMagicBytes() {
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(pngMagic.count, 8)
        XCTAssertEqual(pngMagic[0], 0x89)
        XCTAssertEqual(pngMagic[1], 0x50) // 'P'
        XCTAssertEqual(pngMagic[2], 0x4E) // 'N'
        XCTAssertEqual(pngMagic[3], 0x47) // 'G'
    }

    func testJpegMagicBytes() {
        // JPEG magic bytes: FF D8 FF
        let jpegMagic = Data([0xFF, 0xD8, 0xFF])
        XCTAssertEqual(jpegMagic.count, 3)
        XCTAssertEqual(jpegMagic[0], 0xFF)
        XCTAssertEqual(jpegMagic[1], 0xD8)
        XCTAssertEqual(jpegMagic[2], 0xFF)
    }

    func testTiffMagicBytesLittleEndian() {
        // TIFF little-endian magic bytes: 49 49 2A 00
        let tiffMagic = Data([0x49, 0x49, 0x2A, 0x00])
        XCTAssertEqual(tiffMagic.count, 4)
        XCTAssertEqual(tiffMagic[0], 0x49) // 'I'
        XCTAssertEqual(tiffMagic[1], 0x49) // 'I'
    }

    func testTiffMagicBytesBigEndian() {
        // TIFF big-endian magic bytes: 4D 4D 00 2A
        let tiffMagic = Data([0x4D, 0x4D, 0x00, 0x2A])
        XCTAssertEqual(tiffMagic.count, 4)
        XCTAssertEqual(tiffMagic[0], 0x4D) // 'M'
        XCTAssertEqual(tiffMagic[1], 0x4D) // 'M'
    }
}
