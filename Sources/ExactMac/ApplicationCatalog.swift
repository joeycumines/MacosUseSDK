import AppKit
import CryptoKit
import Foundation

private let supportedApplicationBundlePackageTypes: Set<String> = ["APPL", "FNDR"]

/// Returns whether a bundle is a launchable user-facing macOS application.
/// Finder is the system-defined exception to the ordinary `APPL` package type:
/// its bundle declares the historical `FNDR` package type.
func isSupportedApplicationBundle(_ bundle: Bundle) -> Bool {
    guard let packageType = bundle.infoDictionary?["CFBundlePackageType"] as? String else {
        return false
    }
    return supportedApplicationBundlePackageTypes.contains(packageType)
}

/// Immutable metadata for one exact installed macOS application bundle.
public struct ApplicationBundleInfo: Hashable, Sendable {
    /// Stable opaque identity derived from the exact canonical bundle URL.
    public let identity: String
    public let displayName: String
    public let bundleID: String?
    public let bundleURL: URL
    public let version: String?

    public init(
        identity: String,
        displayName: String,
        bundleID: String?,
        bundleURL: URL,
        version: String?,
    ) {
        self.identity = identity
        self.displayName = displayName
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.version = version
    }
}

/// Immutable metadata for one observed running macOS application process.
public struct RunningApplicationInfo: Hashable, Sendable {
    public let pid: pid_t
    public let displayName: String
    public let bundleID: String?
    public let bundleURL: URL?
    public let bundleIdentity: String?
    public let launchDate: Date?
    public let active: Bool

    public init(
        pid: pid_t,
        displayName: String,
        bundleID: String?,
        bundleURL: URL?,
        bundleIdentity: String?,
        launchDate: Date?,
        active: Bool,
    ) {
        self.pid = pid
        self.displayName = displayName
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.bundleIdentity = bundleIdentity
        self.launchDate = launchDate
        self.active = active
    }
}

/// Returns a canonical file URL suitable for exact bundle identity.
public func canonicalApplicationBundleURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
}

/// Returns a deterministic opaque identity for one exact application bundle
/// location. Bundle ID is deliberately excluded because distinct installations
/// may share it.
public func applicationBundleIdentity(for url: URL) -> String {
    let canonical = canonicalApplicationBundleURL(url)
    return SHA256.hash(data: Data(canonical.absoluteString.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

/// Returns ordinary macOS application roots plus each domain's CoreServices
/// directory. Finder and other user-facing system applications live outside
/// `Applications`, under `/System/Library/CoreServices`; missing roots are
/// harmless and ignored by discovery.
public func defaultApplicationSearchRoots(fileManager: FileManager = .default) -> [URL] {
    let domains = FileManager.SearchPathDomainMask.allDomainsMask
    let roots = fileManager.urls(for: .applicationDirectory, in: domains) +
        fileManager.urls(for: .libraryDirectory, in: domains).map {
            $0.appendingPathComponent("CoreServices", isDirectory: true)
        }
    return roots
        .map(canonicalApplicationBundleURL)
        .reduce(into: []) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }
}

/// Discovers installed application bundles without opening or activating them.
/// Package descendants are skipped, canonical URLs are de-duplicated, and
/// output is stable across filesystem enumeration order.
public func discoverApplicationBundles(
    searchRoots: [URL] = defaultApplicationSearchRoots(),
    fileManager: FileManager = .default,
) -> [ApplicationBundleInfo] {
    var bundleURLs = Set<URL>()

    func admit(_ candidate: URL) {
        let canonical = canonicalApplicationBundleURL(candidate)
        guard canonical.pathExtension.lowercased() == "app" else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        bundleURLs.insert(canonical)
    }

    for root in searchRoots.map(canonicalApplicationBundleURL) {
        if root.pathExtension.lowercased() == "app" {
            admit(root)
            continue
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else {
            continue
        }
        for case let candidate as URL in enumerator {
            admit(candidate)
        }
    }

    return bundleURLs.compactMap { url -> ApplicationBundleInfo? in
        guard let bundle = Bundle(url: url),
              let infoDictionary = bundle.infoDictionary,
              isSupportedApplicationBundle(bundle)
        else {
            return nil
        }
        let displayName = resolveApplicationDisplayName(
            localizedInfoDictionary: bundle.localizedInfoDictionary,
            infoDictionary: infoDictionary,
            applicationURL: url,
            fallbackIdentifier: url.deletingPathExtension().lastPathComponent,
        )
        guard !displayName.isEmpty else { return nil }
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        return ApplicationBundleInfo(
            identity: applicationBundleIdentity(for: url),
            displayName: displayName,
            bundleID: bundle.bundleIdentifier,
            bundleURL: url,
            version: version,
        )
    }.sorted { lhs, rhs in
        if lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) != .orderedSame {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return lhs.bundleURL.absoluteString < rhs.bundleURL.absoluteString
    }
}

/// Enumerates currently running user-facing applications without mutating
/// launch, activation, or focus state.
@MainActor
public func discoverRunningApplications(workspace: NSWorkspace = .shared) -> [RunningApplicationInfo] {
    workspace.runningApplications.compactMap { application in
        guard application.processIdentifier > 0,
              !application.isTerminated,
              application.activationPolicy != .prohibited
        else {
            return nil
        }
        let bundleURL = application.bundleURL.map(canonicalApplicationBundleURL)
        let displayName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = bundleURL?.deletingPathExtension().lastPathComponent ?? application.bundleIdentifier ?? ""
        let normalizedName = (displayName?.isEmpty == false ? displayName : fallback) ?? ""
        guard !normalizedName.isEmpty else { return nil }
        return RunningApplicationInfo(
            pid: application.processIdentifier,
            displayName: normalizedName,
            bundleID: application.bundleIdentifier,
            bundleURL: bundleURL,
            bundleIdentity: bundleURL.map(applicationBundleIdentity),
            launchDate: application.launchDate,
            active: application.isActive,
        )
    }.sorted { lhs, rhs in
        if lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) != .orderedSame {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return lhs.pid < rhs.pid
    }
}
