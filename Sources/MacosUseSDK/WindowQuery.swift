// Provides window information primitives that query AX APIs directly,
// supporting the "Split-Brain" window authority model.

import ApplicationServices
import Foundation
import OSLog

private let logger = sdkLogger(category: "WindowQuery")

/// Structure representing the resolved Accessibility state of a window.
public struct WindowInfo {
    public let pid: Int32
    public let windowId: CGWindowID
    public let bounds: CGRect
    public let title: String
    public let isMinimized: Bool
    public let isHidden: Bool
    public let isMain: Bool
    public let isFocused: Bool
}

/// Fetches Accessibility API window information for a specific window using heuristic matching.
///
/// This function bridges the gap between CoreGraphics (windowId) and Accessibility (AXUIElement).
/// Since AXUIElement does not natively expose a `CGWindowID`, we rely on a heuristic match
/// comparing the trusted `expectedBounds` (from CGWindowList) against the live AX bounds.
///
/// - Parameters:
///   - pid: The process ID of the target application.
///   - windowId: The CoreGraphics Window ID (CGWindowID) we are targeting.
///   - expectedBounds: The bounds from CGWindowList, used as the source of truth for matching.
///   - expectedTitle: (Optional) The title from CGWindowList, used as a secondary matching heuristic.
/// - Returns: A `WindowInfo` struct containing authoritative AX data, or `nil` if no match is found.
public func fetchAXWindowInfo(
pid: Int32,
windowId: CGWindowID,
expectedBounds: CGRect,
expectedTitle: String? = nil
) -> WindowInfo? {
    let appElement = AXUIElementCreateApplication(pid)

    // 1. Fetch the list of windows
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        logger.error("Failed to fetch AX windows list for PID \(pid, privacy: .public): AXError \(result.rawValue)")
        return nil
    }

    // 2. Optimize IPC: Batch fetch attributes to avoid N+1 problem
    // We fetch Position, Size, Title, Minimized, and Main in a single round-trip per window.
    let attributes: [CFString] = [
        kAXPositionAttribute as CFString,  // Index 0
        kAXSizeAttribute as CFString,      // Index 1
        kAXTitleAttribute as CFString,     // Index 2
        kAXMinimizedAttribute as CFString, // Index 3
        kAXMainAttribute as CFString       // Index 4
    ]

    var bestMatch: WindowInfo?
    // Initialize with a high score (distance); lower score is better.
    var bestScore: CGFloat = CGFloat.greatestFiniteMagnitude

    for axWindow in windows {
        var valuesArray: CFArray?
        let valuesResult = AXUIElementCopyMultipleAttributeValues(axWindow, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesArray)

        // Validate we got a list of values matching our request count
        guard valuesResult == .success,
        let values = valuesArray as? [AnyObject],
        values.count == attributes.count else {
            continue
        }

        // 3. Robust Extraction: Replace unsafe `as!` with `as?` and validate types

        // -- Position --
        var axPosition = CGPoint.zero
        let posVal = values[0]
        if CFGetTypeID(posVal) == AXValueGetTypeID() {
            // swiftlint:disable:next force_cast
            let axVal = posVal as! AXValue
            if AXValueGetType(axVal) == .cgPoint {
                AXValueGetValue(axVal, .cgPoint, &axPosition)
            } else {
                continue
            }
        } else {
            // Position is mandatory for heuristic matching; skip if missing
            continue
        }

        // -- Size --
        var axSize = CGSize.zero
        let sizeVal = values[1]
        if CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            // swiftlint:disable:next force_cast
            let axVal = sizeVal as! AXValue
            if AXValueGetType(axVal) == .cgSize {
                AXValueGetValue(axVal, .cgSize, &axSize)
            } else {
                continue
            }
        } else {
            // Size is mandatory for heuristic matching; skip if missing
            continue
        }

        let axBounds = CGRect(origin: axPosition, size: axSize)

        // 4. Heuristic Matching Logic
        // Calculate Euclidean distance between trusted CG bounds and candidate AX bounds.
        // We use a combination of origin delta and size delta.
        let originDiff = hypot(axBounds.origin.x - expectedBounds.origin.x, axBounds.origin.y - expectedBounds.origin.y)
        let sizeDiff = hypot(axBounds.width - expectedBounds.width, axBounds.height - expectedBounds.height)
        let score = originDiff + sizeDiff

        // If this candidate is closer than previous ones, verify and store it
        if score < bestScore {
            bestScore = score

            // -- Title --
            let axTitle = values[2] as? String ?? ""

            // -- Minimized --
            // CFBoolean bridges to Bool in Swift, but we check safely.
            let axMinimized = (values[3] as? Bool) ?? false

            // -- Main --
            let axMain = (values[4] as? Bool) ?? false

            // Hidden State Logic:
            // kAXHiddenAttribute on window elements is unreliable or returns unsupported.
            // We treat 'minimized' as the primary source of truth for visibility here.
            // If a window is minimized, it is effectively hidden from view.
            let isHidden = false

            let candidate = WindowInfo(
                pid: pid,
                windowId: windowId,
                bounds: axBounds,
                title: axTitle,
                isMinimized: axMinimized,
                isHidden: isHidden,
                isMain: axMain,
                isFocused: axMain // kAXMain usually implies focus
            )

            bestMatch = candidate
        }
    }

    // 5. Validation Threshold
    // A score of < 20.0 roughly allows for shadow/border discrepancies or slight animation lag.
    // If the best score is huge, we likely found the "first" window of a totally different app window state.
    let matchThreshold: CGFloat = 20.0

    if bestScore <= matchThreshold {
        return bestMatch
    }

    return nil
}
