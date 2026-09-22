import ExactMac
import Foundation

/// Read-only source for installed bundle and running-process discovery.
/// Keeping this boundary injectable lets public RPC tests exercise production
/// service composition without consulting or mutating the host desktop.
protocol ApplicationCatalogProvider: Sendable {
    func applicationBundles() async -> [ApplicationBundleInfo]
    func runningApplications() async -> [RunningApplicationInfo]
}

struct ProductionApplicationCatalogProvider: ApplicationCatalogProvider {
    func applicationBundles() async -> [ApplicationBundleInfo] {
        await Task.detached(priority: .utility) {
            discoverApplicationBundles()
        }.value
    }

    func runningApplications() async -> [RunningApplicationInfo] {
        await MainActor.run {
            discoverRunningApplications()
        }
    }
}
