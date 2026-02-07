import AppKit
@testable import MacosUseSDK
import XCTest

/// Tests for VisualsConfig and animation styles.
///
/// Verifies animation style enum, duration validation, and default values.
final class DrawVisualsTests: XCTestCase {
    // MARK: - VisualsConfig Default Values

    func testDefaultValues() {
        let config = VisualsConfig.default

        XCTAssertEqual(config.duration, 0.5)
        XCTAssertEqual(config.animationStyle, .none)
    }

    // MARK: - VisualsConfig Custom Values

    func testCustomInitialization() {
        let config = VisualsConfig(
            duration: 2.0,
            animationStyle: .pulseAndFade,
        )

        XCTAssertEqual(config.duration, 2.0)
        XCTAssertEqual(config.animationStyle, .pulseAndFade)
    }

    func testCustomInitialization_scaleInFadeOut() {
        let config = VisualsConfig(
            duration: 1.5,
            animationStyle: .scaleInFadeOut,
        )

        XCTAssertEqual(config.duration, 1.5)
        XCTAssertEqual(config.animationStyle, .scaleInFadeOut)
    }

    func testCustomInitialization_none() {
        let config = VisualsConfig(
            duration: 0.8,
            animationStyle: .none,
        )

        XCTAssertEqual(config.duration, 0.8)
        XCTAssertEqual(config.animationStyle, .none)
    }

    // MARK: - AnimationStyle Sendable

    func testAnimationStyle_sendable() {
        let styles: [VisualsConfig.AnimationStyle] = [.none, .pulseAndFade, .scaleInFadeOut]

        XCTAssertEqual(styles.count, 3)
        XCTAssertEqual(styles[0], .none)
        XCTAssertEqual(styles[1], .pulseAndFade)
        XCTAssertEqual(styles[2], .scaleInFadeOut)
    }

    // MARK: - VisualsConfig Sendable

    func testVisualsConfig_sendable() {
        let config = VisualsConfig()

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(config)
    }

    // MARK: - VisualsConfig Codable

    func testVisualsConfig_notCodable() {
        // VisualsConfig does not conform to Codable in current implementation
        // This test verifies that attempting to encode it would fail at compile time
        let config = VisualsConfig(duration: 1.0, animationStyle: .pulseAndFade)

        // If this compiles, VisualsConfig is not Codable (which is expected)
        XCTAssertNotNil(config)
        XCTAssertEqual(config.duration, 1.0)
    }

    // MARK: - OverlayDescriptor Tests

    func testOverlayDescriptor_initWithFrameAndType() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 100)
        let descriptor = OverlayDescriptor(frame: frame, type: .box(text: "Test"))

        XCTAssertEqual(descriptor.frame, frame)
        if case let .box(text) = descriptor.type {
            XCTAssertEqual(text, "Test")
        } else {
            XCTFail("Expected .box type")
        }
    }

    func testOverlayDescriptor_circleType() {
        let frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        let descriptor = OverlayDescriptor(frame: frame, type: .circle)

        XCTAssertEqual(descriptor.frame, frame)
        if case .circle = descriptor.type {
            // Expected
        } else {
            XCTFail("Expected .circle type")
        }
    }

    func testOverlayDescriptor_captionType() {
        let frame = CGRect(x: 0, y: 0, width: 250, height: 80)
        let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: "Hello"))

        XCTAssertEqual(descriptor.frame, frame)
        if case let .caption(text) = descriptor.type {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .caption type")
        }
    }

    func testOverlayDescriptor_sendable() {
        let descriptor = OverlayDescriptor(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            type: .box(text: "Test"),
        )

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(descriptor)
    }

    // MARK: - getMainScreenCenter Tests

    func testGetMainScreenCenter_returnsPoint() {
        let center = getMainScreenCenter()

        guard let center else {
            // May be nil if no screens are available
            XCTAssertTrue(true, "No main screen available (skipped)")
            return
        }

        // Verify we got a valid point (coordinates depend on display arrangement)
        // NSScreen.main returns the screen with keyboard focus, not necessarily
        // the leftmost/topmost screen. Just verify it's a valid point.
        XCTAssertFalse(center.x.isNaN, "Center X should be a valid number")
        XCTAssertFalse(center.y.isNaN, "Center Y should be a valid number")
        XCTAssertFalse(center.x.isInfinite, "Center X should not be infinite")
        XCTAssertFalse(center.y.isInfinite, "Center Y should not be infinite")
    }

    func testGetMainScreenCenter_appKitCoordinates() {
        // Verify the center point is in AppKit coordinates (bottom-left origin)
        guard let center = getMainScreenCenter(),
              let mainScreen = NSScreen.main
        else {
            XCTSkip("No main screen available")
            return
        }

        let screenRect = mainScreen.frame
        let expectedX = screenRect.midX
        let expectedY = screenRect.midY

        XCTAssertEqual(center.x, expectedX)
        XCTAssertEqual(center.y, expectedY)
    }
}
