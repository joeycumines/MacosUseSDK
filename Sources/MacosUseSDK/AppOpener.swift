import AppKit
import Foundation
import OSLog

private let logger = sdkLogger(category: "AppOpener")

/// Define potential errors during app opening
public extension MacosUseSDKError {
    /// Ensure this enum is correctly defined within the extension
    enum AppOpenerError: Error, LocalizedError {
        case appNotFound(identifier: String)
        case invalidPath(path: String)
        case activationFailed(identifier: String, underlyingError: Error?)
        case pidLookupFailed(identifier: String)
        case unexpectedNilURL

        public var errorDescription: String? {
            switch self {
            case let .appNotFound(id):
                return "Application not found for identifier: '\(id)'"
            case let .invalidPath(path):
                return "Provided path does not appear to be a valid application bundle: '\(path)'"
            case let .activationFailed(id, err):
                let base = "Failed to open/activate application '\(id)'"
                if let err {
                    return "\(base): \(err.localizedDescription)"
                }
                return base
            case let .pidLookupFailed(id):
                return "Could not determine PID for application '\(id)' after activation attempt."
            case .unexpectedNilURL:
                return "Internal error: Application URL became nil unexpectedly."
            }
        }
    }
}

/// Define the structure for the successful result
public struct AppOpenerResult: Codable, Sendable {
    public let pid: pid_t
    public let appName: String
    public let processingTimeSeconds: String
}

/// --- Private Helper Class for State Management ---
/// Using a class instance allows managing state like stepStartTime across async calls
@MainActor
private class AppOpenerOperation {
    let appIdentifier: String
    let background: Bool
    let overallStartTime: Date = .init()
    var stepStartTime: Date

    init(identifier: String, background: Bool) {
        appIdentifier = identifier
        self.background = background
        stepStartTime = overallStartTime // Initialize step timer
        logger.info("starting AppOpenerOperation for: \(identifier, privacy: .private(mask: .hash)) background=\(background, privacy: .public)")
    }

    /// Helper to log step completion times (Method definition)
    func logStepCompletion(_ stepDescription: String) {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(stepStartTime)
        let durationStr = String(format: "%.3f", duration)
        logger.info("[\(durationStr, privacy: .public)s] finished '\(stepDescription, privacy: .public)'")
        stepStartTime = endTime // Reset for next step
    }

    /// Main logic function using async/await (Method definition)
    func execute() async throws -> AppOpenerResult {
        // --- All the application discovery, PID finding, and activation logic goes *inside* this method ---
        let workspace = NSWorkspace.shared // Define workspace locally within the method
        var appURL: URL?
        var foundPID: pid_t?
        var bundleIdentifier: String?
        var finalAppName: String?

        // --- 1. Application Discovery ---
        // (Path checking logic...)
        if self.appIdentifier.hasSuffix(".app"), self.appIdentifier.contains("/") {
            logger.info("interpreting '\(self.appIdentifier, privacy: .private)' as a path.")
            let potentialURL = URL(fileURLWithPath: appIdentifier)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: potentialURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue, potentialURL.pathExtension == "app"
            {
                appURL = potentialURL
                logger.info("path confirmed as valid application bundle: \(potentialURL.path, privacy: .private)")
                if let bundle = Bundle(url: potentialURL) {
                    bundleIdentifier = bundle.bundleIdentifier
                    finalAppName =
                        bundle.localizedInfoDictionary?["CFBundleName"] as? String ?? bundle.bundleIdentifier
                    logger.info(
                        "derived bundleID: \(bundleIdentifier ?? "nil", privacy: .public), name: \(finalAppName ?? "nil", privacy: .public) from path",
                    )
                }
            } else {
                logger.warning(
                    "provided path does not appear to be a valid application bundle: \(self.appIdentifier, privacy: .private). Will try as name/bundleID.",
                )
            }
        }

        // (Name/BundleID search logic...)
        if appURL == nil {
            logger.info(
                "interpreting '\(self.appIdentifier, privacy: .private)' as an application name or bundleID, searching...",
            )
            if let foundURL = workspace.urlForApplication(withBundleIdentifier: self.appIdentifier) {
                appURL = foundURL
                bundleIdentifier = self.appIdentifier
                logger.info(
                    "found application url via bundleID '\(self.appIdentifier, privacy: .public)': \(foundURL.path, privacy: .private)",
                )
                if let bundle = Bundle(url: foundURL) {
                    finalAppName =
                        bundle.localizedInfoDictionary?["CFBundleName"] as? String ?? bundle.bundleIdentifier
                }
            } else if let foundURLByName = workspace.urlForApplication(
                toOpen: URL(fileURLWithPath: "/Applications/\(self.appIdentifier).app"),
            )
                ?? workspace.urlForApplication(
                    toOpen: URL(fileURLWithPath: "/System/Applications/\(self.appIdentifier).app"),
                )
                ?? workspace.urlForApplication(
                    toOpen: URL(fileURLWithPath: "/System/Applications/Utilities/\(self.appIdentifier).app"),
                )
            {
                appURL = foundURLByName
                logger.info(
                    "found application url via name search '\(self.appIdentifier, privacy: .private)': \(foundURLByName.path, privacy: .private)",
                )
                if let bundle = Bundle(url: foundURLByName) {
                    bundleIdentifier = bundle.bundleIdentifier
                    finalAppName =
                        bundle.localizedInfoDictionary?["CFBundleName"] as? String ?? bundle.bundleIdentifier
                    logger.info(
                        "derived bundleID: \(bundleIdentifier ?? "nil", privacy: .public), name: \(finalAppName ?? "nil", privacy: .public) from found URL",
                    )
                }
            } else {
                logStepCompletion("application discovery (failed)") // Call method
                throw MacosUseSDKError.AppOpenerError.appNotFound(identifier: self.appIdentifier)
            }
        }
        logStepCompletion(
            "application discovery (url: \(appURL?.path ?? "nil"), bundleID: \(bundleIdentifier ?? "nil"))",
        ) // Call method

        // (Guard statement logic...)
        guard let finalAppURL = appURL else {
            logger.error("unexpected error - application url is nil before launch attempt.")
            throw MacosUseSDKError.AppOpenerError.unexpectedNilURL
        }
        // (Final app name determination...)
        if finalAppName == nil {
            if let bundle = Bundle(url: finalAppURL) {
                finalAppName =
                    bundle.localizedInfoDictionary?["CFBundleName"] as? String ?? bundle.bundleIdentifier
            }
            finalAppName = finalAppName ?? self.appIdentifier
        }

        // --- 2. Pre-find PID if running ---
        // (PID finding logic...)
        if let bID = bundleIdentifier {
            logger.info("checking running applications for bundle id: \(bID, privacy: .public)")
            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bID)
            // Deterministic selection: prefer .regular activation policy, then active, then most recent launch
            let bestCandidate = candidates.sorted { a, b in
                // Primary: prefer .regular (foreground apps) over .accessory/.prohibited
                let aPol = a.activationPolicy.rawValue
                let bPol = b.activationPolicy.rawValue
                if aPol != bPol { return aPol < bPol }
                // Secondary: prefer currently active
                if a.isActive != b.isActive { return a.isActive }
                // Tertiary: prefer most recently launched
                let aDate = a.launchDate ?? .distantPast
                let bDate = b.launchDate ?? .distantPast
                return aDate > bDate
            }.first
            if let runningApp = bestCandidate {
                foundPID = runningApp.processIdentifier
                logger.info("found running instance with pid \(foundPID!, privacy: .public) for bundle id \(bID, privacy: .public) (policy: \(runningApp.activationPolicy.rawValue, privacy: .public), active: \(runningApp.isActive, privacy: .public)).")
            } else {
                logger.info(
                    "no running instance found for bundle id \(bID, privacy: .public) before activation attempt.",
                )
            }
        } else {
            logger.warning(
                "no bundle identifier, attempting lookup by URL: \(finalAppURL.path, privacy: .private)",
            )
            for app in workspace.runningApplications {
                if app.bundleURL?.standardizedFileURL == finalAppURL.standardizedFileURL
                    || app.executableURL?.standardizedFileURL == finalAppURL.standardizedFileURL
                {
                    foundPID = app.processIdentifier
                    logger.info("found running instance with pid \(foundPID!, privacy: .public) matching URL.")
                    break
                }
            }
            if foundPID == nil {
                logger.info("no running instance found by URL before activation attempt.")
            }
        }
        logStepCompletion(
            "pre-finding existing process (pid: \(foundPID.map(String.init) ?? "none found"))",
        ) // Call method

        // --- 3. Open/Activate Application ---
        // (Activation logic...)
        logger.info(
            "attempting to open/activate application: \(finalAppName ?? self.appIdentifier, privacy: .private) (background=\(self.background, privacy: .public))",
        )
        let configuration = NSWorkspace.OpenConfiguration() // Define configuration locally
        configuration.activates = !self.background // If background=true, don't activate (steal focus)

        do {
            // Await the async call AND extract the PID within an explicit MainActor Task
            // This replaces MainActor.run which caused issues in Swift 6.1 with async closures
            let pidAfterOpen = try await Task { @MainActor in
                logger.info("[Task @MainActor] executing workspace.openApplication...")
                // The await happens *inside* the MainActor Task block
                let runningApp = try await workspace.openApplication(
                    at: finalAppURL, configuration: configuration,
                )
                // Access the non-Sendable property *inside* the MainActor Task block
                let pid = runningApp.processIdentifier
                logger.info("[Task @MainActor] got pid \(pid, privacy: .public) from NSRunningApplication.")
                // Return the Sendable pid_t
                return pid
            }.value // Await the result of the Task

            logStepCompletion("opening/activating application async call completed")

            // --- 4. Determine Final PID ---
            var finalPID: pid_t?

            if let pid = foundPID {
                finalPID = pid
                logger.info("using pre-found pid \(pid, privacy: .public).")
            } else {
                // Use the PID extracted immediately after the await
                finalPID = pidAfterOpen
                logger.info(
                    "using pid \(finalPID!, privacy: .public) from newly launched/activated application instance.",
                )
                foundPID = finalPID // Update foundPID if it was initially nil
            }
            logStepCompletion("determining final pid (using \(finalPID!))") // Call method

            // --- 5. Prepare Result ---
            let endTime = Date()
            let processingTime = endTime.timeIntervalSince(overallStartTime)
            let formattedTime = String(format: "%.3f", processingTime)

            logger.info(
                "success: application '\(finalAppName ?? self.appIdentifier, privacy: .private)' active (pid: \(finalPID!, privacy: .public)).",
            )
            logger.info("total processing time: \(formattedTime, privacy: .public) seconds")

            return AppOpenerResult(
                pid: finalPID!,
                appName: finalAppName ?? self.appIdentifier,
                processingTimeSeconds: formattedTime,
            )

        } catch {
            logStepCompletion("opening/activating application (failed)") // Call method
            logger.error("activation call failed: \(error.localizedDescription, privacy: .public)")

            if let pid = foundPID {
                logger.warning(
                    "activation failed, but PID \(pid, privacy: .public) was found beforehand. Assuming it's running.",
                )
                let endTime = Date()
                let processingTime = endTime.timeIntervalSince(overallStartTime)
                let formattedTime = String(format: "%.3f", processingTime)
                logger.info("total processing time: \(formattedTime, privacy: .public) seconds")
                return AppOpenerResult(
                    pid: pid,
                    appName: finalAppName ?? self.appIdentifier,
                    processingTimeSeconds: formattedTime,
                )
            } else {
                logger.error("PID could not be determined after activation failure.")
                let endTime = Date()
                let processingTime = endTime.timeIntervalSince(overallStartTime)
                let formattedTime = String(format: "%.3f", processingTime)
                logger.info("total processing time (on failure): \(formattedTime, privacy: .public) seconds")
                throw MacosUseSDKError.AppOpenerError.activationFailed(
                    identifier: self.appIdentifier, underlyingError: error,
                )
            }
        }
        // --- End of logic inside execute method ---
    } // End of execute() method
} // End of AppOpenerOperation class

/// Opens or activates a macOS application identified by its name, bundle ID, or full path.
/// Outputs detailed logs to stderr.
///
/// - Parameter identifier: The application name (e.g., "Calculator"), bundle ID (e.g., "com.apple.calculator"), or full path (e.g., "/System/Applications/Calculator.app").
/// - Parameter background: If true, the application is opened without being activated (brought to foreground). The user's current focus is preserved. Defaults to false (activates app).
/// - Returns: An `AppOpenerResult` containing the PID, application name, and processing time on success.
/// - Throws: `MacosUseSDKError.AppOpenerError` if the application cannot be found, activated, or its PID determined.
@MainActor
public func openApplication(identifier: String, background: Bool = false) async throws -> AppOpenerResult {
    // Input validation
    guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MacosUseSDKError.AppOpenerError.appNotFound(identifier: "(empty)")
    }

    // Create an instance of the helper class and execute its logic
    let operation = AppOpenerOperation(identifier: identifier, background: background)
    return try await operation.execute()
}

// --- IMPORTANT: Ensure no other executable code (like the old script lines) exists below this line in the file ---
// --- Remove any leftover 'if', 'guard', 'logStepCompletion', 'workspace.openApplication', 'RunLoop.main.run' calls from the top level ---
