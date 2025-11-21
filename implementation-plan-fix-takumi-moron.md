Here is the explicit implementation plan to rectify the architectural divergence and ensure exact behavior preservation.

## **Objective**

Restore the original **Swift Structured Concurrency** model (`Task.detached`) in `WindowHelpers.swift` to guarantee exact behavior preservation regarding cancellation propagation and thread management. Remove the unacknowledged **Grand Central Dispatch** (`DispatchQueue` + `Continuation`) rewrite and consolidate logging to prevent instance duplication.

-----

## **Phase 1: Revert Concurrency Architecture (Critical)**

### **1.1 Restore `findWindowElement` Concurrency Model**

**Target File:** `Server/Sources/MacosUseServer/WindowHelpers.swift`

1.  **Locate** the `findWindowElement(pid:windowId:)` function.
2.  **Delete** the entire body that uses `withCheckedThrowingContinuation` and `DispatchQueue.global`.
3.  **Implement** the original logic using `Task.detached`:
      * Wrap the logic in `try await Task.detached(priority: .userInitiated) { ... }.value`.
      * **Constraint:** Do not use `DispatchQueue` or `continuation`.
      * **Code Reference:** Use the exact implementation from the **deleted** section of `MacosUseServiceProvider.swift` (lines 319-380 in the diff).

**Required Implementation Structure:**

```swift
func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
    // CRITICAL: Must use Task.detached for proper cancellation support, NOT DispatchQueue
    try await Task.detached(priority: .userInitiated) {
        // [Insert original logic: AXUIElementCreateApplication -> CopyAttribute -> CGWindowList -> Match]
        // Return matching window or throw
    }.value
}
```

### **1.2 Restore `findWindowElementWithMinimizedFallback` Concurrency Model**

**Target File:** `Server/Sources/MacosUseServer/WindowHelpers.swift`

1.  **Locate** the `findWindowElementWithMinimizedFallback(pid:windowId:)` function.
2.  **Delete** the fallback logic block that uses `withCheckedThrowingContinuation`.
3.  **Implement** the fallback logic using `Task.detached`:
      * **Code Reference:** Use the exact implementation from the **deleted** section of `MacosUseServiceProvider.swift` (lines 232-316 in the diff).

**Required Implementation Structure:**

```swift
// Fallback: search kAXChildrenAttribute for minimized windows
return try await Task.detached(priority: .userInitiated) {
    // [Insert original logic: AXUIElementCreateApplication -> CopyAttribute(kAXChildrenAttribute) -> Match]
}.value
```

-----

## **Phase 2: Logger Scope & Consistency**

### **2.1 Consolidate Logger Instance**

**Target Files:** `Server/Sources/MacosUseServer/WindowHelpers.swift`, `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift`

1.  **Remove** the file-private global logger definition in `WindowHelpers.swift`:
    ```swift
    // DELETE THIS LINE
    private let logger = MacosUseSDK.sdkLogger(category: "MacosUseServiceProvider")
    ```
2.  **Verify Visibility** in `MacosUseServiceProvider.swift`:
      * Ensure the `logger` property inside `MacosUseServiceProvider` is marked `internal` (not `private`) so it can be accessed by the extension in `WindowHelpers.swift`.
3.  **Refactor Calls**:
      * Ensure calls in `WindowHelpers.swift` access the logger via the context (e.g., `Self.logger` or `logger` if static context allows) to ensure the exact same logger instance is used across the service.

-----

## **Phase 3: Verification & Guarantees**

### **3.1 Static Analysis Verification**

Perform the following checks to guarantee correctness:

1.  **Grep Check**: Run `grep "DispatchQueue.global" Server/Sources/MacosUseServer/WindowHelpers.swift`.
      * **Pass Condition**: Returns **0 results**.
2.  **Grep Check**: Run `grep "withCheckedThrowingContinuation" Server/Sources/MacosUseServer/WindowHelpers.swift`.
      * **Pass Condition**: Returns **0 results**.
3.  **Grep Check**: Run `grep "Task.detached" Server/Sources/MacosUseServer/WindowHelpers.swift`.
      * **Pass Condition**: Returns **4 results** (one for each of the 4 methods: `findWindowElement`, `findWindowElementWithMinimizedFallback`, `buildWindowResponseFromAX`, `getWindowState`).

### **3.2 Logic Parity Guarantee**

  * **Verify**: The logic inside the `Task` blocks in Phase 1 must match the logic in the `MacosUseServiceProvider.swift` deletion diff **character-for-character** (excluding indentation).
  * **Guarantee**: This reverts the implicit architectural change, ensuring that if the parent task is cancelled, the structured concurrency model behaves exactly as it did prior to the refactor.