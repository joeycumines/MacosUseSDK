import Foundation
@testable import MacosUseSDK
import XCTest

final class ApplicationCatalogTests: XCTestCase {
    func testDefaultDiscoveryContainsCalculatorGoldenApplication() {
        let calculatorURL = canonicalApplicationBundleURL(
            URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true),
        )
        let bundles = discoverApplicationBundles()
        let calculatorBundles = bundles.filter {
            $0.displayName.localizedCaseInsensitiveContains("calculator")
        }

        XCTAssertTrue(
            calculatorBundles.contains {
                $0.bundleID == "com.apple.calculator" && $0.bundleURL == calculatorURL
            },
            "default roots \(defaultApplicationSearchRoots().map(\.path)) did not discover Calculator; found \(calculatorBundles)",
        )
    }

    func testDefaultDiscoveryContainsFinderGoldenApplication() {
        let finderURL = canonicalApplicationBundleURL(
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true),
        )
        let bundles = discoverApplicationBundles()
        let finderBundles = bundles.filter {
            $0.bundleID == "com.apple.finder"
        }

        XCTAssertTrue(
            finderBundles.contains { $0.bundleURL == finderURL },
            "default roots \(defaultApplicationSearchRoots().map(\.path)) did not discover Finder; found \(finderBundles)",
        )
    }

    func testDuplicateBundleIDsAtDistinctLocationsRemainDistinctResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("First/Calculator.app", isDirectory: true)
        let second = root.appendingPathComponent("Second/Calculator.app", isDirectory: true)
        try makeBundle(at: first, displayName: "Calculator A", bundleID: "com.example.calculator", version: "1.0")
        try makeBundle(at: second, displayName: "Calculator B", bundleID: "com.example.calculator", version: "2.0")

        let bundles = discoverApplicationBundles(searchRoots: [root])

        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(Set(bundles.compactMap(\.bundleID)), ["com.example.calculator"])
        XCTAssertEqual(Set(bundles.map(\.identity)).count, 2)
        XCTAssertEqual(Set(bundles.map(\.bundleURL)), Set([first, second].map(canonicalApplicationBundleURL)))
        XCTAssertEqual(Set(bundles.compactMap(\.version)), ["1.0", "2.0"])
    }

    func testCanonicalBundleURLDeduplicatesSymlinkedSearchRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("Real/Example.app", isDirectory: true)
        let aliasRoot = root.appendingPathComponent("Alias", isDirectory: true)
        try makeBundle(at: bundle, displayName: "Example", bundleID: "com.example.app", version: nil)
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: root.appendingPathComponent("Real", isDirectory: true),
        )

        let bundles = discoverApplicationBundles(
            searchRoots: [root.appendingPathComponent("Real", isDirectory: true), aliasRoot],
        )

        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].identity, applicationBundleIdentity(for: bundle))
        XCTAssertEqual(bundles[0].bundleURL, canonicalApplicationBundleURL(bundle))
    }

    func testDiscoveryIgnoresNonBundlesAndIsDeterministicallyOrdered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("NotAnApp", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Broken.app", isDirectory: true), withIntermediateDirectories: true)
        try makeBundle(at: root.appendingPathComponent("Zulu.app", isDirectory: true), displayName: "Zulu", bundleID: nil, version: nil)
        try makeBundle(at: root.appendingPathComponent("Alpha.app", isDirectory: true), displayName: "Alpha", bundleID: nil, version: nil)

        let first = discoverApplicationBundles(searchRoots: [root])
        let second = discoverApplicationBundles(searchRoots: [root])

        XCTAssertEqual(first.map(\.displayName), ["Alpha", "Zulu"])
        XCTAssertEqual(first, second)
    }

    func testIdentityUsesExactCanonicalURLNotBundleMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Example.app", isDirectory: true)
        try makeBundle(at: bundle, displayName: "Before", bundleID: "com.example", version: "1")
        let before = applicationBundleIdentity(for: bundle)
        try makeBundle(at: bundle, displayName: "After", bundleID: "com.changed", version: "2")
        XCTAssertEqual(applicationBundleIdentity(for: bundle), before)
    }

    private func makeBundle(
        at url: URL,
        displayName: String,
        bundleID: String?,
        version: String?,
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "TestExecutable",
        ]
        if let bundleID {
            info["CFBundleIdentifier"] = bundleID
        }
        if let version {
            info["CFBundleShortVersionString"] = version
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
