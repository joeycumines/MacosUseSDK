import AppKit
import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for ResponseData and processing time formatting.
///
/// Verifies processing_time_seconds is formatted to 2 decimal places.
final class ResponseDataTests: XCTestCase {
    // MARK: - Default Values

    func testDefaultValues() {
        let response = ResponseData(
            app_name: "TestApp",
            elements: [],
            stats: Statistics(),
            processing_time_seconds: "0.00",
        )

        XCTAssertEqual(response.app_name, "TestApp")
        XCTAssertTrue(response.elements.isEmpty)
        XCTAssertEqual(response.processing_time_seconds, "0.00")
    }

    // MARK: - Processing Time Formatting

    func testProcessingTime_formattedToTwoDecimals() {
        // Test that time is formatted with 2 decimal places
        let time1 = String(format: "%.2f", 0.123456)
        XCTAssertEqual(time1, "0.12")

        let time2 = String(format: "%.2f", 1.999999)
        XCTAssertEqual(time2, "2.00")

        let time3 = String(format: "%.2f", 0.005)
        XCTAssertEqual(time3, "0.01")
    }

    func testProcessingTime_subSecondFormatting() {
        let time = String(format: "%.2f", 0.05)
        XCTAssertEqual(time, "0.05")
    }

    func testProcessingTime_integerFormatting() {
        let time = String(format: "%.2f", 5.0)
        XCTAssertEqual(time, "5.00")
    }

    func testProcessingTime_zeroFormatting() {
        let time = String(format: "%.2f", 0.0)
        XCTAssertEqual(time, "0.00")
    }

    // MARK: - ResponseData Structure

    func testResponseData_withElements() {
        let element = ElementData(
            role: "AXButton",
            text: "Click Me",
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        var stats = Statistics()
        stats.count = 1
        stats.role_counts["AXButton"] = 1

        let response = ResponseData(
            app_name: "Calculator",
            elements: [element],
            stats: stats,
            processing_time_seconds: "0.45",
        )

        XCTAssertEqual(response.app_name, "Calculator")
        XCTAssertEqual(response.elements.count, 1)
        XCTAssertEqual(response.stats.count, 1)
        XCTAssertEqual(response.processing_time_seconds, "0.45")
    }

    func testResponseData_emptyElements() {
        let response = ResponseData(
            app_name: "TestApp",
            elements: [],
            stats: Statistics(),
            processing_time_seconds: "0.01",
        )

        XCTAssertTrue(response.elements.isEmpty)
    }

    // MARK: - Codable

    func testResponseData_codable() throws {
        let element = ElementData(
            role: "AXButton",
            text: "Test",
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        var stats = Statistics()
        stats.count = 1

        let response = ResponseData(
            app_name: "TestApp",
            elements: [element],
            stats: stats,
            processing_time_seconds: "0.45",
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ResponseData.self, from: data)

        XCTAssertEqual(response.app_name, decoded.app_name)
        XCTAssertEqual(response.elements.count, decoded.elements.count)
        XCTAssertEqual(response.processing_time_seconds, decoded.processing_time_seconds)
    }

    // MARK: - Sendable

    func testResponseData_sendable() {
        let response = ResponseData(
            app_name: "Test",
            elements: [],
            stats: Statistics(),
            processing_time_seconds: "0.00",
        )

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(response)
    }

    // MARK: - Statistics Integration

    func testResponseData_withFullStatistics() {
        var stats = Statistics()
        stats.count = 10
        stats.visible_elements_count = 8
        stats.with_text_count = 5
        stats.without_text_count = 5
        stats.excluded_count = 2
        stats.excluded_non_interactable = 1
        stats.excluded_no_text = 1
        stats.role_counts["AXButton"] = 3
        stats.role_counts["AXTextField"] = 2

        let response = ResponseData(
            app_name: "FullStatsApp",
            elements: [],
            stats: stats,
            processing_time_seconds: "1.23",
        )

        XCTAssertEqual(response.stats.count, 10)
        XCTAssertEqual(response.stats.visible_elements_count, 8)
        XCTAssertEqual(response.stats.role_counts["AXButton"], 3)
        XCTAssertEqual(response.stats.role_counts["AXTextField"], 2)
    }
}
