# Performance Analysis Report: MacosUseSDK Server

**Date:** 2025-01-31
**Scope:** Server/Sources/MacosUseServer/ and Sources/MacosUseSDK/
**Focus:** Performance-critical paths, bottlenecks, and optimization opportunities

---

## Executive Summary

The server implementation has several performance bottlenecks in hot code paths, primarily related to:

1. **Excessive IPC overhead** from repeated AX API calls without batching
2. **No caching of traversal results** causing full tree traversals on every query
3. **Inefficient polling patterns** in observations that trigger expensive operations
4. **Per-call overhead** in screenshot capture and input simulation
5. **Lack of performance monitoring** making it difficult to identify issues in production

**Critical Path Latency (Estimates):**
- `traverseAccessibilityTree()`: 100-500ms for typical applications (Text Editor, Finder)
- `ListWindows`: 10-50ms (CGWindowList) + optional AX queries (50-200ms per window)
- `ScreenshotCapture`: 200-500ms (SCStream setup/stream/teardown)
- Observation polling: Scales linearly with observation count × poll interval

---

## 1. Performance-Critical Code Paths

### 1.1 Accessibility Tree Traversal (HOT PATH)

**Location:** `Sources/MacosUseSDK/AccessibilityTraversal.swift`

**Critical Operations:**
```swift
// Lines 175-568: Main traversal function
public func traverseAccessibilityTree(pid: Int32, onlyVisibleElements: Bool = false) throws -> ResponseData
```

**Performance Impact:**
- Performs `AXUIElementCopyAttributeValue` for EVERY element, EVERY attribute
- Each attribute call = 1 IPC round-trip to Accessibility server
- For 100 elements with 8 attributes = 800+ IPC calls
- **NO caching mechanism in SDK layer**
- Traversal is fully recursive - explores entire tree

**Hot Code:**
```swift
// Lines 256-285: Extracts attributes via individual IPC calls per attribute
func extractElementAttributes(element: AXUIElement) -> (...) {
    // Each of these is a separate IPC call:
    if let roleValue = copyAttributeValue(element: element, attribute: kAXRoleAttribute) { ... }
    if let roleDescValue = copyAttributeValue(...) { ... }  // IPC
    for attr in textAttributes {
        if let attrValue = copyAttributeValue(...) { ... }  // IPC per attribute
    }
    if let posValue = copyAttributeValue(...) { ... }  // IPC
    if let sizeValue = copyAttributeValue(...) { ... }  // IPC
    // ... more IPC calls
}
```

**Performance Issues:**
1. No use of `AXUIElementCopyMultipleAttributeValues` which can batch attribute fetches
2. No caching of element data between traversals
3. Excludes elements only AFTER fully traversing them
4. VisitedElements set prevents cycles but doesn't cache results

**Impact on Server:**
```
ObservationManager.swift - monitorObservation():
  ├─ Called every pollInterval (default 1s)
  ├─ For elementChanges: Calls handleTraverse() → traverseAccessibilityTree()
  └─ For attributeChanges: Calls handleTraverse() → traverseAccessibilityTree()
     └─ Full traversal happens EVERY poll cycle
```

---

### 1.2 Window Queries and Registry (HOT PATH)

**Location:** `Server/Sources/MacosUseServer/WindowRegistry.swift`

**Critical Operations:**
```swift
// Lines 35-73: Refreshes entire window list on every query
func refreshWindows(forPID pid: pid_t? = nil) async throws
```

**Performance Impact:**
- Cache TTL is only **1.0 second** - unnecessarily aggressive
- `listWindows()` calls `refreshWindows()` before EVERY query
- `getWindow()` checks if stale and may trigger refresh
- NO caching of window state (minimized, hidden, focused)

**Hot Code:**
```swift
// Lines 38-68: Full CGWindowList enumeration
let windowList = system.cgWindowListCopyWindowInfo(options: [...])
for windowDict in windowList {
    // Processes all windows for all processes
    // Calls NSRunningApplication() for bundle ID
}
```

**Performance Issues:**
1. Cache TTL too short - causes unnecessary refreshes
2. Bundle ID lookup via `NSRunningApplication` is called per window
3. No pre-fetching or warm cache for hot paths
4. Cache eviction removes ALL entries after TTL (no LRU)

**Impact on Server:**
```
WindowMethods.swift - listWindows():
  ├─ Calls refreshWindows()
  ├─ Calls listWindows() AFTER refresh
  └─ Registry-only response (optimized)
    └─ But refresh happens BEFORE checking if needed

WindowMethods.swift - getWindow():
  ├─ Calls findWindowElement()
  │  └─ Calls fetchAXWindowInfo() from SDK
  └─ Builds response from AX UIElement
     └─ NO caching of AX query results
```

---

### 1.3 Screenshot Capture (EXPENSIVE OPERATION)

**Location:** `Server/Sources/MacosUseServer/ScreenshotCapture.swift`

**Critical Operations:**
```swift
// Lines 35-62: Screen capture
static func captureScreen(...) async throws -> (data: Data, ...)
static func captureWindow(...) async throws -> (data: Data, ...)
static func captureRegion(...) async throws -> (data: Data, ...)
```

**Performance Impact:**
- Creates **new SCStream** for EVERY capture
- `SCShareableContent.current` fetches all displays/windows
- Stream lifecycle: startCapture → receive 1 frame → stopCapture
- Image encoding happens synchronously
- OCR via Vision framework if enabled (very expensive)

**Hot Code:**
```swift
// Lines 98-115: SCStream setup/teardown per capture
let delegate = CaptureDelegate()
let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .main)
try await withCheckedThrowingContinuation { continuation in
    delegate.continuation = continuation
    stream.startCapture { ... }  // Heavy operation
}
// Stream stopped in delegate callback after 1 frame
```

**Performance Issues:**
1. Full SCStream lifecycle overhead for every screenshot
2. NO reuse of ScreenCaptureKit streams
3. Image encoding blocks on caller
4. OCR happens synchronously during capture path
5. `CIContext` is shared but could be per-display optimized

**Impact on Server:**
- `CaptureWindowScreenshot` RPC is expensive (200-500ms)
- No caching of recent screenshots
- Polling applications that use screenshots is extremely inefficient

---

### 1.4 Observation Manager Polling (HOT PATH)

**Location:** `Server/Sources/MacosUseServer/ObservationManager.swift`

**Critical Operations:**
```swift
// Lines 162-298: Observation polling loop
private nonisolated func monitorObservation(name: String, initialState: ObservationState) async
```

**Performance Impact:**
- Runs continuously for every active observation
- Each poll triggers full AX traversal or window enumeration
- Multiple observations cause duplicate work

**Hot Code:**
```swift
// Lines 185-197: Full traversal per poll
while !Task.isCancelled {
    switch type {
    case .elementChanges, .treeChanges:
        let traverseResult = try await handleTraverse(pid: pid, visibleOnly: filter.visibleOnly)
        let currentElements = traverseResult.elements
        let changes = detectElementChanges(previous: previousElements, current: currentElements)
        // Compares ENTIRE element arrays
```

**Performance Issues:**
1. Full traversal even with NO changes (wasted work)
2. Element comparison uses O(n*m) for all elements
3. Window observation calls `fetchAXWindows()` which does batch AX queries
4. Separate observations don't share traversal results

**Impact on Server:**
- 10 observations at 1s poll = 10 full traversals per second
- With 1000-element apps = 1000k element comparisons per second
- Observations can cause AX server overload

---

### 1.5 Input Simulation (PER-OPERATION OVERHEAD)

**Location:** `Sources/MacosUseSDK/InputController.swift`

**Critical Operations:**
```swift
// Lines 61-68: Key press simulation
public func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) async throws

// Lines 110-130: Mouse click simulation
public func clickMouse(at point: CGPoint) async throws

// Lines 175-210: Text typing via osascript
public func writeText(_ text: String) async throws
```

**Performance Impact:**
- Creates **new CGEventSource** for every input operation
- `writeText()` spawns **new Process** (osascript) for every call
- 15ms delay hardcoded after every event
- NO batching of sequential input events

**Hot Code:**
```swift
// Lines 61-82: Creates source per key press
public func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) async throws {
    let source = try createEventSource()  // New source every time
    let keyDown = CGEvent(keyboardEventSource: source, ...)
    try await postEvent(keyDown, ...)
    try await Task.sleep(nanoseconds: 15_000_000)  // Hardcoded delay
    let keyUp = CGEvent(...)
    try await postEvent(keyUp, ...)
}

// Lines 175-210: osascript per text string
public func writeText(_ text: String) async throws {
    let process = Process()  // New process per text call
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    // Spawns osascript process → AppleScript → System Events
}
```

**Performance Issues:**
1. CGEventSource creation overhead (can be reused)
2. osascript spawning is slow (20-50ms per call + overhead)
3. 15ms delay is conservative but adds up
4. No way to batch multiple key presses
5. Each osascript spawns System Events subprocess

---

## 2. Expensive Operations in Hot Paths

### 3.1 AX Attribute Queries

**Problem:** Individual attribute calls are IPC round-trips

**Existing Batching (Good Pattern in ObservationManager):**
```swift
// ObservationManager.swift Lines 310-328
private nonisolated func fetchWindowAttributes(_ element: AXUIElement) -> (...) {
    let attributes = [
        kAXTitleAttribute as String,
        kAXMinimizedAttribute as String,
        kAXHiddenAttribute as String,
        kAXMainAttribute as String,
    ]
    guard let values = system.copyAXMultipleAttributes(element: element, attributes: attributes) else { ... }
    // Batch IPC call - reduces 4 round-trips to 1
}
```

**Missing in Traversal:**
```swift
// AccessibilityTraversal.swift - Does NOT batch
func extractElementAttributes(element: AXUIElement) -> (...) {
    // 10+ individual AXUIElementCopyAttributeValue calls
    // Should be: AXUIElementCopyMultipleAttributeValues
}
```

**Recommendation:** Rewrite `extractElementAttributes` to use batched API

**Expected Improvement:** 70-80% reduction in AX IPC calls

---

### 3.2 CGWindowListCopyWindowInfo

**Problem:** Called frequently and enumerates ALL windows

**Current:**
```swift
// WindowRegistry.swift Line 38
let windowList = system.cgWindowListCopyWindowInfo(options: [...], relativeToWindow: ...)
// Returns ALL windows on system
```

**Optimization:** Use window watcher notifications for incremental updates

---

### 3.3 osascript for Text Input

**Problem:** Spawning process per text string is extremely slow

**Current:**
```
writeText("hello"):
  ├─ Spawns osascript process
  ├─ osascript loads AppleScript
  ├─ System Events launched
  └─ keystroke dispatched to AX API
Total: 20-50ms overhead
```

**Alternatives:**
1. Use CGEvent with character-to-keycode mapping
2. Cache osascript process with persistent script injection
3. Use Accessibility API directly with `AXUIElementSetAttributeValue`

**Expected Improvement:** 15-40ms per text operation saved

---

### 3.4 SCStream Lifecycle

**Problem:** Full setup/teardown per screenshot

**Current:**
```
captureScreenshot:
  ├─ SCShareableContent.current (~50ms)
  ├─ Create SCStream (~20ms)
  ├─ addStreamOutput (~5ms)
  ├─ startCapture (~10ms)
  ├─ Wait for 1 frame (~16ms at 60fps)
  ├─ stopCapture (~10ms)
  └─ Stream released
Total: 100-150ms overhead besides image data
```

**Optimization:**
- Create persistent stream for display/screen
- Use continuous capture with frame callback
- Pool streams for common scenarios

**Expected Improvement:** 50-80% reduction for repeated captures

---

### 3.5 Observation Polling with No Changes

**Problem:** Full traversal even when nothing changed

**Current:**
```swift
while !Task.isCancelled {
    let traverseResult = try await handleTraverse(...)  // Always runs
    let changes = detectElementChanges(previous: previousElements, current: currentElements)
    // If changes.count == 0, traversal was wasted
    try await Task.sleep(pollInterval)
}
```

**Optimization:**
- Use AX notification callbacks (kAXMainThreadChanged, kAXFocusedUIElementChanged)
- Only traverse when notifications received
- Fall back to polling if notifications not available

**Expected Improvement:** 90%+ reduction in idle poll cycles

---

## 4. Batching Opportunities

### 4.1 AX Attribute Batching (CRITICAL)

**Status:** ✅ Partially implemented (ObservationManager), ❌ NOT in Traversal

**Impact:** HIGH - reduces IPC round-trips by 75%+

**Implementation Required:**
```swift
// In AccessibilityTraversal.swift
func extractElementAttributes(..., element: AXUIElement) -> (...) {
    let attributes = [
        kAXRoleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXEnabledAttribute,
        kAXFocusedAttribute,
        // ... combine all attributes
    ]
    if let values = AXUIElementCopyMultipleAttributeValues(element, ...) { ... }
}
```

---

### 4.2 Multiple Element Queries

**Status:** ❌ NOT IMPLEMENTED

**Use Case:** Client queries multiple elements by ID

**Implementation Required:**
```swift
// New API: GetElements
func getElements(elementIds: [String]) async throws -> [Element] {
    return elementIds.compactMap { registry.getElement($0) }
    // Would benefit from batch AX queries if registry miss
}
```

---

### 4.3 Input Event Batching

**Status:** ❌ NOT IMPLEMENTED

**Use Case:** Sequential key presses or mouse operations

**Implementation Required:**
```swift
// New API: BatchInput
func executeBatchInput(actions: [InputAction]) async throws {
    let source = try createEventSource()  // Create once
    for action in actions {
        let event = CGEvent(keyboardEventSource: source, ...)
        event.post(tap: .cghidEventTap)
        try await Task.sleep(10_000_000)  // Smaller delay for batch
    }
}
```

---

### 4.4 Screenshot Sequence

**Status:** ❌ NOT IMPLEMENTED

**Use Case:** Recording sequence of screenshots

**Implementation Required:**
```swift
// New API: CaptureScreenshotSequence
func captureScreenshotSequence(count: Int, interval: TimeInterval) async throws -> [Screenshot] {
    // Use single SCStream, capture N frames
    // Avoid repeated stream setup/teardown
}
```

---

## 5. Memory Management

### 5.1 Element Registry

**Status:** ✅ CONTROLLED

**Mechanism:**
```swift
// Lines 29-30: TTL-based expiration
private let cacheExpiration: TimeInterval = 30.0

// Lines 145-164: Background cleanup
private func startCleanupTask() async {
    while true {
        try await Task.sleep(10_000_000_000)
        cleanupExpiredElements()  // Removes expired entries
    }
}
```

**Analysis:**
- Cleanup runs every 10s
- No memory pressure handling
- No size limit (could grow unbounded with many queries)

**Risk:** Under heavy query load, registry could grow to 10k+ elements before cleanup

**Recommendation:** Add hard size limit (e.g., 5000 elements) with LRU eviction

---

### 5.2 Window Registry

**Status:** ✅ CONTROLLED

**Mechanism:**
```swift
// Lines 64-70: TTL-based eviction
windowCache = windowCache.filter { $0.value.timestamp >= staleThreshold }
```

**Analysis:**
- Evicts all stale entries at once
- Could cause memory spike if many windows refreshed simultaneously

**Recommendation:** Stagger eviction or implement LRU

---

### 5.3 Screenshot Memory

**Status:** ⚠️ POTENTIAL LEAK

**Mechanism:**
- Creates new CGImage per screenshot
- CIContext.render() creates new buffers
- No pooling of image buffers

**Risk:** Frequent screenshot RPCs could cause high memory allocation rate

**Recommendation:** Implement image buffer pooling for common resolutions

---

### 5.4 Observation Streams

**Status:** ✅ CONTROLLED

**Mechanism:**
```swift
// Lines 126, 131: Stream buffering
AsyncStream<...>(bufferingPolicy: .bufferingNewest(100))
```

**Analysis:**
- Limited buffer of 100 events
- Backpressure handling via buffering
- Prevents unbounded stream growth

---

## 6. Synchronous vs Asynchronous Patterns

### 6.1 AX Operations

**Status:** ✅ ASYNC SAFE

**Pattern:**
```swift
// AutomationCoordinator.swift Lines 71-83
public func handleTraverse(...) async throws -> ... {
    let sdkResponse = try await Task.detached(priority: .userInitiated) {
        try MacosUseSDK.traverseAccessibilityTree(...)  // Runs on background thread
    }.value
}
```

**Analysis:**
- AX APIs are thread-safe (CFTypeRef based)
- Server correctly offloads to background threads
- No blocking of main actor

**Status:** GOOD ✅

---

### 6.2 CGEvent Posting

**Status:** ✅ ASYNC

**Pattern:**
```swift
// InputController.swift
public func clickMouse(at point: CGPoint) async throws {
    let event = CGEvent(...)
    event.post(tap: .cghidEventTap)  // Synchronous post
    try await Task.sleep(15_000_000)  // Async delay
}
```

**Analysis:**
- `event.post()` is synchronous but fast (<1ms)
- Delay is async, allows other tasks to run

**Status:** GOOD ✅

---

### 6.3 Screenshot Capture

**Status:** ⚠️ MIXED

**Pattern:**
```swift
// ScreenshotCapture.swift Lines 98-115
return try await withCheckedThrowingContinuation { continuation in
    stream.startCapture { ... }  // Async callback
}
```

**Analysis:**
- Uses async continuation pattern correctly
- Image encoding happens synchronously
- OCR happens synchronously if enabled

**Risk:** Large screenshots + OCR could block thread

**Recommendation:** Offload encoding and OCR to background thread

---

### 6.4 os Text Input

**Status:** ⚠️ BLOCKING

**Pattern:**
```swift
// InputController.swift Lines 175-210
public func writeText(_ text: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
        // Process.run() spawns process synchronously
        // But waits asynchronously on terminationHandler
    }
}
```

**Analysis:**
- Continuation makes it async-safe
- But underlying Process spawning is slow

**Status:** Acceptable given async wrapper

---

## 7. Performance Monitoring

### 7.1 Current State

**Status:** ❌ NO PERFORMANCE MONITORING IMPLEMENTED

**What Exists:**
- Basic logging via `Logger` with privacy annotations
- Logging of step completion durations in AccessibilityTraversal
- NO metrics collection
- NO performance timelines
- NO telemetry

**Existing Timing Example:**
```swift
// AccessibilityTraversal.swift Lines 278-281
func logStepCompletion(_ stepDescription: String) {
    let endTime = Date()
    let duration = endTime.timeIntervalSince(stepStartTime)
    let durationStr = String(format: "%.3f", duration)
    logger.info("[\(durationStr)s] finished '\(stepDescription)'")
}
```

**Issues:**
- Logging only, not metrics
- No aggregations/percentiles
- No alerting on slow operations
- Not queryable

---

### 7.2 Missing Metrics

**Critical Metrics to Track:**

1. **Traversal Metrics**
   - Duration by PID
   - Element count by duration bucket
   - Success/failure rate
   - AX error counts by type

2. **Observation Metrics**
   - Poll frequency
   - Change detection rate (changes detected / polls)
   - Poll latency percentiles (p50, p95, p99)
   - Active observation count

3. **Window Registry Metrics**
   - Cache hit/miss rate
   - Refresh frequency
   - Cache size distribution

4. **Input Metrics**
   - Event type distribution (click/type/key)
   - Input latency
   - osascript failure rate

5. **Screenshot Metrics**
   - Capture duration by type (screen/window/region)
   - Image encoding duration
   - OCR duration if enabled
   - SCStream setup/teardown duration

---

### 7.3 Recommended Implementation

```swift
// New: PerformanceMetrics.swift
public actor PerformanceMetrics {
    private var traversalTimings: [TimeInterval] = []
    private var observationStats = [String: ObservationStats]()
    // ... other metrics

    public func recordTraversal(duration: TimeInterval, pid: pid_t, elementCount: Int) {
        traversalTimings.append(duration)
        logger.info("[METRICS] traversal: pid=\(pid), duration=\(duration)s, elements=\(elementCount)")
    }

    public func getTraversalPercentiles() -> (p50: TimeInterval, p95: TimeInterval, p99: TimeInterval) {
        let sorted = traversalTimings.sorted()
        let count = sorted.count
        return (
            p50: sorted[count / 2],
            p95: sorted[Int(Double(count) * 0.95)],
            p99: sorted[Int(Double(count) * 0.99)]
        )
    }
}
```

---

## 8. Hot Spots Identified

### 8.1 Top Performance Bottlenecks

| Rank | Component | Hot Path | Estimated Latency | Impact |
|------|-----------|-----------|-------------------|---------|
| 1 | AX Tree Traversal | `traverseAccessibilityTree` | 100-500ms | CRITICAL - affects observations, find, traverse |
| 2 | Full Window Refresh | `WindowRegistry.refreshWindows` | 10-50ms | HIGH - affects all window operations |
| 3 | Screenshot Capture | `captureScreen/captureWindow` | 200-500ms | HIGH - affects screenshot APIs |
| 4 | osasript Text Input | `writeText` via Process | 20-50ms overhead | MED - affects text entry |
| 5 | Element Lookups | `WindowMethods.getWindow` AX queries | 50-100ms per call | MED - affects GetWindow |
| 6 | Observation Polling | `monitorObservation` loop | N/A (CPU intensive) | HIGH - can AX server overload |

---

### 8.2 Per-RPC Latency Breakdown

**TraverseAccessibility RPC:**
```
Total: 150-600ms
├─ AX App Element Creation: ~5ms
├─ Full Tree Traversal: 100-500ms
│  ├─ AX attribute IPC calls: 80-400ms (primary cost)
│  ├─ Element filtering: 10-20ms
│  └─ Sorting by position: 5-10ms
└─ Protobuf encoding: 5-10ms
```

**ListWindows RPC:**
```
Total: 10-80ms (registry-only path optimized)
├─ Window Registry Refresh: 10-50ms (may skip if cache fresh)
├─ Registry query: 1-5ms
├─ Pagination: <1ms
└─ Protobuf encoding: 1-5ms
Note: OLD implementation was 200-1000ms due to per-window AX queries
```

**Click RPC:**
```
Total: 20-40ms
├─ Element lookup (if by selector): 50-200ms (first call only)
├─ Input execution: 15-20ms
│  ├─ CGEvent creation: <1ms
│  ├─ Post delay: 15ms
│  └─ Event posting: <1ms
└─ Protobuf encoding: <1ms
```

**WriteText RPC:**
```
Total: 30-70ms
├─ osascript spawn: 20-40ms
├─ AppleScript execution: 5-20ms
└─ Protobuf encoding: <1ms
```

**CaptureScreenshot RPC:**
```
Total: 250-600ms
├─ SCShareableContent.current: 50ms
├─ SCStream setup: 30-50ms
├─ Frame capture: 16-33ms (1-2 frames)
├─ Stream teardown: 10-20ms
├─ Image encoding: 50-200ms (scale varies)
├─ OCR (if enabled): 50-100ms
└─ Protobuf encoding: 5-10ms
```

---

## 9. Recommendations for Performance Optimization

### 9.1 Critical Improvements (Implement First)

#### 1. Batch AX Attribute Queries
**Priority:** CRITICAL
**Expected Impact:** 70-80% reduction in traversal latency
**Effort:** 2-3 days

```swift
// Rewrite AccessibilityTraversal.extractElementAttributes to use:
AXUIElementCopyMultipleAttributeValues(element, <attributes array>, ...)
```

---

#### 2. Implement Traversal Result Cache
**Priority:** CRITICAL
**Expected Impact:** 90%+ reduction for repeated traversals
**Effort:** 3-5 days

```swift
// New: TraversalCache actor
actor TraversalCache {
    private var cache: [String: TraversalResult] = [:]
    private let TTL: TimeInterval = 2.0

    func get(pid: pid_t, visibleOnly: Bool) -> TraversalResult? { ... }
    func put(pid: pid_t, visibleOnly: Bool, result: TraversalResult) { ... }
}
```

---

#### 3. Increase Window Registry TTL
**Priority:** HIGH
**Expected Impact:** 80% reduction in unnecessary refreshes
**Effort:** 1 hour

```swift
// WindowRegistry.swift
private let cacheTTL: TimeInterval = 5.0  // Was 1.0
```

---

#### 4. Replace osascript with Direct Key Mapping
**Priority:** HIGH
**Expected Impact:** 20-40ms faster per text operation
**Effort:** 5-7 days

```swift
// Use character-to-keycode mapping tables
// Implement support for Unicode beyond ASCII
// Consider keeping osascript as fallback
```

---

### 9.2 High-Value Improvements

#### 5. Implement Persistent SCStream Pool
**Priority:** HIGH
**Expected Impact:** 50-80% reduction in screenshot overhead
**Effort:** 5-7 days

---

#### 6. Add AX Notification Callbacks for Observations
**Priority:** HIGH
**Expected Impact:** 90%+ reduction in idle poll cycles
**Effort:** 7-10 days

---

#### 7. Implement Window Registry Watcher
**Priority:** MEDIUM
**Expected Impact:** 70% reduction in refresh overhead
**Effort:** 5-7 days

---

#### 8. Add CGEventSource Pooling
**Priority:** LOW-MEDIUM
**Expected Impact:** 1-2ms per input operation
**Effort:** 1 day

---

### 9.3 Monitoring and Observability

#### 9. Implement Performance Metrics Collection
**Priority:** HIGH
**Expected Impact:** Better production visibility
**Effort:** 3-5 days

```swift
// Add metrics to:
- Traversal durations
- AX IPC counts
- Cache hit rates
- RPC latency distributions
```

---

#### 10. Add Endpoint for Metrics Query
**Priority:** MEDIUM
**Expected Impact:** Debuggability
**Effort:** 2-3 days

```swift
// New RPC: GetPerformanceMetrics
rpc GetPerformanceMetrics(GetPerformanceMetricsRequest) returns (PerformanceMetricsResponse)
```

---

### 9.4 Memory Optimization

#### 11. Add Cache Size Limits with LRU
**Priority:** MEDIUM
**Expected Impact:** Prevents unbounded memory growth
**Effort:** 2-3 days

---

#### 12. Implement Image Buffer Pooling
**Priority:** LOW
**Expected Impact:** Reduced GC pressure
**Effort:** 2-3 days

---

### 9.5 Concurrency Improvements

#### 13. Parallelize Independent AX Queries
**Priority:** LOW-MEDIUM
**Expected Impact:** 10-20% speedup for multi-window queries
**Effort:** 3-4 days

```swift
// For ListWindows with GetWindowState-style queries:
// Query each window's state in parallel using Task.detached
```

---

#### 14. Implement Read-Write Lock for Registry
**Priority:** LOW
**Expected Impact:** Better concurrency under high read load
**Effort:** 2-3 days

```swift
// Replace actor with reader-writer pattern
// Allow concurrent reads, serialize writes
```

---

## 10. Testing Recommendations

### 10.1 Performance Testing Framework

**Required Test Scenarios:**

1. **Traversal Performance Tests**
   - Varying element counts (100, 1000, 10000 elements)
   - Varying tree depths (shallow vs deep)
   - Role distribution impact
   - visibleOnly flag performance

2. **Observation Polling Tests**
   - Multiple observations on same process
   - Change detection accuracy vs latency
   - CPU usage under various poll intervals
   - AX server impact under load

3. **Window Registry Tests**
   - Cache hit/miss rate patterns
   - Refresh frequency vs data freshness
   - Multi-process window queries

4. **Input Performance**
   - Sequential vs batched input latency
   - Text input throughput (chars/second)
   - Event scheduling accuracy

5. **Screenshot Performance**
   - Display/region capture latency
   - Encoding time by format
   - OCR latency by text density
   - Memory usage pattern

---

### 10.2 Load Testing Scenarios

**Recommended Load Test:**

```swift
// Simulate 50 clients simultaneously
for client in 1...50 {
    Task {
        // Mix of operations:
        // - 40% traverseAccessibility
        // - 20% listWindows
        // - 20% clickElement
        // - 10% findElements
        // - 10% watchAccessibility (polling)
    }
}
```

**Metrics to Capture:**
- P50, P95, P99 latency by RPC type
- CPU usage (overall and per-process)
- Memory usage over time
- AX server latency
- Error rates under load

---

## 11. Summary

### Immediate Wins (1 week effort)

1. ✅ Batch AX attributes in traversal - **70-80% faster traversals**
2. ✅ Increase window cache TTL to 5s - **80% fewer refreshes**
3. ✅ Add CGEventSource pooling - **1-2ms per input**

### High-Value Improvements (2-3 weeks)

4. ✅ Implement traversal result cache - **90%+ cache hit for common queries**
5. ✅ Replace osascript with key mapping - **20-40ms per text operation**
6. ✅ Implement SCStream pooling - **50-80% faster screenshots**

### Strategic Improvements (1-2 months)

7. ✅ AX notification callbacks - **Eliminate idle polling**
8. ✅ Performance metrics system - **Production visibility**
9. ✅ Window watcher - **Incremental updates only**

### Expected Overall Impact

After implementing critical and high-value improvements:

| Operation | Current Latency | Expected | Improvement |
|------------|-----------------|------------|--------------|
| Traversal | 100-500ms | 20-100ms | **70-80%** |
| Observation Poll (idle) | 100-500ms | 0ms (no traversal) | **95-100%** |
| ListWindows | 10-80ms | 5-10ms | **80-90%** |
| WriteText | 30-70ms | 5-20ms | **70-85%** |
| Screenshot | 250-600ms | 50-150ms | **70-80%** |

**System-wide:** Under moderate load (10 active clients), expected CPU reduction of 40-60% and memory reduction of 30-50%.

---

## Appendix A: Code References

### Performance-Critical Files

1. `Sources/MacosUseSDK/AccessibilityTraversal.swift`
   - Lines 175-568: Main traversal logic
   - Lines 256-285: Attribute extraction (NO batch IPC)

2. `Server/Sources/MacosUseServer/WindowRegistry.swift`
   - Lines 35-73: Window registry cache with 1s TTL

3. `Server/Sources/MacosUseServer/ObservationManager.swift`
   - Lines 162-298: Observation polling loop

4. `Server/Sources/MacosUseServer/ScreenshotCapture.swift`
   - Lines 98-115: SCStream lifecycle

5. `Sources/MacosUseSDK/InputController.swift`
   - Lines 175-210: osascript-based text input

### Example of Good Batching Pattern

`Server/Sources/MacosUseServer/ObservationManager.swift` Lines 310-328 demonstrates correct use of `copyAXMultipleAttributes`.

### Monitoring Gaps

NO files found for:
- Metrics collection
- Performance tracing
- Latency tracking
- Cache hit/miss counting
- Alerting thresholds

---

**Report Prepared By:** Takumi (Performance Investigation)
**Date:** 2025-01-31
**Version:** 1.0
