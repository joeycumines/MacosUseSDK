import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import MacosUseServer

@Suite("ProductionSystemOperations Tests")
struct ProductionSystemOperationsTests {
    @Test("ProductionSystemOperations conforms and returns CG window list")
    func returnsCGWindowList() async throws {
        let sys: SystemOperations = ProductionSystemOperations.shared

        let windows = sys.cgWindowListCopyWindowInfo(options: [.optionAll, .excludeDesktopElements], relativeToWindow: kCGNullWindowID)
        // We don't assert a specific count — just ensure the call completes and returns a valid array
        #expect(windows is [[String: Any]], "Expected window list to be an array of dictionaries")
    }

    @Test("fetchAXWindowInfo returns nil for obviously-missing pid/window")
    func fetchAXWindowInfoMissing() async throws {
        let sys: SystemOperations = ProductionSystemOperations.shared

        // Try with pid 0 + window 0 — should be absent and thus return nil.
        let info = sys.fetchAXWindowInfo(pid: 0, windowId: 0, expectedBounds: .zero)
        #expect(info == nil, "Expected no AX window info for pid 0 window 0")
    }
}
