# Review Facts: Source Code Observations

This document summarizes factual observations gathered from the source code, verifying claims made in `review-1.md` and `review-2.md`. It strictly adheres to the scientific method: these are observations, not hypotheses.

## 1. Pagination Implementation

**Claim:** Review 1 claims "zero pagination logic was added" in `MacosUseServiceProvider.swift`. Review 2 claims pagination logic exists.

**Observation:** Pagination **IS** implemented in `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift`.

*   **Token Handling:** Methods `encodePageToken(offset:)` and `decodePageToken(_:)` are defined and used.
*   **List Methods:** `listApplications`, `listInputs`, `listWindows`, `listObservations`, and `listSessions` all implement the following pattern:
    1.  Decode `pageToken` to get an `offset`.
    2.  Determine `pageSize`.
    3.  Slice the results array: `Array(results[startIndex ..< endIndex])`.
    4.  Generate `nextPageToken` if more results exist.
*   **Find Methods:** `findElements` and `findRegionElements` request `maxResults = offset + pageSize + 1` from `ElementLocator`, then perform slicing and token generation.
*   **ElementLocator:** `Server/Sources/MacosUseServer/ElementLocator.swift` accepts `maxResults` in `findElements` and `findElementsInRegion` and applies `prefix(maxResults)`.

**Code Reference:** `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift` (Lines 35-57, 130-158, 239-267, 439-478, 503-542, etc.)

## 2. Architectural Divergence (Window Logic)

**Claim:** Review 1 and 2 claim divergence between Server and SDK window lookup logic, with SDK being more efficient.

**Observation:** There are two distinct implementations for finding a window by ID.

*   **Server Implementation (`Server/Sources/MacosUseServer/WindowHelpers.swift`):**
    *   Function: `findWindowElement(pid:windowId:)`
    *   Logic: Iterates through all AX windows.
    *   IPC: Calls `AXUIElementCopyAttributeValue` multiple times per window (Position, Size) to compare against `CGWindowList` bounds.
    *   Matching: Strictly matches bounds with a delta < 2.
*   **SDK Implementation (`Sources/MacosUseSDK/WindowQuery.swift`):**
    *   Function: `fetchAXWindowInfo(pid:windowId:expectedBounds:expectedTitle:)`
    *   Logic: Iterates through all AX windows.
    *   IPC: Uses `AXUIElementCopyMultipleAttributeValues` to fetch Position, Size, Title, Minimized, and Main in a **single batch call**.
    *   Matching: Uses a heuristic score based on bounds distance and includes a title match bonus.

**Conclusion:** The implementations are divergent. The SDK implementation uses batched IPC calls, whereas the Server implementation uses multiple IPC calls per window.

## 3. Concurrency & Liveness

**Claim:** Reviews claim concurrency fixes (off-main-thread execution) are present.

**Observation:** Concurrency best practices are implemented in critical paths.

*   **AutomationCoordinator:** `Server/Sources/MacosUseServer/AutomationCoordinator.swift` uses `Task.detached(priority: .userInitiated)` to run `MacosUseSDK.traverseAccessibilityTree` off the Main Actor.
*   **Window Mutations:** `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift` uses `Task.detached` for AX set operations in `focusWindow`, `moveWindow`, `resizeWindow`, `minimizeWindow`, and `restoreWindow`.
*   **InputController:** `Sources/MacosUseSDK/InputController.swift` uses `withCheckedThrowingContinuation` for `osascript` execution and explicitly clears `process.terminationHandler = nil` to prevent retain cycles.

## 4. Window Lookup Race / "Split-Brain" Consistency

**Claim:** Review 2 warns of a race condition where `findWindowElement` fails because it relies on stale `CGWindowList` data.

**Observation:**
*   **Split-Brain Authority:** `MacosUseServiceProvider.swift` implements `buildWindowResponseFromAX` which adheres to `window.proto`'s "Split-Brain Authority" model:
    *   **AX Authority (Fresh):** Title, Bounds, Minimized, Hidden.
    *   **Registry Authority (Stable/Stale):** Z-Index, BundleID.
    *   **Visible Calculation:** `(!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)`.
*   **The Race:** `findWindowElement` in `WindowHelpers.swift` retrieves `CGWindowList` (which can be stale) to get "expected bounds". It then iterates live AX windows and tries to match them against these (potentially stale) bounds.
    *   If a window was just resized (AX updated), but `CGWindowList` hasn't updated yet, `findWindowElement` will look for a window with *old* bounds, fail to match the window with *new* bounds, and return `RPCError.notFound`.

**Code Reference:** `Server/Sources/MacosUseServer/WindowHelpers.swift` (Lines 160-230)

## 5. Dead Code

**Claim:** Review 1 claims `asyncMap` in `Extensions.swift` is unused.

**Observation:** `Server/Sources/MacosUseServer/Extensions.swift` defines `Sequence.asyncMap`. A search of the codebase reveals **0 usages** of this function outside of its definition.

## 6. Window Proto Compliance

**Observation:** The implementation in `MacosUseServiceProvider.swift` (`buildWindowResponseFromAX`) aligns with the documentation in `proto/macosusesdk/v1/window.proto`.

*   **Proto:** `visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden`
*   **Code:** `let visible = isOnScreen && !axMinimized && !axHidden` where `isOnScreen` defaults to `true` if AX interaction succeeded (Assumption).
