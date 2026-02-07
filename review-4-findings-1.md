# Findings: MacosUseSDK Deficiencies (Review-4)

This report documents the investigation into several technical deficiencies identified in the `MacosUseSDK` codebase as part of Review-4.

## 1. Internationalization Failure (Confirmed)
**File:** `Sources/MacosUseSDK/InputController.swift`
**Finding:** The `mapKeyNameToKeyCode(_:)` function uses a hardcoded `switch` statement that maps characters (e.g., "a", "s", "z") to `CGKeyCode` values based strictly on the **US-QWERTY** layout.
**Impact:** On non-US keyboard layouts (e.g., AZERTY, QWERTZ, Dvorak), these mappings will produce incorrect characters or actions. For example, on an AZERTY keyboard, mapping "a" to `0` will result in "q" being typed.
**Current State:**
- `mapKeyNameToKeyCode("a")` returns `0`.
- `mapKeyNameToKeyCode("q")` returns `12`.
- Tests in `Tests/MacosUseSDKTests/InputControllerTests.swift` hard-verify these US-centric values.

## 2. Stability Risk: Private API Usage (Confirmed)
**File:** `Sources/MacosUseSDK/WindowQuery.swift`
**Finding:** The SDK uses `@_silgen_name("_AXUIElementGetWindow")` to link directly to a private Apple symbol.
**Impact:** This creates a binary compatibility risk. If Apple removes or renames this symbol in a future macOS update, the application will crash at launch due to an unresolved symbol.
**Current State:** The function is used as a "gold standard" for matching `AXUIElement` to `CGWindowID`. While highly effective currently, it lacks a graceful runtime check/fallback mechanism (e.g., `dlsym`).

## 3. Data Loss in Attribute Extraction (Confirmed)
**File:** `Sources/MacosUseSDK/AccessibilityTraversal.swift`
**Finding:** `getStringValue` only handles `CFString`. It ignores `CFNumber` (used for sliders), `CFBoolean` (checkboxes), and `AXValue` (complex types).
**Impact:** Critical state information for UI controls like sliders, progress bars, and checkboxes is lost during traversal, appearing as `nil` or empty strings in the output.
**Current State:**
```swift
func getStringValue(_ value: CFTypeRef?) -> String? {
    guard let value = value else { return nil }
    let typeID = CFGetTypeID(value)
    if typeID == CFStringGetTypeID() {
        let cfString = value as! CFString
        return cfString as String
    }
    // ... returns nil for other types ...
}
```

## 4. Indeterminate Process Targeting (Confirmed)
**File:** `Sources/MacosUseSDK/AppOpener.swift`
**Finding:** `NSRunningApplication.runningApplications(withBundleIdentifier: bID).first` is used to find existing instances.
**Impact:** In environments with multiple instances of the same app (e.g., multiple Chrome profiles, background helpers), the SDK chooses one arbitrarily. This can lead to targeting the wrong instance for traversal or actions.
**Current State:** The code does not attempt to filter by activation policy or launch date.

## 5. Brittle Diffing Logic (Confirmed)
**File:** `Sources/MacosUseSDK/ActionCoordinator.swift`
**Finding:** Diffing relies heavily on a 5.0 point `positionTolerance`.
**Impact:** Minor UI shifts or window resizes cause the SDK to report that all elements were removed and re-added, losing continuity for state tracking.

## 6. Fire-and-Forget Visualization (Confirmed)
**File:** `Sources/MacosUseSDK/ActionCoordinator.swift` & `HighlightInput.swift`
**Finding:** Visualizations are launched in detached `Task { @MainActor in ... }` blocks without awaiting completion or tracking.
**Impact:** In CLI tools that exit quickly, the visualizations may never appear because the process terminates before the `MainActor` can execute the task.

---

# Implementation Plan

This plan details the specific code changes required to resolve the findings above.

## 1. Fix Internationalization (Dynamic Key Mapping)

**Objective:** Replace hardcoded QWERTY constants with dynamic resolution using macOS Text Input Sources (TIS).

**File:** `Sources/MacosUseSDK/InputController.swift`

**Action:**
1.  Import `Carbon`.
2.  Implement `resolveKeyCode(for char: String) -> CGKeyCode?`:
    *   Get current keyboard layout: `TISCopyCurrentKeyboardInputSource()`.
    *   Get layout data: `TISGetInputSourceProperty(..., kTISPropertyUnicodeKeyLayoutData)`.
    *   Iterate virtual key codes (0-127).
    *   Use `UCKeyTranslate` to convert each key code to a Unicode string.
    *   If the generated string matches the target character (case-insensitive), return that key code.
3.  Update `mapKeyNameToKeyCode(_:)`:
    *   Retain hardcoded constants for **Function Keys** (F1-F12) and **Special Keys** (Return, Tab, Esc, Arrows) as these are standard.
    *   For single-character inputs (letters, numbers, punctuation), call `resolveKeyCode`.
    *   If `resolveKeyCode` fails (e.g., character not on current layout), fall back to the existing US-QWERTY constants as a safety net.

**Verification (Automated):**
*   **Unit Test (`testResolveKeyCodeRoundTrip`):** For a set of standard characters (a-z, 0-9), verify that `resolveKeyCode(for:)` returns a key code which, when passed through `UCKeyTranslate` again, produces the original character. This ensures the dynamic mapping is internally consistent with the system's layout.

## 2. Fix Private API Stability (Dynamic Linking)

**Objective:** Remove the hard link to `_AXUIElementGetWindow` to prevent startup crashes if the symbol is removed.

**File:** `Sources/MacosUseSDK/WindowQuery.swift`

**Action:**
1.  Remove `@_silgen_name("_AXUIElementGetWindow")`.
2.  Define a function pointer type:
    ```swift
    typealias AXUIElementGetWindowType = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    ```
3.  Update `fetchAXWindowInfo`:
    *   Use `dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow")` to resolve the symbol at runtime.
    *   If the pointer is non-null, cast it to `AXUIElementGetWindowType` and call it.
    *   If the pointer is null (symbol removed), log a warning and proceed immediately to the **heuristic matching** logic (fallback).

**Verification (Automated):**
*   **Unit Test (`testFetchAXWindowInfoHeuristicFallback`):** Invoke `fetchAXWindowInfo` with a mock window where the ID check is guaranteed to fail or be bypassed (simulated via high-level test harness), and verify that the function still returns the correct `WindowInfo` based solely on the heuristic bounds matching. This confirms the fallback path is robust.

## 3. Fix Data Loss (Comprehensive Attribute Extraction)

**Objective:** Extract values from `CFNumber`, `CFBoolean`, and `CFDate` attributes.

**File:** `Sources/MacosUseSDK/AccessibilityTraversal.swift`

**Action:**
1.  Rename `getStringValue` to `getDisplayString`.
2.  Update logic to inspect `CFGetTypeID(value)`:
    *   **CFString:** Return as String (existing).
    *   **CFBoolean:** Return "true" or "false".
    *   **CFNumber:** Use `String(describing:)` or `CFNumberGetValue` to convert to String.
    *   **CFDate:** Use `ISO8601DateFormatter` to return a standard string representation.
    *   **AXValue:** If it's a `kAXValueTypeCFRange`, format as `{loc, len}`.
3.  Update call sites (`extractElementAttributes`) to use `getDisplayString`.

**Verification (Automated):**
*   **Unit Test (`testAttributeStringification`):** Create a suite of tests that pass various CoreFoundation types (`CFNumber` with different types, `CFBoolean`, `CFDate`) to `getDisplayString` and assert that the returned `String` matches the expected human-readable format.

## 2. Fix Private API Stability (Dynamic Linking)

**Objective:** Remove the hard link to `_AXUIElementGetWindow` to prevent startup crashes if the symbol is removed.

**File:** `Sources/MacosUseSDK/WindowQuery.swift`

**Action:**
1.  Remove `@_silgen_name("_AXUIElementGetWindow")`.
2.  Define a function pointer type:
    ```swift
    typealias AXUIElementGetWindowType = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    ```
3.  Update `fetchAXWindowInfo`:
    *   Use `dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow")` to resolve the symbol at runtime.
    *   If the pointer is non-null, cast it to `AXUIElementGetWindowType` and call it.
    *   If the pointer is null (symbol removed), log a warning and proceed immediately to the **heuristic matching** logic (fallback).

**Verification (Automated):**
*   **Unit Test (`testFetchAXWindowInfoHeuristicFallback`):** Invoke `fetchAXWindowInfo` with a mock window where the ID check is guaranteed to fail or be bypassed (simulated via high-level test harness), and verify that the function still returns the correct `WindowInfo` based solely on the heuristic bounds matching. This confirms the fallback path is robust.

## 3. Fix Data Loss (Comprehensive Attribute Extraction)

**Objective:** Extract values from `CFNumber`, `CFBoolean`, and `CFDate` attributes.

**File:** `Sources/MacosUseSDK/AccessibilityTraversal.swift`

**Action:**
1.  Rename `getStringValue` to `getDisplayString`.
2.  Update logic to inspect `CFGetTypeID(value)`:
    *   **CFString:** Return as String (existing).
    *   **CFBoolean:** Return "true" or "false".
    *   **CFNumber:** Use `String(describing:)` or `CFNumberGetValue` to convert to String.
    *   **CFDate:** Use `ISO8601DateFormatter` to return a standard string representation.
    *   **AXValue:** If it's a `kAXValueTypeCFRange`, format as `{loc, len}`.
3.  Update call sites (`extractElementAttributes`) to use `getDisplayString`.

**Verification (Automated):**
*   **Unit Test (`testAttributeStringification`):** Create a suite of tests that pass various CoreFoundation types (`CFNumber` with different types, `CFBoolean`, `CFDate`) to `getDisplayString` and assert that the returned `String` matches the expected human-readable format.

## 4. Fix Indeterminate Process Targeting

**Objective:** Deterministically select the "best" instance of an application when multiple are running.

**File:** `Sources/MacosUseSDK/AppOpener.swift`

**Action:**
1.  In `execute()`, when querying `NSRunningApplication.runningApplications(withBundleIdentifier:)`:
2.  Do NOT just take `.first`.
3.  Sort the results:
    *   **Primary Sort:** `activationPolicy`. Prefer `.regular` (0) over `.accessory` (1) or `.prohibited` (2).
    *   **Secondary Sort:** `isActive`. Prefer `true` (focused) over `false`.
    *   **Tertiary Sort:** `launchDate`. Prefer the most recently launched instance.
4.  Select the top candidate.

**Verification (Automated):**
*   **Unit Test (`testAppSelectionSorting`):** Define a mock `SortableApp` structure (replicating `NSRunningApplication` properties) and verify that a sorting function using the new criteria correctly ranks a "Regular + Active" app above an "Accessory" app, and a "Newer" app above an "Older" one.

## 5. Fix Brittle Diffing Logic

**Objective:** Distinguish between "Modified" elements (moved, text changed) and "Removed/Added" elements.

**File:** `Sources/MacosUseSDK/ActionCoordinator.swift`

**Action:**
1.  Update `performAction` (Diff Calculation section).
2.  Implement a two-pass matching algorithm:
    *   **Pass 1 (Identity Match):** Match `before` and `after` elements if they have the same `Role`, `Path`, AND `Text`.
    *   **Pass 2 (Fuzzy Match):** Match if `Role` matches AND (`Text` matches OR `Geometry` is within tolerance).
3.  If a match is found:
    *   Compare `Geometry`. If different > tolerance, add `AttributeChangeDetail` for x/y/w/h.
    *   Compare `Text`. If different, add `AttributeChangeDetail` for text.
    *   Add to `modified` list if any changes found.

**Verification (Automated):**
*   **Unit Test (`testDiffingHeuristics`):** Provide two `[ElementData]` arrays where one element has moved by 10 points and another has changed its text. Assert that the resulting `TraversalDiff` contains 0 additions/removals and 2 `modified` elements with the correct change details.

## 6. Fix Fire-and-Forget Visualization

**Objective:** Ensure visualizations persist and are visible, especially in short-lived CLI executions.

**File:** `Sources/MacosUseSDK/HighlightInput.swift` & `ActionCoordinator.swift`

**Action:**
1.  Update visualization functions (e.g., `clickMouseAndVisualize`) to be `async` and **await** the completion of the visual effect.
2.  Remove the detached `Task { @MainActor ... }` wrapper *inside* the low-level functions.

**Verification (Automated):**
*   **Unit Test (`testVisualizationAwaitsDuration`):** Measure the execution time of `clickMouseAndVisualize` (with a mocked input side) and assert that the elapsed time is greater than or equal to the requested `duration`. This proves the function is now correctly awaiting the visualization's lifecycle.