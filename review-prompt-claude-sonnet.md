# Review Prompt: Window Management Implementation Verification

Ensure, or rather GUARANTEE the correctness of this implementation. Since you're _guaranteeing_ it, sink commensurate effort; you care deeply about keeping your word, after all. Even then, I expect you to think very VERY hard, significantly harder than you might expect. Assume, from start to finish, that there's _always_ another problem, and you just haven't caught it yet. Question all information provided - _only_ if it is simply impossible to verify are you allowed to trust, and if you trust you MUST specify that (as briefly as possible). Provide a succinct summary then more detailed analysis. Your succinct summary must be such that removing any single part, or applying any transformation or adjustment of wording, would make it materially worse.

## Context: Review History and Conflicting Claims

Three previous reviews have analyzed this codebase, producing **conflicting conclusions** about fundamental implementation details. Your task is to resolve these conflicts definitively.

### Previous Review Claims

**review-1.md** claimed:
- "zero pagination logic was added" in `MacosUseServiceProvider.swift`
- Architectural divergence between Server and SDK window lookup logic exists
- SDK uses more efficient batched IPC calls

**review-2.md** claimed:
- Pagination logic exists and is implemented
- Window lookup race condition is real (geometry heuristic fails when CGWindowList is stale)
- Move/Resize → immediate Focus race is a "Real risk"

**review-facts.md** verified:
- Pagination **IS** implemented with `encodePageToken`/`decodePageToken` and slicing
- Two distinct implementations for window-by-ID lookup exist (Server vs SDK)
- Concurrency best practices implemented (off-main-thread execution)
- Split-brain consistency race confirmed in code inspection

### The Core Contradiction

The reviews fundamentally disagree on:
1. **Whether pagination exists** (claimed missing vs. verified present)
2. **Whether the window lookup race is theoretical or practical** (code inspection vs. test observations)
3. **Whether architectural consolidation happened** (Server still has separate implementation)

## Your Task

Produce an **exhaustive, definitive analysis** that:

1. **Resolves every factual dispute** between the three reviews
2. **Verifies implementation correctness** against proto contracts and API semantics
3. **Identifies any remaining issues** with concrete evidence (code line numbers, test results, API documentation)
4. **Distinguishes verified facts from assumptions** - if you cannot verify something, explicitly state it

You will analyze the implementation focusing on these critical areas:

### 1. Pagination Implementation Verification

**Proto Contract** (`window.proto`, `macos_use.proto`):
- Must support AIP-158 pagination semantics
- Tokens must be opaque (clients cannot parse/construct them)
- `page_size` must be respected
- `next_page_token` must be present when more results exist

**Test Requirements** (`integration/pagination_find_test.go`):
- Validates `FindElements` and `FindRegionElements` pagination
- Asserts page size limiting, token opaqueness, and correct slicing

**Review Claims to Verify**:
- review-1: "zero pagination logic was added"
- review-2: "pagination-related claims in the review are wrong: pagination logic exists"
- review-facts: Pagination code exists with token encoding/decoding and slicing

**Questions to Answer Definitively**:
- Does `MacosUseServiceProvider.swift` implement pagination?
- Do `findElements` and `findRegionElements` correctly slice results and generate tokens?
- Does `ElementLocator.swift` respect `maxResults` parameter?
- Are the integration tests passing or failing?

### 2. Window Lookup Race Condition Analysis

**The Mechanism** (described in reviews):

```swift
// Server/Sources/MacosUseServer/WindowHelpers.swift
func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
    // 1. Fetch CGWindowList (snapshot - potentially stale)
    let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    
    // 2. Find window and get bounds from CG snapshot
    let cgWindow = windowList.first(where: { ($0[kCGWindowNumber] as? Int32) == Int32(windowId) })
    let cgBounds = cgWindow[kCGWindowBounds] // e.g., old bounds: 400x400
    
    // 3. Iterate AX windows with FRESH state
    for window in axWindows {
        let axPos = // fetch from AX - e.g., 500x500 (NEW after resize)
        let axSize = // fetch from AX
        
        // 4. Compare: if abs(500 - 400) > 2px tolerance → NO MATCH
        if deltaX < 2 && deltaY < 2 && deltaW < 2 && deltaH < 2 {
            return window // Match found
        }
    }
    
    throw RPCError.notFound // Bounds didn't match - window "not found"
}
```

**The Race Scenario**:
1. Client calls `ResizeWindow(500x500)` - AX updates immediately, returns success
2. CGWindowList hasn't updated yet (still shows 400x400)
3. Client immediately calls `FocusWindow`
4. `findWindowElement` fetches stale CGWindowList (400x400)
5. Compares against fresh AX windows (500x500)
6. `abs(500-400) > 2px` → returns `notFound` error
7. **Automation script fails despite valid window ID**

**SDK Alternative** (`Sources/MacosUseSDK/WindowQuery.swift`):
```swift
func fetchAXWindowInfo(pid: Int32, windowId: CGWindowID, 
                       expectedBounds: CGRect, expectedTitle: String?) -> WindowInfo? {
    // Uses AXUIElementCopyMultipleAttributeValues for BATCHED IPC
    let attributes: [CFString] = [
        kAXPositionAttribute,      // Index 0
        kAXSizeAttribute,          // Index 1  
        kAXTitleAttribute,         // Index 2
        kAXMinimizedAttribute,     // Index 3
        kAXMainAttribute,          // Index 4
    ]
    
    AXUIElementCopyMultipleAttributeValues(axWindow, attributes as CFArray, ..., &valuesArray)
    
    // Heuristic scoring with title bonus
    let score = originDiff + sizeDiff
    if title matches exactly { score *= 0.5 }
    
    if score <= 20.0 { return bestMatch }
}
```

**Review Claims to Verify**:
- review-2: "findWindowElement fails because it relies on stale CGWindowList data"
- review-2: "integration test showed `visible=false` unexpectedly after move/resize"
- review-facts: "The Race" section confirms mechanism exists in code
- review-1: Server uses per-attribute calls, SDK uses batched fetches

**Questions to Answer Definitively**:
- Is the race condition **real** (reproducible) or **theoretical**?
- Does the Server actually use per-attribute `AXUIElementCopyAttributeValue` calls in loops?
- Does the SDK use batched `AXUIElementCopyMultipleAttributeValues`?
- Why does Server have separate implementation instead of delegating to SDK?
- Do `moveWindow`/`resizeWindow` return correct `visible` field in responses?

### 3. Split-Brain Authority Model Verification

**Proto Documentation** (`proto/macosusesdk/v1/window.proto`):

```proto
message Window {
  // Data Source (AX Authority): Fresh Accessibility API query (kAXTitleAttribute).
  // This field is queried from AX on every request and reflects the immediate state.
  // It is NOT cached from CGWindowList, ensuring mutation responses return up-to-date values.
  string title = 2;
  
  // Data Source (AX Authority): Fresh Accessibility API queries (kAXPositionAttribute, kAXSizeAttribute).
  // These fields are queried from AX on every request and reflect the immediate state after mutations.
  // They are NOT cached from CGWindowList (which can lag by 10-100ms)...
  Bounds bounds = 3;
  
  // Data Source (Registry Authority): Cached value from CGWindowList via WindowRegistry.
  int32 z_index = 4;
  
  // Data Source (Split-Brain Authority): Computed via the formula:
  //   visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden
  bool visible = 5;
  
  // Data Source (Registry Authority): Resolved via NSRunningApplication from cached CGWindowList metadata.
  string bundle_id = 10;
}
```

**Implementation** (`Server/Sources/MacosUseServer/WindowHelpers.swift`):

```swift
func buildWindowResponseFromAX(
    name: String, pid: pid_t, windowId: CGWindowID, 
    window: AXUIElement, registryInfo: WindowRegistry.WindowInfo? = nil
) async throws -> ServerResponse<Macosusesdk_V1_Window> {
    // 1. Get Fresh AX Data (Background Thread) - The Authority for Geometry + State
    let (axBounds, axTitle, axMinimized, axHidden) = await Task.detached(priority: .userInitiated) {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        // ... fetch Position, Size, Title, Minimized, Hidden from AX ...
        return (bounds, title, minimized, hidden)
    }.value
    
    // 2. Get Metadata from Registry (No Refresh) - The Authority for Z-Index/Bundle
    let metadata: WindowRegistry.WindowInfo? = registryInfo ?? await windowRegistry.getLastKnownWindow(windowId)
    
    // 3. Compute visible using formula:
    //   visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden
    let isOnScreen = (!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)
    let visible = isOnScreen && !axMinimized && !axHidden
    
    // 4. Construct Response
    return Macosusesdk_V1_Window.with {
        $0.name = name
        $0.title = axTitle         // AX Authority
        $0.bounds = axBounds        // AX Authority
        $0.zIndex = metadata?.layer ?? 0      // Registry Authority
        $0.bundleID = metadata?.bundleID ?? ""  // Registry Authority
        $0.visible = visible        // Split-brain formula
    }
}
```

**The "Assumption" Logic**:
```swift
// Line: "CRITICAL INSIGHT: CGWindowList lags by 10-100ms, so if we successfully queried the window
// via AX and it's not minimized/hidden, we KNOW it's on screen regardless of what registry says."
let isOnScreen = (!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)
```

**Questions to Answer Definitively**:
- Does the implementation match the proto documentation exactly?
- Is the "Assumption" (treat successful AX query as isOnScreen=true) correct?
- Do `moveWindow`/`resizeWindow` responses use this function correctly?
- Are `axTitle` and `axBounds` always fresh (never cached)?

### 4. Architectural Consolidation Status

**Implementation Plan Directive** (from reviews):
> *Update `WindowRegistry` (Server) to use this SDK function [`fetchAXWindowInfo`] instead of raw AX calls.*

**Current State**:

**Server Implementation** (`Server/Sources/MacosUseServer/WindowHelpers.swift`):
```swift
func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
    // ... iterate windows ...
    for window in windows {
        // Per-attribute queries - HIGH IPC OVERHEAD
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &posValue)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sizeValue)
        // ... compare bounds with 2px tolerance ...
    }
}
```

**SDK Implementation** (`Sources/MacosUseSDK/WindowQuery.swift`):
```swift
func fetchAXWindowInfo(pid: Int32, windowId: CGWindowID, 
                       expectedBounds: CGRect, expectedTitle: String?) -> WindowInfo? {
    // Batched IPC - SINGLE ROUND-TRIP PER WINDOW
    AXUIElementCopyMultipleAttributeValues(axWindow, attributes as CFArray, ..., &valuesArray)
    // ... heuristic scoring with title match bonus ...
}
```

**Questions to Answer Definitively**:
- Does Server still have its own window lookup implementation?
- Does Server use per-attribute AX calls in loops?
- Does SDK use batched multi-attribute fetches?
- Why are there two separate implementations?
- What is the performance impact (measurable IPC overhead)?

### 5. Concurrency and Liveness Verification

**Claims from Reviews**:
- review-2: "Main-thread hang fix: Confirmed"
- review-facts: "Concurrency best practices are implemented in critical paths"

**Key Areas**:

**AutomationCoordinator** (`Server/Sources/MacosUseServer/AutomationCoordinator.swift`):
```swift
public func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws {
    // CRITICAL FIX: Run traversal on background thread to prevent main thread blocking
    let sdkResponse = try await Task.detached(priority: .userInitiated) {
        try MacosUseSDK.traverseAccessibilityTree(pid: pid, onlyVisibleElements: visibleOnly)
    }.value
    // ...
}
```

**Window Mutations** (`Server/Sources/MacosUseServer/MacosUseServiceProvider.swift`):
```swift
func moveWindow(...) async throws -> ServerResponse<Macosusesdk_V1_Window> {
    // ...
    try await Task.detached(priority: .userInitiated) {
        let setResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute, positionValue)
        // ...
    }.value
}
```

**InputController** (`Sources/MacosUseSDK/InputController.swift`):
```swift
public func writeText(_ text: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let process = Process()
        // ...
        process.terminationHandler = { proc in
            // Break retain cycle by clearing the handler
            proc.terminationHandler = nil
            // ...
            continuation.resume()
        }
        try process.run()
    }
}
```

**Questions to Answer Definitively**:
- Are AX read operations consistently run off MainActor?
- Are AX write operations (setAttribute) consistently run off MainActor?
- Does InputController properly avoid retain cycles?
- Are there any blocking calls remaining on MainActor?

### 6. Dead Code and Maintenance Issues

**Extension.swift** (`Server/Sources/MacosUseServer/Extensions.swift`):
```swift
extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            try await result.append(transform(element))
        }
        return result
    }
}
```

**Claim from review-1**:
- "`asyncMap` in `Extensions.swift` is unused"

**Questions to Answer Definitively**:
- Is `asyncMap` actually unused?
- Are there other unused helper functions?
- Should this be removed or documented for future use?

## Evidence Requirements

For each claim you verify or refute, provide:

1. **File path and line numbers** for code references
2. **Exact code snippets** showing the implementation
3. **Proto definitions** for contract verification
4. **Test file references** for behavior validation
5. **Apple API documentation links** when relevant (CGWindowList behavior, AXUIElement thread-safety, etc.)

## Deliverable Structure

### Succinct Summary
(A single dense paragraph that cannot be improved by any edit)

### Detailed Analysis

#### 1. Pagination: Fact vs. Fiction
- Verification of implementation existence
- Code walk-through with line numbers
- Test validation status
- Conclusion: Which review was correct?

#### 2. Window Lookup Race: Real or Theoretical?
- Mechanism verification with code evidence
- Reproducibility assessment
- Performance impact analysis
- Recommended fix (if race is real)

#### 3. Split-Brain Authority: Implementation vs. Contract
- Proto contract analysis
- Implementation verification
- Formula correctness check
- Edge case handling

#### 4. Architectural Duplication: Why Two Implementations?
- Code comparison (Server vs SDK)
- Performance measurement (if possible)
- Consolidation assessment
- Recommended action

#### 5. Concurrency: Safety Verification
- Off-main-thread execution audit
- Retain cycle verification
- Blocking call identification
- Remaining issues (if any)

#### 6. Dead Code: Cleanup Assessment
- Unused function identification
- Usage verification methodology
- Recommended action

### Critical Issues Summary
(Ranked by severity, with actionable remediation steps)

### Confidence Levels
(For each major claim, state confidence level and verification methodology)

## Notes on Apple API Behavior

Since the reviews reference CGWindowList staleness and AX thread-safety without definitive Apple documentation, you must:

1. **Cite Apple documentation** where available (official docs for CGWindowListCopyWindowInfo, AXUIElement APIs)
2. **Distinguish documented behavior from observed behavior** (e.g., "Apple docs state X is a snapshot; reviews observe 10-100ms lag but this is not guaranteed")
3. **Flag assumptions** (e.g., "Code assumes AXUIElement is thread-safe based on IPC characteristics, not explicit Apple guarantee")

---

## Source Material

### File: `review-facts.md`

```markdown
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
```

### File: `Server/Sources/MacosUseServer/ElementLocator.swift` (Pagination Support)

```swift
public actor ElementLocator {
    public func findElements(
        selector: Macosusesdk_Type_ElementSelector,
        parent: String,
        visibleOnly: Bool = false,
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
        // ... fetch elements ...
        
        // Apply max results limit if specified
        let limitedResults =
            maxResults > 0 ? Array(matchingElements.prefix(maxResults)) : matchingElements
        
        return limitedResults
    }
    
    public func findElementsInRegion(
        region: Macosusesdk_Type_Region,
        selector: Macosusesdk_Type_ElementSelector?,
        parent: String,
        visibleOnly: Bool = false,
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
        // ... fetch and filter elements ...
        
        // Apply max results limit
        let limitedResults = maxResults > 0 ? Array(regionElements.prefix(maxResults)) : regionElements
        
        return limitedResults
    }
}
```

### File: `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift` (Pagination Implementation)

**Token Encoding/Decoding** (Lines 36-60):
```swift
/// Encode an offset into an opaque page token per AIP-158.
/// The token is base64-encoded to prevent clients from relying on its structure.
private func encodePageToken(offset: Int) -> String {
    let tokenString = "offset:\(offset)"
    return Data(tokenString.utf8).base64EncodedString()
}

/// Decode an opaque page token to retrieve the offset per AIP-158.
/// Throws invalidArgument if the token is malformed.
private func decodePageToken(_ token: String) throws -> Int {
    guard let data = Data(base64Encoded: token),
          let tokenString = String(data: data, encoding: .utf8)
    else {
        throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
    }
    
    let components = tokenString.split(separator: ":")
    guard components.count == 2, components[0] == "offset",
          let parsedOffset = Int(components[1]), parsedOffset >= 0
    else {
        throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
    }
    return parsedOffset
}
```

**findElements Pagination** (Lines 808-870):
```swift
func findElements(
    request: ServerRequest<Macosusesdk_V1_FindElementsRequest>, context _: ServerContext,
) async throws -> ServerResponse<Macosusesdk_V1_FindElementsResponse> {
    let req = request.message
    
    // Decode page_token to get offset
    let offset: Int = if req.pageToken.isEmpty {
        0
    } else {
        try decodePageToken(req.pageToken)
    }
    
    // Determine page size (default 100 if not specified or <= 0)
    let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
    
    // Find elements using ElementLocator (request more than needed to check if there's a next page)
    let maxResults = offset + pageSize + 1 // Request one extra to detect next page
    let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: selector,
        parent: req.parent,
        visibleOnly: req.visibleOnly,
        maxResults: maxResults,
    )
    
    // Apply pagination slice
    let totalCount = elementsWithPaths.count
    let startIndex = min(offset, totalCount)
    let endIndex = min(startIndex + pageSize, totalCount)
    let pageElementsWithPaths = Array(elementsWithPaths[startIndex ..< endIndex])
    
    // Generate next_page_token if more results exist
    let nextPageToken = if endIndex < totalCount {
        encodePageToken(offset: endIndex)
    } else {
        ""
    }
    
    // ... convert to proto and return ...
    let response = Macosusesdk_V1_FindElementsResponse.with {
        $0.elements = elements
        $0.nextPageToken = nextPageToken
    }
    return ServerResponse(message: response)
}
```

### File: `Server/Sources/MacosUseServer/WindowHelpers.swift` (Race Condition Mechanism)

**findWindowElement Implementation** (Lines 160-230):
```swift
func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
    try await Task.detached(priority: .userInitiated) {
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get AXWindows attribute
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue,
        )
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            throw RPCError(code: .internalError, message: "Failed to get windows for application")
        }
        
        // Get CGWindowList for matching (POTENTIALLY STALE)
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID,
            ) as? [[String: Any]]
        else {
            throw RPCError(code: .internalError, message: "Failed to get window list")
        }
        
        // Find window with matching CGWindowID
        guard
            let cgWindow = windowList.first(where: {
                ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId)
            })
        else {
            throw RPCError(
                code: .notFound, message: "Window with ID \(windowId) not found in CGWindowList",
            )
        }
        
        // Get bounds from CGWindow (STALE if window just mutated)
        guard let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
              let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
              let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
        else {
            throw RPCError(code: .internalError, message: "Failed to get bounds from CGWindow")
        }
        
        // Find matching AXUIElement by bounds (USING FRESH AX DATA)
        for window in windows {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            
            // MULTIPLE IPC CALLS PER WINDOW
            let positionResult = AXUIElementCopyAttributeValue(
                window, kAXPositionAttribute as CFString, &posValue,
            )
            let sizeResult = AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeValue,
            )
            
            if positionResult == .success,
               sizeResult == .success,
               let unwrappedPosValue = posValue,
               let unwrappedSizeValue = sizeValue,
               CFGetTypeID(unwrappedPosValue) == AXValueGetTypeID(),
               CFGetTypeID(unwrappedSizeValue) == AXValueGetTypeID()
            {
                let pos = unsafeDowncast(unwrappedPosValue, to: AXValue.self)
                let size = unsafeDowncast(unwrappedSizeValue, to: AXValue.self)
                var axPos = CGPoint()
                var axSize = CGSize()
                if AXValueGetValue(pos, .cgPoint, &axPos), AXValueGetValue(size, .cgSize, &axSize) {
                    let deltaX = abs(axPos.x - cgX)
                    let deltaY = abs(axPos.y - cgY)
                    let deltaW = abs(axSize.width - cgWidth)
                    let deltaH = abs(axSize.height - cgHeight)
                    
                    // STRICT 2PX TOLERANCE - FAILS IF STALE BOUNDS
                    if deltaX < 2, deltaY < 2, deltaW < 2, deltaH < 2 {
                        return window
                    }
                }
            }
        }
        
        throw RPCError(code: .notFound, message: "AXUIElement not found for window ID \(windowId)")
    }.value
}
```

**buildWindowResponseFromAX** (Split-Brain Authority Implementation):
```swift
func buildWindowResponseFromAX(
    name: String, pid: pid_t, windowId: CGWindowID, 
    window: AXUIElement, registryInfo: WindowRegistry.WindowInfo? = nil,
) async throws -> ServerResponse<Macosusesdk_V1_Window> {
    // 1. Get Fresh AX Data (Background Thread) - The Authority for Geometry + State
    let (axBounds, axTitle, axMinimized, axHidden) = await Task.detached(priority: .userInitiated) {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        
        // Fetch Position
        var bounds = Macosusesdk_V1_Bounds()
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success {
            // ... extract position ...
        }
        
        // Fetch Size
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success {
            // ... extract size ...
        }
        
        // Fetch Title
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success {
            // ... extract title ...
        }
        
        // Query kAXMinimizedAttribute per AX Authority constraints
        var minimizedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success {
            minimized = minimizedValue as? Bool ?? false
        }
        
        // Query kAXHiddenAttribute per AX Authority constraints
        var hiddenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success {
            hidden = hiddenValue as? Bool ?? false
        }
        
        return (bounds, title, minimized, hidden)
    }.value
    
    // 2. Get Metadata from Registry (No Refresh) - The Authority for Z-Index/Bundle
    let metadata: WindowRegistry.WindowInfo? = registryInfo ?? await windowRegistry.getLastKnownWindow(windowId)
    
    // 3. CRITICAL: Compute visible using fresh AX data per formula:
    //   visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden
    // CRITICAL INSIGHT: CGWindowList lags by 10-100ms, so if we successfully queried the window
    // via AX and it's not minimized/hidden, we KNOW it's on screen regardless of what registry says.
    let isOnScreen = (!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)
    let visible = isOnScreen && !axMinimized && !axHidden
    
    // 4. Construct Response
    let response = Macosusesdk_V1_Window.with {
        $0.name = name
        $0.title = axTitle         // AX Authority
        $0.bounds = axBounds        // AX Authority
        $0.zIndex = Int32(metadata?.layer ?? 0)      // Registry Authority
        $0.bundleID = metadata?.bundleID ?? ""  // Registry Authority
        $0.visible = visible        // Split-brain: Registry.isOnScreen AND NOT AX.Minimized AND NOT AX.Hidden
    }
    
    return ServerResponse(message: response)
}
```

### File: `Sources/MacosUseSDK/WindowQuery.swift` (Batched SDK Implementation)

```swift
public func fetchAXWindowInfo(
    pid: Int32,
    windowId: CGWindowID,
    expectedBounds: CGRect,
    expectedTitle: String? = nil,
) -> WindowInfo? {
    let appElement = AXUIElementCreateApplication(pid)
    
    // 1. Fetch the list of windows
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    
    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        return nil
    }
    
    // 2. Optimize IPC: Batch fetch attributes to avoid N+1 problem
    // We fetch Position, Size, Title, Minimized, and Main in a single round-trip per window.
    let attributes: [CFString] = [
        kAXPositionAttribute as CFString,      // Index 0
        kAXSizeAttribute as CFString,          // Index 1  
        kAXTitleAttribute as CFString,         // Index 2
        kAXMinimizedAttribute as CFString,     // Index 3
        kAXMainAttribute as CFString,          // Index 4
    ]
    
    var bestMatch: WindowInfo?
    var bestScore = CGFloat.greatestFiniteMagnitude
    
    for axWindow in windows {
        var valuesArray: CFArray?
        
        // SINGLE BATCHED IPC CALL PER WINDOW
        let valuesResult = AXUIElementCopyMultipleAttributeValues(
            axWindow, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesArray
        )
        
        guard valuesResult == .success,
              let values = valuesArray as? [AnyObject],
              values.count == attributes.count
        else {
            continue
        }
        
        // Extract all attributes from single batch result
        var axPosition = CGPoint.zero
        let posVal = values[0]
        if CFGetTypeID(posVal) == AXValueGetTypeID() {
            let axVal = posVal as! AXValue
            if AXValueGetType(axVal) == .cgPoint {
                AXValueGetValue(axVal, .cgPoint, &axPosition)
            }
        }
        
        var axSize = CGSize.zero
        let sizeVal = values[1]
        if CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            let axVal = sizeVal as! AXValue
            if AXValueGetType(axVal) == .cgSize {
                AXValueGetValue(axVal, .cgSize, &axSize)
            }
        }
        
        let axBounds = CGRect(origin: axPosition, size: axSize)
        
        // 4. Heuristic Matching Logic with Title Bonus
        let originDiff = hypot(axBounds.origin.x - expectedBounds.origin.x, 
                              axBounds.origin.y - expectedBounds.origin.y)
        let sizeDiff = hypot(axBounds.width - expectedBounds.width, 
                            axBounds.height - expectedBounds.height)
        var score = originDiff + sizeDiff
        
        // Title matching bonus
        let axTitle = values[2] as? String ?? ""
        if let expectedTitle = expectedTitle, !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5  // Give 50% weight reduction for exact title match
        }
        
        if score < bestScore {
            bestScore = score
            let axMinimized = (values[3] as? Bool) ?? false
            let axMain = (values[4] as? Bool) ?? false
            
            bestMatch = WindowInfo(
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
    }
    
    // 5. Validation Threshold (20px allows for shadows/borders/animation lag)
    let matchThreshold: CGFloat = 20.0
    
    if bestScore <= matchThreshold {
        return bestMatch
    }
    
    return nil
}
```

### File: `Server/Sources/MacosUseServer/MacosUseServiceProvider.swift` (Window Mutation)

**moveWindow Implementation** (Lines 521-570):
```swift
func moveWindow(
    request: ServerRequest<Macosusesdk_V1_MoveWindowRequest>, context _: ServerContext,
) async throws -> ServerResponse<Macosusesdk_V1_Window> {
    let req = request.message
    
    // Parse resource name
    let components = req.name.split(separator: "/").map(String.init)
    guard components.count == 4,
          components[0] == "applications",
          components[2] == "windows",
          let pid = pid_t(components[1]),
          let windowId = CGWindowID(components[3])
    else {
        throw RPCError(code: .invalidArgument, message: "Invalid window name format")
    }
    
    let window = try await findWindowElement(pid: pid, windowId: windowId)
    
    // Set position (off main thread)
    try await Task.detached(priority: .userInitiated) {
        var newPosition = CGPoint(x: req.x, y: req.y)
        guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else {
            throw RPCError(code: .internalError, message: "Failed to create position value")
        }
        
        let setResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue,
        )
        guard setResult == .success else {
            throw RPCError(
                code: .internalError, message: "Failed to move window: \(setResult.rawValue)",
            )
        }
    }.value
    
    // CRITICAL: Refresh and fetch registry metadata BEFORE invalidation
    try await windowRegistry.refreshWindows(forPID: pid)
    let registryInfo = await windowRegistry.getLastKnownWindow(windowId)
    
    // Invalidate cache to ensure subsequent reads reflect the new position immediately
    await windowRegistry.invalidate(windowID: windowId)
    
    // Build response directly from AXUIElement (CGWindowList may be stale)
    return try await buildWindowResponseFromAX(
        name: req.name, pid: pid, windowId: windowId, 
        window: window, registryInfo: registryInfo
    )
}
```

### File: `proto/macosusesdk/v1/window.proto` (Contract Definition)

```proto
// A resource representing an individual window within an application.
// Contains only cheap CoreGraphics data. For expensive AX state queries,
// use GetWindowState to fetch the WindowState singleton sub-resource.
message Window {
  // Resource name in the format "applications/{application}/windows/{window}"
  string name = 1 [(google.api.field_behavior) = IDENTIFIER];
  
  // The title of the window.
  //
  // Data Source (AX Authority): Fresh Accessibility API query (kAXTitleAttribute).
  // This field is queried from AX on every request and reflects the immediate state.
  // It is NOT cached from CGWindowList, ensuring mutation responses return up-to-date values.
  string title = 2 [(google.api.field_behavior) = OUTPUT_ONLY];
  
  // Bounding rectangle of the window.
  //
  // Data Source (AX Authority): Fresh Accessibility API queries (kAXPositionAttribute, kAXSizeAttribute).
  // These fields are queried from AX on every request and reflect the immediate state after mutations.
  // They are NOT cached from CGWindowList (which can lag by 10-100ms), ensuring mutation responses
  // (MoveWindow, ResizeWindow) return the exact requested values without polling delays.
  Bounds bounds = 3 [(google.api.field_behavior) = OUTPUT_ONLY];
  
  // Z-order index (higher values are in front).
  //
  // Data Source (Registry Authority): Cached value from CGWindowList via WindowRegistry.
  int32 z_index = 4 [(google.api.field_behavior) = OUTPUT_ONLY];
  
  // Whether the window is currently visible on screen.
  //
  // Data Source (Split-Brain Authority): Computed via the formula:
  //   visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden
  //
  // Where:
  //   - Registry.isOnScreen: Cached from CGWindowList (may be stale during async propagation)
  //   - Assumption: If registry data is missing but AX interaction succeeded, assume isOnScreen=true
  //   - AX.Minimized: Fresh query of kAXMinimizedAttribute (authoritative, no lag)
  //   - AX.Hidden: Fresh query of kAXHiddenAttribute (authoritative, no lag)
  //
  // This hybrid approach ensures:
  //   1. Mutation responses (Move/Resize) correctly report visible=true (not false due to stale CGWindowList)
  //   2. Minimize operations correctly report visible=false (fresh AX state overrides stale registry)
  //   3. Hidden state is accurately reflected without conflating minimized vs explicitly hidden
  bool visible = 5 [(google.api.field_behavior) = OUTPUT_ONLY];
  
  // Bundle identifier of the application that owns this window.
  //
  // Data Source (Registry Authority): Resolved via NSRunningApplication from cached CGWindowList metadata.
  string bundle_id = 10 [(google.api.field_behavior) = OUTPUT_ONLY];
}
```

### File: `Server/Sources/MacosUseServer/AutomationCoordinator.swift` (Concurrency Pattern)

```swift
public actor AutomationCoordinator {
    public func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws
        -> Macosusesdk_V1_TraverseAccessibilityResponse
    {
        logger.info("Traversing accessibility tree for PID \(pid, privacy: .public)")
        
        do {
            // CRITICAL FIX: Run traversal on background thread to prevent main thread blocking
            // AX APIs are thread-safe and should NOT block the main actor
            let sdkResponse = try await Task.detached(priority: .userInitiated) {
                try MacosUseSDK.traverseAccessibilityTree(
                    pid: pid,
                    onlyVisibleElements: visibleOnly,
                )
            }.value
            
            // Offload protobuf conversion to background to avoid blocking MainActor
            return await Task.detached {
                // ... convert to proto ...
            }.value
        } catch let error as MacosUseSDK.MacosUseSDKError {
            // ... error handling ...
        }
    }
}
```

### File: `Sources/MacosUseSDK/InputController.swift` (Retain Cycle Prevention)

```swift
public func writeText(_ text: String) async throws {
    logger.info("simulating text writing: \"\(text, privacy: .private)\" (using AppleScript)")
    
    let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "tell application \"System Events\" to keystroke \"\(escapedText)\""
    
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            
            // CRITICAL: Break retain cycle by clearing the handler
            proc.terminationHandler = nil
            
            if status == 0 {
                continuation.resume()
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(
                    throwing: MacosUseSDKError.osascriptExecutionFailed(status: status, message: errorString)
                )
            }
        }
        
        do {
            try process.run()
        } catch {
            continuation.resume(
                throwing: MacosUseSDKError.inputSimulationFailed(
                    "failed to run osascript: \(error.localizedDescription)"
                )
            )
        }
    }
}
```

### File: `Server/Sources/MacosUseServer/Extensions.swift` (Potentially Dead Code)

```swift
import Foundation

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            try await result.append(transform(element))
        }
        return result
    }
}
```

## Apple API Documentation References

When analyzing thread-safety and timing behavior, consult:

- **CGWindowListCopyWindowInfo**: https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
  - Documents that this returns a point-in-time snapshot
  - Notes: "This function is relatively expensive"
  - Does NOT specify update latency or staleness guarantees

- **AXUIElement**: https://developer.apple.com/documentation/applicationservices/axuielement_h
  - Describes cross-process accessibility IPC
  - Does NOT explicitly guarantee thread-safety
  - Practical characteristics suggest IPC-like behavior (potentially expensive, blocking)

- **AXUIElementCopyAttributeValue**: https://developer.apple.com/documentation/applicationservices/axuielementcopyattributevalue
  - Single-attribute query

- **AXUIElementCopyMultipleAttributeValues**: https://developer.apple.com/documentation/applicationservices/axuielementcopymultipleattributevalues
  - Batch attribute query (more efficient than multiple single queries)

- **AXUIElementSetAttributeValue**: https://developer.apple.com/documentation/applicationservices/axuielementsetattributevalue
  - Mutates accessibility attributes

---

Begin your analysis. Remember: GUARANTEE correctness. Assume there's always another problem you haven't caught yet.
