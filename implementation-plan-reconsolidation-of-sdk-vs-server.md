# Implementation Plan: Reconsolidation of SDK vs Server

**Status:** Draft
**Goal:** Consolidate `Sources/MacosUseSDK` and `Server/Sources/MacosUseServer` to eliminate divergence, prioritizing server robustness and concurrency requirements.

## 1. Core Philosophy & Constraints

*   **Server-First:** The SDK must be designed primarily as the "engine" for the gRPC server. Scripting/CLI use cases are secondary and should be built *on top* of the server-optimized SDK primitives.
*   **Concurrency:** The SDK must align with the Server's actor model. Blocking calls (e.g., `usleep`) on the Main Thread are forbidden.
*   **Statelessness (mostly):** The SDK should primarily provide stateless mechanisms (traversal, input injection, AX querying). State management (Registries, Sessions) belongs in the Server (or a high-level SDK layer if needed for standalone use).
*   **No Side Effects:** Changes must not break existing Server behavior.

## 2. Key Refactoring Areas

### 2.1. Async Input Controller (Critical for Liveness)
**Current State:** `InputController.swift` uses `usleep` for delays between input events. This blocks the underlying thread. Since `AutomationCoordinator` runs on `@MainActor`, this blocks the entire Main Loop, hurting liveness (e.g., processing other RPCs or heartbeats).
**Plan:**
*   Convert all `InputController` functions (`pressKey`, `clickMouse`, etc.) to `async`.
*   Replace `usleep` with `try await Task.sleep(nanoseconds: ...)`.
*   Update `ActionCoordinator` and `AutomationCoordinator` to `await` these calls.

### 2.2. Selector Logic Consolidation
**Current State:** `ElementLocator` (Server) implements `matchesSelector` and depends on Proto types (`Macosusesdk_Type_ElementSelector`). The SDK knows nothing about selectors, only `ElementData`.
**Plan:**
*   Define a pure Swift `ElementSelector` struct in `Sources/MacosUseSDK` (mirroring the capabilities of the Proto selector).
*   Move the `matchesSelector` logic from `ElementLocator` to a method on `ElementData` (or a helper in SDK) in `Sources/MacosUseSDK`.
*   Update `ElementLocator` (Server) to map Proto Selectors to SDK `ElementSelector` and use the SDK's matching logic.
*   *Benefit:* Allows standalone Swift scripts to use powerful selector logic without importing Protos.

### 2.3. Window Authority Primitives
**Current State:** The "Split-Brain" authority model (AX vs CG) is implemented in `WindowRegistry` (Server). The SDK has no dedicated Window management.
**Plan:**
*   Introduce `WindowInfo` struct in SDK.
*   Add `fetchAXWindowInfo(pid: Int32, windowId: Int32) -> WindowInfo?` to `Sources/MacosUseSDK`. This function will perform the "Fresh AX" queries (Bounds, Title, Minimized, Hidden) required by the Split-Brain model.
*   Update `WindowRegistry` (Server) to use this SDK function instead of raw AX calls, ensuring consistent implementation of the "AX Authority" side of the split-brain.

### 2.4. ActionCoordinator Deconstruction
**Current State:** `ActionCoordinator.swift` (SDK) has a monolithic `performAction` function that handles "Traverse Before", "Action", "Traverse After", "Diff", and "Animation".
**Plan:**
*   Keep `performAction` as a convenience wrapper, but ensure all its steps are exposed as public, composable `async` functions in SDK:
    *   `traverse(...)` (Already exists)
    *   `executeInput(...)` (Make public/accessible)
    *   `calculateDiff(before:after:)` (Make public)
    *   `visualize(...)` (Make public)
*   This allows the Server (or other consumers) to compose these steps differently if needed (e.g., "Traverse, then wait for condition, then Input").

### 2.5. Element Abstraction (Nice to Have)
**Current State:** SDK returns `ElementData` (struct). Server wraps this in `Macosusesdk_Type_Element` and manages `AXUIElement` references in `ElementRegistry`.
**Plan:**
*   Keep `ElementData` as the primary data transfer object.
*   Ensure `ElementData` contains all necessary attributes for the Server's `ElementRegistry` to function (it already has `SendableAXUIElement`).

## 3. Implementation Steps

### Step 1: Async Input Controller
1.  Modify `Sources/MacosUseSDK/InputController.swift`:
    *   Change signatures to `async throws`.
    *   Replace `usleep` with `Task.sleep`.
2.  Update `Sources/MacosUseSDK/ActionCoordinator.swift` to `await` input calls.
3.  Update `Server/Sources/MacosUseServer/AutomationCoordinator.swift` to `await` input calls.

### Step 2: Selector Logic Move
1.  Create `Sources/MacosUseSDK/ElementSelector.swift`.
2.  Define `public struct ElementSelector` (and related enums like `Criteria`, `Operator`).
3.  Implement `public func matches(element: ElementData, selector: ElementSelector) -> Bool`.
4.  Update `Server/Sources/MacosUseServer/ElementLocator.swift` to use SDK's `ElementSelector` and `matches`.

### Step 3: Window Primitives
1.  Create `Sources/MacosUseSDK/WindowQuery.swift`.
2.  Implement `fetchAXWindowInfo` using `AXUIElement` APIs.
3.  Update `Server/Sources/MacosUseServer/WindowRegistry.swift` to utilize `fetchAXWindowInfo`.

### Step 4: Cleanup & Verification
1.  Run all tests.
2.  Verify no regressions in Server behavior.
3.  Ensure `implementation-constraints.md` is respected (Logging, etc.).

## 4. Verification Plan

*   **Unit Tests:** Add tests in `Tests/MacosUseSDKTests` for:
    *   `ElementSelector` matching logic.
    *   `fetchAXWindowInfo` (mocked or real app).
*   **Integration Tests:** Run existing `integration/` tests to ensure Server behavior is unchanged.
*   **Manual Check:** Verify `InputController` no longer blocks the main thread (code review).
