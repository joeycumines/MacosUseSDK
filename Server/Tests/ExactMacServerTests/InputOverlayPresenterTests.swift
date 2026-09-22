import CoreGraphics
import ExactMac
@testable import ExactMacServer
import Testing

@Suite(.serialized)
struct InputOverlayPresenterTests {
    @Test
    func `planning uses exact frozen global points and AppKit conversion`() throws {
        let topology = [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 20, width: 1000, height: 760),
                isMain: true,
                scale: 2,
            ),
            DisplayTopologyDisplay(
                displayID: 2,
                frame: CGRect(x: -1200, y: -900, width: 1200, height: 900),
                visibleFrame: CGRect(x: -1200, y: -900, width: 1200, height: 860),
                isMain: false,
                scale: 1,
            ),
        ]

        let click = try InputOverlayPlanning.presentation(
            for: .click(point: CGPoint(x: -100, y: -100)),
            topology: topology,
            requestedDuration: 0.25,
        )
        #expect(click.content == .circle)
        #expect(click.duration == 0.25)
        #expect(click.frame == CGRect(x: -132, y: 868, width: 64, height: 64))

        let key = try InputOverlayPlanning.presentation(
            for: .pressKeyCode(keyCode: 36, flags: []),
            topology: topology,
            requestedDuration: 0,
        )
        #expect(key.content == .caption)
        #expect(key.duration == 0.5)
        #expect(key.frame == CGRect(x: 340, y: 364, width: 320, height: 72))
    }

    @Test
    func `drain cancels running renderer and joins resistant cleanup exactly once`() async throws {
        let renderer = InputOverlayRendererProbe()
        let presenter = InputOverlayPresenter { presentation in
            try await renderer.render(presentation)
        }
        let reservation = try await presenter.reserve(testPresentation())
        let presentation = Task {
            try await presenter.present(reservation)
        }
        await renderer.waitUntilEntered()

        let shutdown = Task {
            await presenter.shutdown()
        }
        await renderer.waitUntilCancellationObserved()

        #expect(await presenter.activeReservationCount() == 1)
        #expect(await renderer.cleanupCount() == 0)

        await renderer.releaseCleanup()
        do {
            try await presentation.value
            Issue.record("Expected renderer cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected presentation error: \(error)")
        }
        await shutdown.value
        await presenter.shutdown()

        #expect(await renderer.cleanupCount() == 1)
        #expect(await presenter.activeReservationCount() == 0)
        #expect(await presenter.lifecycleState() == .drained)
    }

    @Test
    func `drain settles an untriggered reservation and rejects later presentation`() async throws {
        let presenter = InputOverlayPresenter { _ in
            Issue.record("Reserved presentation must not run after drain")
        }
        let reservation = try await presenter.reserve(testPresentation())

        await presenter.shutdown()

        do {
            try await presenter.present(reservation)
            Issue.record("Expected drained reservation rejection")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected drained reservation error: \(error)")
        }
        #expect(await presenter.activeReservationCount() == 0)
    }
}

private actor InputOverlayRendererProbe {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationObserved = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupReleased = false
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanups = 0

    func render(_: InputOverlayPresentation) async throws {
        entered = true
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in enteredWaiters {
            waiter.resume()
        }
        do {
            try await Task.sleep(for: .seconds(3600))
            Issue.record("Renderer unexpectedly completed without cancellation")
        } catch is CancellationError {
            cancellationObserved = true
            let cancellationWaiters = cancellationWaiters
            self.cancellationWaiters.removeAll()
            for waiter in cancellationWaiters {
                waiter.resume()
            }
            if !cleanupReleased {
                await withCheckedContinuation { continuation in
                    cleanupWaiters.append(continuation)
                }
            }
            cleanups += 1
            throw CancellationError()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func releaseCleanup() {
        cleanupReleased = true
        let cleanupWaiters = cleanupWaiters
        self.cleanupWaiters.removeAll()
        for waiter in cleanupWaiters {
            waiter.resume()
        }
    }

    func cleanupCount() -> Int {
        cleanups
    }
}

private func testPresentation() -> InputOverlayPresentation {
    InputOverlayPresentation(
        frame: CGRect(x: 10, y: 20, width: 64, height: 64),
        content: .circle,
        duration: 0.5,
    )
}
