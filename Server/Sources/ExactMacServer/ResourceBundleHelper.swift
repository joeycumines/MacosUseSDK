import Foundation

/// Resolves the ExactMacServer resource bundle in a deployment-safe manner.
///
/// When the server runs from an installed .app, the bundle must be inside
/// `Contents/` — codesign rejects content at the app bundle root on modern
/// macOS.  This helper searches `Contents/Resources/` first, which is the
/// standard location for app-bundled resources, and falls back to the
/// SwiftPM-generated `Bundle.module` path for development builds.
enum ResourceBundleHelper {
    /// The resource bundle that contains `.pb` descriptor files and other
    /// assets declared by the SwiftPM `resources:` manifest.
    static let bundle: Bundle = {
        let bundleName = "ExactMacServer_ExactMacServer"

        // 1. Inside the deployed .app (codesign-safe path).
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("\(bundleName).bundle"),
            let bundle = Bundle(path: resourceURL.path)
        {
            return bundle
        }

        // 2. The SwiftPM-generated module bundle (works during development
        //    when Bundle.module resolves correctly).
        if let moduleBundle = Bundle(path: Bundle.main.bundleURL
            .appendingPathComponent("\(bundleName).bundle").path)
        {
            return moduleBundle
        }

        // 3. Last resort: try the build-tree path embedded by SwiftPM.
        //    This is populated from the generated resource_bundle_accessor.
        return Bundle.module
    }()
}
