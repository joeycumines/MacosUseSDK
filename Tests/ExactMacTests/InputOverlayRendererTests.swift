import CoreGraphics
@testable import ExactMac
import XCTest

final class InputOverlayRendererTests: XCTestCase {
    func testPresentationValidationRejectsInvalidGeometryAndDuration() {
        let valid = InputOverlayPresentation(
            frame: CGRect(x: 10, y: 20, width: 64, height: 64),
            content: .circle,
            duration: 0.5,
        )
        XCTAssertNoThrow(try valid.validated())

        for presentation in [
            InputOverlayPresentation(
                frame: CGRect(x: CGFloat.nan, y: 20, width: 64, height: 64),
                content: .circle,
                duration: 0.5,
            ),
            InputOverlayPresentation(
                frame: CGRect(x: 10, y: 20, width: 0, height: 64),
                content: .circle,
                duration: 0.5,
            ),
            InputOverlayPresentation(
                frame: CGRect(x: 10, y: 20, width: 64, height: 64),
                content: .circle,
                duration: .infinity,
            ),
            InputOverlayPresentation(
                frame: CGRect(x: 10, y: 20, width: 64, height: 64),
                content: .caption,
                duration: 0,
            ),
        ] {
            XCTAssertThrowsError(try presentation.validated())
        }
    }

    @MainActor
    func testCancelledLifetimeThrowsAfterExactOnceCleanup() async {
        var cleanupCount = 0
        let presentation = Task { @MainActor in
            try await runInputOverlayLifetime(duration: 3600) {
                cleanupCount += 1
            }
        }

        presentation.cancel()
        do {
            try await presentation.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected lifetime error: \(error)")
        }

        XCTAssertEqual(cleanupCount, 1)
    }
}
