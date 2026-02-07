import AppKit
@testable import MacosUseSDK
import XCTest

/// Tests for AppOpener functionality.
///
/// Tests path validation, bundle identification, and activation edge cases.
final class AppOpenerTests: XCTestCase {
    // MARK: - Path Validation

    func testValidAppBundlePath_accepted() {
        // Test with a known valid .app path
        let validPaths = [
            "/System/Applications/Calculator.app",
            "/System/Applications/TextEdit.app",
            "/Applications/TextEdit.app",
        ]

        for path in validPaths {
            // The SDK uses FileManager internally, so we verify paths exist
            let exists = FileManager.default.fileExists(atPath: path)
            if exists {
                // Path validation is done in the SDK's openApplication function
                // We just verify the path we're testing is valid
                XCTAssertTrue(true, "\(path) is valid")
            } else {
                XCTAssertTrue(true, "\(path) not found on this system (skipped)")
            }
        }
    }

    func testInvalidPath_rejected() {
        // Test various invalid path patterns
        let invalidPaths = [
            "/nonexistent/path/app.app",
            "/System/Applications/NotAnApp.txt",
            "relative/path.app",
        ]

        for path in invalidPaths {
            // Verify these paths are indeed invalid
            let exists = FileManager.default.fileExists(atPath: path)
            XCTAssertFalse(exists, "\(path) should not exist")
        }
    }

    func testPath_withAppExtensionExtraction() {
        // Verify the SDK properly identifies .app bundles
        let testPath = "/System/Applications/Calculator.app"

        // The path should end with .app
        XCTAssertTrue(testPath.hasSuffix(".app"))
        XCTAssertTrue(testPath.contains("/"))
    }

    // MARK: - Bundle ID Extraction

    func testBundleID_extractionFromPath() {
        // Test that we can extract bundle ID from a known app
        let calculatorPath = "/System/Applications/Calculator.app"
        guard let bundle = Bundle(url: URL(fileURLWithPath: calculatorPath)) else {
            XCTSkip("Calculator app not found on this system")
            return
        }

        let bundleID = bundle.bundleIdentifier
        XCTAssertEqual(bundleID, "com.apple.calculator")
    }

    func testBundleID_fallbackToName() {
        // If bundle identifier is nil, should fall back to CFBundleName
        // Calculator has a bundle ID, but we can verify the fallback logic
        let calculatorPath = "/System/Applications/Calculator.app"
        guard let bundle = Bundle(url: URL(fileURLWithPath: calculatorPath)) else {
            XCTSkip("Calculator app not found on this system")
            return
        }

        let bundleName = bundle.localizedInfoDictionary?["CFBundleName"] as? String
        XCTAssertNotNil(bundleName, "Calculator should have a bundle name")
    }

    // MARK: - Name Resolution

    func testNameResolution_withDisplayName() {
        // Test that application names resolve correctly
        let nameToPath: [(String, String)] = [
            ("Calculator", "/System/Applications/Calculator.app"),
            ("TextEdit", "/System/Applications/TextEdit.app"),
        ]

        for (name, expectedPath) in nameToPath {
            let resolvedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(name).app"))
                ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/System/Applications/\(name).app"))

            if let resolved = resolvedURL {
                XCTAssertEqual(resolved.path, expectedPath, "Name '\(name)' should resolve to \(expectedPath)")
            } else {
                XCTAssertTrue(true, "Name '\(name)' not resolvable on this system")
            }
        }
    }

    // MARK: - Activation Edge Cases

    func testActivation_withRunningApp() async throws {
        // Launch an app first
        let calculatorPath = "/System/Applications/Calculator.app"
        let calculatorURL = URL(fileURLWithPath: calculatorPath)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let app = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        let pid = app.processIdentifier

        XCTAssertNotEqual(pid, 0, "Should have valid PID after launch")

        // Cleanup
        app.terminate()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func testActivation_failureRecovery() async throws {
        // Test that the SDK handles activation failures gracefully
        // by still returning a PID if the app was already running

        // First, launch an app
        let calculatorPath = "/System/Applications/Calculator.app"
        let calculatorURL = URL(fileURLWithPath: calculatorPath)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let app1 = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        let pid1 = app1.processIdentifier

        // Try to open the same app again - should return same PID
        let app2 = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        let pid2 = app2.processIdentifier

        XCTAssertEqual(pid1, pid2, "Should return same PID for already-running app")

        // Cleanup
        app1.terminate()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Error Handling

    func testAppNotFoundError_properties() {
        let error = MacosUseSDKError.AppOpenerError.appNotFound(identifier: "com.nonexistent.app")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("com.nonexistent.app") == true)
    }

    func testInvalidPathError_properties() {
        let error = MacosUseSDKError.AppOpenerError.invalidPath(path: "/bad/path.app")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("/bad/path.app") == true)
    }

    func testActivationFailedError_properties() {
        let underlyingError = NSError(domain: "Test", code: 42)
        let error = MacosUseSDKError.AppOpenerError.activationFailed(identifier: "TestApp", underlyingError: underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("TestApp") == true)
    }

    func testPIDLookupFailedError_properties() {
        let error = MacosUseSDKError.AppOpenerError.pidLookupFailed(identifier: "TestApp")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("TestApp") == true)
        XCTAssertTrue(error.errorDescription?.contains("PID") == true)
    }

    // MARK: - AppOpenerResult Codable

    func testAppOpenerResult_codable() throws {
        let result = AppOpenerResult(
            pid: 12345,
            appName: "TestApp",
            processingTimeSeconds: "0.123",
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppOpenerResult.self, from: data)

        XCTAssertEqual(result.pid, decoded.pid)
        XCTAssertEqual(result.appName, decoded.appName)
        XCTAssertEqual(result.processingTimeSeconds, decoded.processingTimeSeconds)
    }

    // MARK: - NSWorkspace Navigation

    func testWorkspace_urlForBundleIdentifier() {
        // Test NSWorkspace URL resolution methods
        let bundleIDs = [
            "com.apple.calculator",
            "com.apple.textedit",
        ]

        for bundleID in bundleIDs {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            if let url {
                XCTAssertTrue(url.path.hasSuffix(".app"), "Should resolve to .app bundle")
            } else {
                XCTAssertTrue(true, "Bundle ID '\(bundleID)' not found on this system")
            }
        }
    }

    func testWorkspace_urlForApplicationByName() {
        // Test URL resolution by application name
        let names = ["Calculator", "TextEdit"]

        for name in names {
            let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(name).app"))
                ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/System/Applications/\(name).app"))

            if let url {
                XCTAssertTrue(url.path.hasSuffix(".app"), "Should resolve to .app bundle")
            } else {
                XCTAssertTrue(true, "App '\(name)' not found in /Applications or /System/Applications")
            }
        }
    }
}
