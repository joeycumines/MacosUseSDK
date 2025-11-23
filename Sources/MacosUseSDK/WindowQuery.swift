// Provides window information primitives that query AX APIs directly,
// supporting hybrid data authority (AX for geometry/state, Registry for metadata).

import ApplicationServices
import Foundation
import OSLog

// Private API declaration for getting CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private let logger = sdkLogger(category: "WindowQuery")

/// Structure representing the resolved Accessibility state of a window.
public struct WindowInfo {
    public let element: AXUIElement
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
    expectedTitle: String? = nil,
) -> WindowInfo? {
    let appElement = AXUIElementCreateApplication(pid)

    // 1. Fetch the list of windows - with kAXChildren fallback for race conditions
    // CRITICAL RACE CONDITION FIX: During rapid window mutations, kAXWindowsAttribute
    // can temporarily return an empty list even though windows still exist. We fall back
    // to kAXChildrenAttribute (which includes all UI elements, not just windows) to rescue
    // orphaned windows, matching the pattern in ObservationManager.handleOrphanedWindows.
    var windowsRef: CFTypeRef?
    var result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    var windows = (result == .success) ? (windowsRef as? [AXUIElement]) : nil

    // Fallback to kAXChildren if kAXWindows returned empty or failed
    if windows == nil || windows!.isEmpty {
        logger.debug("[fetchAXWindowInfo] kAXWindows empty/failed for PID \(pid, privacy: .public), trying kAXChildren fallback")
        var childrenRef: CFTypeRef?
        result = AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef)
        if result == .success {
            windows = childrenRef as? [AXUIElement]
            logger.debug("[fetchAXWindowInfo] kAXChildren returned \(windows?.count ?? 0) elements")
        } else {
            logger.error("[fetchAXWindowInfo] kAXChildren fetch failed with AXError \(result.rawValue)")
            windows = nil
        }
    }

    guard let windows, !windows.isEmpty else {
        logger.error("[fetchAXWindowInfo] No elements available from kAXWindows or kAXChildren for PID \(pid, privacy: .public)")
        return nil
    }

    // 2. Optimize IPC: Batch fetch attributes to avoid N+1 problem
    // This reduces per-window IPC from multiple attribute round-trips (4+ calls) to
    // a single batched call — effectively O(N) total work instead of O(4N).
    // We fetch Position, Size, Title, Minimized, and Main in a single round-trip per window.
    let attributes: [CFString] = [
        kAXPositionAttribute as CFString, // Index 0
        kAXSizeAttribute as CFString, // Index 1
        kAXTitleAttribute as CFString, // Index 2
        kAXMinimizedAttribute as CFString, // Index 3
        kAXMainAttribute as CFString, // Index 4
    ]

    var bestMatch: WindowInfo?
    // Initialize with a high score (distance); lower score is better.
    var bestScore = CGFloat.greatestFiniteMagnitude

    for axWindow in windows {
        // CRITICAL FIX 1: Filter by Role if we are in the fallback path (kAXChildren)
        // kAXChildren returns ALL UI elements (buttons, groups, images, etc.), not just windows.
        // We must verify the element is actually a window before attempting to match it.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String
        {
            // Allow standard window roles. Reject non-window elements.
            // Role is typically "AXWindow" for windows (not "AXButton", "AXGroup", etc.)
            if role != "AXWindow" {
                // Reject non-window UI elements; this avoids catastrophic false-matches
                // when kAXChildren includes controls/groups. Note this excludes
                // non-standard window-like roles (AXDrawer/AXPopover), accepting
                // false negatives over false positives.
                continue
            }
        }
        // NOTE: If `AXUIElementCopyAttributeValue(..., kAXRoleAttribute)` fails, `roleRef` will be nil
        // and this `if` body will not execute. In that case we intentionally "fail-open" and allow
        // the element to proceed to heuristic matching rather than rejecting it outright. This
        // behavior prevents transient AX errors from causing false negatives when trying to
        // resolve windows during race conditions.

        // CRITICAL FIX 2: Prioritize ID Match via _AXUIElementGetWindow
        // If the private API works and returns a matching ID, this is the source of truth.
        // Use it as an instant "gold standard" match (Score 0).
        var axID: CGWindowID = 0
        let idResult = _AXUIElementGetWindow(axWindow, &axID)

        // If ID matches perfectly, fetch remaining attributes and return immediately
        if idResult == .success, axID == windowId {
            logger.debug("[fetchAXWindowInfo] EXACT ID match for window \(windowId, privacy: .public) via _AXUIElementGetWindow")

            // Fetch remaining attributes for this confirmed window
            var valuesArray: CFArray?
            let valuesResult = AXUIElementCopyMultipleAttributeValues(axWindow, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesArray)

            guard valuesResult == .success,
                  let values = valuesArray as? [AnyObject],
                  values.count == attributes.count
            else {
                // If attribute fetch fails, fall through to heuristic matching
                logger.warning("[fetchAXWindowInfo] Attribute fetch failed for exact ID match, falling back to heuristics")
                continue
            }

            // Extract bounds
            var axPosition = CGPoint.zero
            let posVal = values[0]
            if CFGetTypeID(posVal) == AXValueGetTypeID() {
                // swiftlint:disable:next force_cast
                let axVal = posVal as! AXValue
                if AXValueGetType(axVal) == .cgPoint {
                    AXValueGetValue(axVal, .cgPoint, &axPosition)
                }
            }

            var axSize = CGSize.zero
            let sizeVal = values[1]
            if CFGetTypeID(sizeVal) == AXValueGetTypeID() {
                // swiftlint:disable:next force_cast
                let axVal = sizeVal as! AXValue
                if AXValueGetType(axVal) == .cgSize {
                    AXValueGetValue(axVal, .cgSize, &axSize)
                }
            }

            let axBounds = CGRect(origin: axPosition, size: axSize)
            let axTitle = values[2] as? String ?? ""
            let axMinimized = (values[3] as? Bool) ?? false
            let axMain = (values[4] as? Bool) ?? false

            return WindowInfo(
                element: axWindow,
                pid: pid,
                windowId: windowId,
                bounds: axBounds,
                title: axTitle,
                isMinimized: axMinimized,
                isHidden: false,
                isMain: axMain,
                isFocused: axMain,
            )
        }

        // If ID is valid but MISMATCHES, skip this element (it is definitely the wrong window)
        if idResult == .success, axID != 0, axID != windowId {
            logger.debug("[fetchAXWindowInfo] Skipping window with ID \(axID, privacy: .public) (looking for \(windowId, privacy: .public))")
            continue
        }

        // Proceed with heuristic matching if ID check failed or returned 0
        var valuesArray: CFArray?
        let valuesResult = AXUIElementCopyMultipleAttributeValues(axWindow, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesArray)

        // Validate we got a list of values matching our request count
        guard valuesResult == .success,
              let values = valuesArray as? [AnyObject],
              values.count == attributes.count
        else {
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
        var score = originDiff + sizeDiff

        // -- Title (Secondary Heuristic) --
        let axTitle = values[2] as? String ?? ""
        // If expectedTitle is provided and matches exactly, apply a bonus (reduce score)
        if let expectedTitle, !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5 // Give 50% weight reduction for exact title match
        }

        // If this candidate is closer than previous ones, verify and store it
        if score < bestScore {
            bestScore = score

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
                element: axWindow,
                pid: pid,
                windowId: windowId,
                bounds: axBounds,
                title: axTitle,
                isMinimized: axMinimized,
                isHidden: isHidden,
                isMain: axMain,
                isFocused: axMain, // kAXMain usually implies focus
            )

            bestMatch = candidate
        }
    }

    // 5. Validation Threshold
    // CRITICAL FIX FOR RACE CONDITION: During rapid mutation sequences, CGWindowList can be
    // extremely stale. Accept matches up to a reasonable threshold to handle minor discrepancies.
    // After window mutations (move/resize), CGWindowList may lag behind AX state by several frames,
    // causing scores up to ~600 pixels for legitimate matches. Reject only egregious mismatches.
    // Scores under 100 are excellent matches; scores under 1000 are acceptable for race conditions.
    // NOTE: This threshold also intentionally absorbs the common "shadow penalty":
    // Quartz (CG) often reports bounds including drop-shadows and resize chrome while AX
    // reports content bounds. See the docs subsection "Heuristic fairness, biases, and alternatives"
    // in `docs/02-window-state-management.md#heuristic-fairness-biases-and-alternatives` for details.
    // WARNING: If the private API `_AXUIElementGetWindow` fails (returns error/0) AND the
    // candidate AX element has moved a very large distance since the last CG snapshot
    // (e.g., >~1200px across monitors), the score can exceed this threshold and the
    // lookup will reject the candidate — causing `GetWindow` to return `nil` briefly.
    // This is an intentional 'fail-closed' tradeoff to avoid mismatching a different window
    // when the private API is unavailable.
    let scoreThreshold: CGFloat = 1000.0
    if bestScore < scoreThreshold {
        logger.debug("[fetchAXWindowInfo] Matched window \(windowId, privacy: .public) with score \(bestScore, privacy: .public)")
        return bestMatch
    } else if bestScore < CGFloat.greatestFiniteMagnitude {
        logger.warning("[fetchAXWindowInfo] Best match for window \(windowId, privacy: .public) has score \(bestScore, privacy: .public) (threshold: \(scoreThreshold)), rejecting as too far")
    } else {
        logger.warning("[fetchAXWindowInfo] No candidate elements found for window \(windowId, privacy: .public)")
    }

    return nil
}
