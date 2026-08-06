import ApplicationServices
import CoreGraphics
import Foundation
@testable import MacosUseServer
import Testing

struct ProductionSystemOperationsTests {
    @Test
    func `ProductionSystemOperations conforms and returns CG window list`() throws {
        let sys: SystemOperations = ProductionSystemOperations.shared

        let windows = try sys.cgWindowListCopyWindowInfo(options: [.optionAll, .excludeDesktopElements], relativeToWindow: kCGNullWindowID)
        // We don't assert a specific count — just ensure the call completes and returns a valid array
        #expect(windows is [[String: Any]], "Expected window list to be an array of dictionaries")
    }
}
