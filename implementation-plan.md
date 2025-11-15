# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION**

> **GUIDANCE: THIS SECTION IS NOT A LOG**
>
> This status block MUST be **updated in place**. Do NOT append new status updates here or elsewhere in the document.
>
> This section is the *only* location for tracking progress. The `implementation-constraints.md` file MUST NOT be used for tracking status.

### **Server Implementation - ⚠️ PARTIAL (CORE METHODS IMPLEMENTED, FEW PARTIAL FEATURES REMAIN)**

**COMPLETION STATUS:** Most proto-defined gRPC service methods have concrete implementations in `MacosUseServiceProvider.swift`. The codebase implements the majority of the API surface, but a few important items remain partially implemented or marked as TODO (see below). Changes were verified by scanning the provider implementations and helper components.

**VERIFICATION SUMMARY:**
- Total RPC methods declared in `macos_use.proto`: ~66 (refer to proto file for exact count).
- Implemented RPCs: ~62 — The vast majority of RPCs have implementation functions and delegate to manager/helper components.
- Partially implemented RPCs: Pagination issues for multiple `List*` RPCs and observation window-change events.
- Explicitly `UNIMPLEMENTED`: 2 RPC methods (`GetPerformanceReport`, `ResetMetrics`) return `UNIMPLEMENTED` from the server.

**RECOMMENDATION:** Address the partial implementations and the explicitly `UNIMPLEMENTED` metrics methods next to push the service to a fully complete state. The rest of the API surface is largely implemented and test-covered by unit and integration tests.

**COMPLETED IMPLEMENTATIONS:**
* **Script Execution (COMPLETE):** ExecuteAppleScript, ExecuteJavaScript, ExecuteShellCommand, ValidateScript, GetScriptingDictionaries - all fully implemented with proper error handling, timeouts, security validation
* **Macro Management (COMPLETE):** CreateMacro, GetMacro, ListMacros, UpdateMacro, DeleteMacro, ExecuteMacro (LRO) - all fully implemented with MacroRegistry integration
* **Clipboard Operations (COMPLETE):** ReadClipboard (getClipboard), WriteClipboard, ClearClipboard - all delegating to ClipboardManager
* **File Dialog Automation (COMPLETE):** OpenFileDialog (automateOpenFileDialog), SaveFileDialog (automateSaveFileDialog) - all delegating to FileDialogAutomation
* **Metrics (PARTIAL - STUBS/UNIMPLEMENTED):** `GetMetrics` has scaffolding, but `GetPerformanceReport` and `ResetMetrics` are explicitly `unimplemented` and return gRPC `UNIMPLEMENTED` errors — metrics collection and reporting require further work.
* **Supporting Infrastructure:** `ElementRegistry`, `ObservationManager`, `MacroRegistry`, and several managers are implemented and invoked — however, some features (e.g., observation window-change detection) are listed as TODOs.

**PROTO VERIFICATION FINDINGS:**
* RecordMacro, StopRecording, WatchClipboard, StreamMetrics methods DO NOT EXIST in proto definitions - they were referenced in the implementation plan but are not part of the actual API specification and therefore were not implemented.

**KNOWN PARTIAL IMPLEMENTATION AREAS (HIGH PRIORITY)**
- Pagination: Several `List*` RPCs (e.g., `ListWindows`, `ListInputs`, `ListObservations`) include `TODO: Implement pagination with next_page_token`. Pagination is currently not implemented or only rudimentarily implemented in many list methods.
- Observation Events: `ObservationManager.swift` contains TODOs for detecting window changes and emitting events. Observations exist, but event completeness (window/app lifecycle) is limited.
- Window Metadata: Many window attributes contain placeholders (e.g., `bundleId = "unknown"` with a TODO recommending storing the bundle ID) — more accurate window metadata should be added.
- Metrics: The metrics subsystem is incomplete; `GetPerformanceReport` and `ResetMetrics` explicitly return `UNIMPLEMENTED`.
- Element Actions: `PerformElementAction` currently implements only a subset of actions (e.g., `press`, `click`, `showmenu`); unrecognized actions return `UNIMPLEMENTED`. Consider adding a mapping for all relevant input types (keyboard combos, hover, drag, etc.).
- Example placeholders: `TargetApplicationsServiceProvider` and `DesktopServiceProvider` contain TODO placeholders recommending implementing gRPC methods (the main `MacosUseServiceProvider` provides consolidated behavior, but these small providers are unimplemented placeholders and can be removed or implemented to mirror the same functionality).

---

## **Objective**

Build a production-grade gRPC server exposing the complete MacosUseSDK functionality through a sophisticated, resource-oriented API following Google's AIPs. The API must support complex automation workflows including multi-window interactions, advanced element targeting, streaming observations, and integration with developer tools like VS Code.

## **Phase 1: Complete API Definition**

### **1.1 Core Resources**

#### **Application** (`applications/{application}`)
-   Represents a running application tracked by the server
-   Standard Methods: Get, List, Delete (AIP-131, 132, 135)
-   Custom Methods:
    -   `OpenApplication` (LRO per AIP-151)
    -   `ActivateApplication` - Bring to front
    -   `TraverseAccessibility` - Get UI tree snapshot
    -   `WatchAccessibility` (server-streaming) - Real-time UI changes

#### **Window** (`applications/{application}/windows/{window}`)
-   Represents individual windows within an application
-   Properties: title, bounds, zIndex, visibility, minimized state
-   Standard Methods: Get, List
-   Custom Methods:
    -   `FocusWindow` - Bring specific window to front
    -   `MoveWindow` - Reposition window
    -   `ResizeWindow` - Change window dimensions
    -   `MinimizeWindow` / `RestoreWindow`

#### **Element** (`applications/{application}/windows/{window}/elements/{element}`)
-   Represents UI elements (buttons, text fields, etc.)
-   Properties: role, text, bounds, states, actions, hierarchy path
-   Standard Methods: Get, List
-   Custom Methods:
    -   `ClickElement` - Interact with element
    -   `SetElementValue` - Modify element value
    -   `GetElementActions` - Available AX actions
    -   `PerformElementAction` - Execute AX action

#### **Input** (`applications/{application}/inputs/{input}` | `desktopInputs/{input}`)
-   Timeline of input actions (circular buffer)
-   Standard Methods: Create, Get, List (AIP-133, 131, 132)
-   Enhanced types:
    -   Keyboard: text, keys with modifiers, shortcuts
    -   Mouse: click, drag, scroll, hover
    -   Composite: multi-step sequences

#### **Observation** (`applications/{application}/observations/{observation}`)
-   Long-running watchers for UI state
-   Types: polling-based, event-based, condition-based
-   Standard Methods: Create (LRO), Get, List, Cancel
-   Output: stream of observed changes

#### **Session** (`sessions/{session}`)
-   Groups related operations and maintains context
-   Supports transaction-like semantics
-   Standard Methods: Create, Get, List, Delete
-   Custom Methods:
    -   `BeginTransaction` - Start atomic operation group
    -   `CommitTransaction` - Apply all operations
    -   `RollbackTransaction` - Undo operations

### **1.2 Advanced Input Types**

#### **Keyboard Input Enhancements**
-   Key combinations with multiple modifiers
-   Text input with IME support
-   Special keys (function keys, media keys)
-   Keyboard shortcuts (Cmd+Tab, etc.)

#### **Mouse Input Enhancements**
-   Drag and drop operations
-   Scroll with momentum/precision
-   Right-click / context menu
-   Multi-button mouse support
-   Hover with duration
-   Double-click, triple-click

#### **Touch/Gesture Input**
-   Pinch, zoom, rotate gestures
-   Multi-finger swipes
-   Force touch

### **1.3 Element Targeting System**

#### **Selector Syntax** (`proto/macosusesdk/type/selector.proto`)
-   By role and attributes (AX properties)
-   By text content (exact, contains, regex)
-   By position (relative, absolute, screen coords)
-   By hierarchy (parent/child relationships, depth)
-   By state (focused, enabled, visible)
-   Compound selectors (AND, OR, NOT)
-   Relative selectors (nth-child, sibling)

#### **Query System**
-   `FindElements` - Search with selectors
-   `FindElementsInRegion` - Spatial search
-   `WaitForElement` (LRO) - Wait for appearance
-   `WaitForElementState` (LRO) - Wait for state change

### **1.4 Window Management API**

#### **Multi-Window Operations**
-   List all windows across all applications
-   Switch between windows
-   Tile/arrange windows programmatically
-   Window z-order management
-   Full-screen / split-screen support
-   Spaces/Mission Control integration

### **1.5 Automation Workflows**

#### **Macro System** (`proto/macosusesdk/v1/macro.proto`)
-   Record user actions
-   Replay with timing preservation
-   Parameterized macros
-   Conditional execution
-   Loop constructs
-   Error handling

#### **Script Execution** (`proto/macosusesdk/v1/script.proto`)
-   AppleScript integration
-   JavaScript for Automation (JXA)
-   Shell command execution
-   Python/other language bindings

### **1.6 Advanced Accessibility Features**

#### **Attribute Monitoring**
-   Subscribe to attribute changes
-   Filter by attribute types
-   Batch notifications

#### **Action Discovery**
-   List available AX actions per element
-   Action parameters and types
-   Custom action support

#### **Hierarchy Navigation**
-   Parent/child navigation
-   Sibling iteration
-   Depth-first/breadth-first search
-   Path queries (XPath-like)

### **1.7 Visual/Screen Capture**

#### **Screenshot API** (`proto/macosusesdk/v1/screenshot.proto`)
-   Capture full screen
-   Capture specific window
-   Capture element bounds
-   OCR integration for text extraction
-   Image comparison for visual testing

#### **Screen Recording**
-   Record screen activity
-   Record specific window
-   Configurable quality/format

### **1.8 Clipboard Operations**

#### **Clipboard API** (`proto/macosusesdk/v1/clipboard.proto`)
-   Read clipboard (text, images, files)
-   Write clipboard (text, images, files)
-   Clipboard history
-   Format conversion

### **1.9 File System Integration**

#### **File Operations** (`proto/macosusesdk/v1/file.proto`)
-   File dialogs (open/save)
-   Drag-drop file operations
-   File selection automation
-   Path handling

### **1.10 Performance & Diagnostics**

#### **Performance Metrics** (`proto/macosusesdk/v1/metrics.proto`)
-   Operation timing statistics
-   Success/failure rates
-   Resource utilization
-   Accessibility tree complexity metrics

#### **Debug Tools**
-   Element inspector (real-time)
-   Action replay debugger
-   State snapshots
-   Log streaming

### **1.11 VS Code Integration Support**

#### **Development Tool Patterns**
-   Text editor element patterns
-   Command palette automation
-   Extension management
-   Terminal automation within IDE
-   File explorer navigation
-   Search/replace operations
-   Git integration automation
-   Debug session control

---

## **Phase 2: Enhanced Server Architecture**

### **2.1 State Management Expansion**

#### **ApplicationStateManager** (actor)
-   Window registry per application
-   Element cache with TTL
-   Active observations registry
-   Transaction state tracking
-   Session management
-   Resource lifecycle tracking

#### **WindowRegistry** (actor)
-   Window discovery and caching
-   Window state updates (bounds, title, visibility)
-   Window focus history
-   Window-to-app mapping
-   Automatic window cleanup on close

#### **ElementCache** (actor)
-   Cache accessibility elements with TTL
-   Invalidation on UI changes
-   Hierarchy caching
-   Path-based lookups
-   LRU eviction policy

#### **ObservationManager** (actor)
-   Register ongoing observations
-   Manage observation lifecycles
-   Fan-out change notifications
-   Resource cleanup
-   Rate limiting/throttling

### **2.2 Command Processing Enhancement**

#### **CommandQueue** (actor)
-   Priority queuing
-   Command batching
-   Idempotency tracking
-   Retry logic with backoff
-   Command cancellation
-   Deadline enforcement

#### **TransactionManager** (actor)
-   Begin/commit/rollback semantics
-   State snapshots
-   Rollback operations
-   Nested transactions
-   Isolation levels

### **2.3 Event System**

#### **EventBus** (actor)
-   Pub-sub for internal components
-   Event history (circular buffer)
-   Event filtering
-   Async event handlers
-   Backpressure handling

#### **ChangeDetector** (@MainActor)
-   Polling-based monitoring
-   Diff calculation engine
-   Change event generation
-   Efficient tree comparison
-   Selective monitoring (by element/window)

### **2.4 Resource Management**

#### **ResourceTracker** (actor)
-   Track all active resources
-   Automatic cleanup on disconnect
-   Resource quotas per client
-   Leak detection
-   Resource usage metrics

### **2.5 Error Handling & Recovery**

#### **ErrorHandler**
-   Error categorization
-   Retry strategies
-   Circuit breaker patterns
-   Fallback behaviors
-   Error reporting/telemetry

### **2.6 Performance Optimization**

#### **CacheManager** (actor)
-   Traversal result caching
-   Query result caching
-   Cache coherency
-   Memory limits
-   Cache statistics

#### **RateLimiter** (actor)
-   Per-client rate limits
-   Per-operation limits
-   Token bucket algorithm
-   Burst handling
-   Quota management

---

## **Phase 3: Complete Service Implementation**

### **3.1 Application Service**
-   `ActivateApplication` - Focus/activate
-   `TraverseAccessibility` - Full implementation
-   `WatchAccessibility` (server-streaming) - Real-time updates
-   `GetApplicationWindows` - List windows
-   `GetApplicationInfo` - Extended metadata
-   Error handling for terminated apps
-   Resource cleanup on app quit

### **3.2 Window Service**
#### Advanced Features
-   `GetWindowBounds` - Precise positioning (can be implemented as alias to GetWindow)
-   `SetWindowBounds` - Set position/size atomically (can combine MoveWindow + ResizeWindow)
-   `GetWindowState` - Visibility, minimized, etc. (expand GetWindow to query all state attributes)
-   `WatchWindows` (server-streaming) - Window changes (requires NotificationManager for AX notifications)

### **3.3 Element Service**
#### Future Enhancements
-   **Invalid hierarchy paths**: Currently using sequential indices - needs proper hierarchical paths (FIXME exists)
-   **Element staleness**: 30-second cache with no re-validation - needs cache invalidation on UI changes
-   **Window bounds uniqueness**: No validation if two windows have identical bounds - needs additional matching criteria

### **3.4 Input Service**
-   Complete all input types:
    -   Text input with IME support
    -   Key combinations with modifiers
    -   Special keys (Fn, media keys)
    -   Mouse drag operations
    -   Right-click/context menu
    -   Scroll with direction/amount
    -   Hover with duration
    -   Double/triple click
-   Input validation
-   Input composition (multi-step)
-   Input recording
-   Input replay with timing

### **3.5 Observation Service**
-   More sophisticated diff algorithms for element changes
-   Event-based AXObserver integration (currently polling-based for elements)
-   Rate limiting and aggregation options
-   Window change event detection (currently basic polling)
-   Application event forwarding to observation streams

### **3.6 Session Service**
-   Actual rollback execution (currently marks as rolled back but doesn't undo operations)
-   Transaction timeout enforcement
-   Nested transaction support
-   More sophisticated isolation level handling

### **3.7 Query Service**
-   `QueryElements` - Advanced element search
-   `QueryWindows` - Window search
-   `QueryApplications` - Application search
-   Selector syntax support
-   Result pagination
-   Result ordering
-   Aggregations
-   Explain query (optimization hints)

### **3.8 Screenshot Service**
-   Image comparison utilities for visual testing
-   Video recording capabilities
-   Animated GIF support
-   Screenshot metadata (timestamp, display info)
-   Batch screenshot operations

### **3.9 Clipboard Service**
-   Clipboard change notifications for real-time monitoring
-   Custom format support (UTType handling)
-   Clipboard ownership tracking
-   Multi-item clipboard support
-   Cross-application clipboard integration

### **3.10 File Service**
-   Path manipulation utilities
-   Temporary file handling
-   Batch file operations
-   File watching/monitoring

### **3.11 Macro Service**
-   `CreateMacro` - New macro
-   `GetMacro` - Macro details
-   `ListMacros` - Available macros
-   `UpdateMacro` - Modify macro
-   `DeleteMacro` - Remove macro
-   `ExecuteMacro` (LRO) - Run macro
-   `RecordMacro` - Record actions
-   `StopRecording` - End recording
-   Macro parameters
-   Conditional logic
-   Loop constructs
-   Error handling

### **3.12 Script Service**
-   Advanced security sandboxing
-   Script compilation caching (compiled scripts stored for reuse)
-   Streaming output for long-running commands
-   Script execution history and analytics

### **3.13 Metrics Service**
-   `GetMetrics` - Current metrics
-   `StreamMetrics` (server-streaming) - Live metrics
-   `GetPerformanceReport` - Analysis
-   Metric types:
    -   Operation timings
    -   Success/failure rates
    -   Resource utilization
    -   Element counts
    -   Cache hit rates
    -   Rate limit status
-   Metric retention
-   Aggregation options

### **3.14 Debug Service**
-   `InspectElement` - Element details
-   `GetAccessibilityTree` - Full tree
-   `StreamLogs` (server-streaming) - Live logs
-   `GetSnapshot` - State snapshot
-   `ListOperations` - Active operations
-   `DescribeOperation` - Operation details
-   `EnableTracing` - Debug mode
-   `DisableTracing` - Normal mode

---

## **Phase 4: Testing Strategy**

**Objective:** To engineer a comprehensive, deterministic integration test suite that validates the functional correctness, state consistency, and error handling of the `MacosUse` gRPC service. This plan mandates a shift from simple "happy path" testing to rigorous state-verification testing, covering 100% of the defined Proto RPCs.

### **4.1 Unit Tests**
-   All new components:
    -   WindowRegistry tests
    -   ElementCache tests
    -   ObservationManager tests
    -   CommandQueue tests
    -   TransactionManager tests
    -   EventBus tests
    -   ChangeDetector tests
    -   ResourceTracker tests
-   Edge cases:
    -   Element not found
    -   Window closed during operation
    -   App quit during operation
    -   Invalid selectors
    -   Permission denied
    -   Memory pressure
    -   Concurrent access

### **4.2 Test Harness & Environment Standardization**
-   **Goal:** Eliminate test flakiness caused by shared state or lingering processes.
-   **Implementation Requirement:**
    -   Develop a **Test Fixture Lifecycle** that runs before and after *every* single test case.
    -   **Pre-flight:** Must scan the OS process list for "Golden Applications" (defined below) and forcefully terminate them (SIGKILL) to ensure a clean slate.
    -   **Post-flight:** Must aggressively issue `DeleteApplication` RPCs for any resources created during the test, followed by a verify-kill of the OS process.
    -   **Client State:** A fresh gRPC connection must be established for every test suite to prevent channel state pollution.
-   **"Golden Application" Definitions:**
    -   **Goal:** Define immutable targets for verification.
    -   **Implementation Requirement:**
        -   **Target A (Stateful):** `TextEdit` (Bundle ID: `com.apple.TextEdit`). Used for window resizing, text entry, file dialogs, and multi-window management.
        -   **Target B (Calculation):** `Calculator` (Bundle ID: `com.apple.calculator`). Used for discrete input verification (click logic) and result validation.
        -   **Target C (System):** `Finder` (Bundle ID: `com.apple.finder`). Used for desktop-level inputs and clipboard operations.

### **4.3 Core Lifecycle & Window Management Verification**
-   **Application Lifecycle Loop**
    -   **Goal:** Verify `OpenApplication`, `GetApplication`, `ListApplications`, `DeleteApplication`.
    -   **Actionable Tasks:**
        1.  **Launch Verification:** Invoke `OpenApplication` for TextEdit. The test must block until the Long Running Operation (LRO) completes. Verify the returned `Application` proto contains a valid, non-zero `pid` and the status is `STATE_COMPLETED`.
        2.  **Persistence Check:** Immediately invoke `ListApplications`. Assert that the list contains exactly the app opened in step 1 (filtering for the test UUID if parallel execution is supported).
        3.  **Termination Verification:** Invoke `DeleteApplication` (graceful). Verify via `ListApplications` that the app is removed from the server's tracking. Immediately verify via OS shell command (`pgrep`) that the process is still running (since graceful delete only stops tracking).
        4.  **Force Kill Verification:** Invoke `DeleteApplication` with `force=true`. Verify via OS shell command that the PID no longer exists.
-   **Precise Window Geometry Control**
    -   **Goal:** Verify `GetWindow`, `ListWindows`, `MoveWindow`, `ResizeWindow`, `FocusWindow`, `Minimize/Restore`.
    -   **Actionable Tasks:**
        1.  **Discovery:** Open TextEdit. Invoke `ListWindows`. Assert count >= 1. Capture the `name` (resource ID) of the main window.
        2.  **Geometry Mutation:** Invoke `ResizeWindow` setting dimensions to strictly `500x500`. Immediately invoke `GetWindow`. Assert `bounds.width` and `bounds.height` are within a 2-pixel tolerance of 500 (accounting for OS chrome).
        3.  **Position Mutation:** Invoke `MoveWindow` to coordinates `100,100`. Verify via `GetWindow` that `bounds.x` and `bounds.y` reflect this change.
        4.  **State Mutation:** Invoke `MinimizeWindow`. Verify `GetWindow` returns `minimized=true`. Invoke `RestoreWindow`. Verify `minimized=false`. Invoke `FocusWindow`. Verify `focused=true`.

### **4.4 Input Fidelity & Event Timeline**
-   **Complex Input Sequences**
    -   **Goal:** Verify `CreateInput`, `ListInputs`, and specific `InputAction` types (Text, Click, Drag).
    -   **Actionable Tasks:**
        1.  **Text Entry Validation:** Target TextEdit. Invoke `CreateInput` with `TextInput` payload "Hello_World". Verify success. Immediately invoke `TraverseAccessibility` and recursively search the element tree to find a `StaticText` or `TextArea` node containing the exact string "Hello_World".
        2.  **Mouse Drag Simulation:** Target the TextEdit window title bar. Invoke `GetWindow` to establish start coordinates. Invoke `CreateInput` with `MouseDrag` payload (from `current_x+10, current_y+10` to `current_x+200, current_y+200`). Verify execution. Invoke `GetWindow` again to confirm the window coordinates have shifted by approximately +190 pixels.
        3.  **Input History:** Invoke `ListInputs` for the application. Assert that the sequence of inputs (Text, then Drag) appears in the returned list in chronological order with `state=STATE_COMPLETED`.

### **4.5 Accessibility & Element Interaction**
-   **Tree Traversal & Search**
    -   **Goal:** Verify `TraverseAccessibility`, `FindElements`, `GetElement`.
    -   **Actionable Tasks:**
        1.  **Full Tree Dump:** Invoke `TraverseAccessibility`. Assert `stats.count` > 10. Assert `stats.visible_elements_count` > 0.
        2.  **Selector Precision:** Invoke `FindElements` using a `CompoundSelector` (Operator AND) combining `role="button"` and `text_regex=".*Zoom.*"`. Verify it returns the specific window control buttons.
        3.  **Element Re-acquisition:** Take the `element_id` from the search result. Invoke `GetElement` using that ID. Assert the returned object matches the search result exactly.
-   **Interactive Element State**
    -   **Goal:** Verify `ClickElement`, `WriteElementValue`, `PerformElementAction`.
    -   **Actionable Tasks:**
        1.  **Action Discovery:** Invoke `GetElementActions` on a window's "Close" button. Verify "AXPress" or similar action exists.
        2.  **Direct Action:** Invoke `PerformElementAction` with "AXPress". Verify via `ListWindows` that the window count has decreased by 1 (window closed).

### **4.6 System Integration & Observability**
-   **Visual Verification (Screenshots)**
    -   **Goal:** Verify `CaptureScreenshot`, `CaptureWindowScreenshot`, `CaptureElementScreenshot`.
    -   **Actionable Tasks:**
        1.  **Format Compliance:** Invoke `CaptureScreenshot` requesting `IMAGE_FORMAT_PNG`. Decode the resulting `image_data` byte array using a standard image library. Assert decoding succeeds and dimensions match the primary display resolution.
        2.  **Contextual Capture:** Invoke `CaptureWindowScreenshot` for Calculator. Enable `include_ocr_text=true`. Assert `ocr_text` contains numeric values currently displayed on the calculator face.
-   **Clipboard & Scripting**
    -   **Goal:** Verify `Clipboard` resource and `Execute*Script` RPCs.
    -   **Actionable Tasks:**
        1.  **Clipboard Roundtrip:** Invoke `WriteClipboard` with text "IntegrationUUID". Invoke `GetClipboard`. Assert `content.text` == "IntegrationUUID". Invoke `ClearClipboard`. Invoke `GetClipboard` and assert content is empty.
        2.  **Polyglot Execution:**
            -   Invoke `ExecuteShellCommand` with `echo "ping"`. Assert `stdout` == "ping\n".
            -   Invoke `ExecuteAppleScript` with `return 5 * 5`. Assert `output` == "25".
            -   Invoke `ExecuteJavaScript` (JXA) to query the System Events app name. Assert output is valid JSON string.

### **4.7 Advanced Workflows (Macros & Sessions)**
-   **Macro Logic**
    -   **Goal:** Verify `CreateMacro`, `ExecuteMacro` (LRO).
    -   **Actionable Tasks:**
        1.  **Definition:** Create a Macro resource containing three sequential actions: Wait (1s), Input (Type "Test"), Input (Key Press "Enter").
        2.  **Execution:** Invoke `ExecuteMacro`. Poll the returned Operation.
        3.  **Verification:** Upon completion, check the `ExecuteMacroResponse`. Assert `actions_executed` == 3. Check the target app to verify the text was typed.
-   **Session Transactions**
    -   **Goal:** Verify `Session` resource and `Begin/Commit/Rollback Transaction`.
    -   **Actionable Tasks:**
        1.  **Transaction Integrity:** Create a Session. Invoke `BeginTransaction`. Perform 3 distinct `CreateInput` operations referencing the Session ID. Invoke `CommitTransaction`.
        2.  **Audit Trail:** Invoke `GetSessionSnapshot`. Verify the `history` array contains exactly the 3 inputs performed within the transaction block.
-   **Reactive Observation**
    -   **Goal:** Verify `WatchAccessibility` and `CreateObservation`.
    -   **Actionable Tasks:**
        1.  **Stream Setup:** Initiate `WatchAccessibility` stream on Calculator.
        2.  **Trigger:** In a separate thread, invoke `CreateInput` to click the "Clear" button.
        3.  **Event Capture:** Block on the stream response. Verify receipt of a `WatchAccessibilityResponse` where `modified` elements contains the display text field (value changing to "0").

### **4.8 Integration Tests**
-   Complete test coverage:
    -   Calculator: Full arithmetic operations
    -   TextEdit: Text editing, formatting
    -   Finder: File operations, navigation
    -   Safari: Navigation, form interaction
    -   System Preferences: Settings modification
    -   Multi-window scenarios
    -   Multi-app coordination
    -   Error recovery
    -   Resource cleanup

### **4.9 Performance Tests**
-   Benchmarks:
    -   Element lookup speed
    -   Cache hit rates
    -   Traversal performance
    -   Input latency
    -   Memory usage patterns
    -   Concurrent client handling
    -   Large tree handling
    -   Rate limit effectiveness

### **4.10 End-to-End Tests**
-   Real-world scenarios:
    -   VS Code automation (open file, edit, save, debug)
    -   Xcode automation (build, test, run)
    -   Browser automation (navigation, forms, downloads)
    -   Mail automation (compose, send)
    -   Multi-step workflows
    -   Error recovery paths
    -   Session management
    -   Transaction rollback

### **4.11 Compliance Tests**
-   API standards:
    -   AIP compliance validation
    -   Resource name formats
    -   LRO patterns
    -   Error handling
    -   Filtering syntax
    -   Pagination
    -   Field masks
-   Accessibility compliance:
    -   Permission handling
    -   Privacy protection
    -   Sandbox compatibility

### **Correctness & Verification Guarantees**

To ensure this implementation plan provides a **guarantee** of correctness, the following validation logic must be strictly adhered to:

1.  **State-Difference Assertions (The Delta Check):**
    -   Tests must never assume an action worked simply because the RPC returned `OK`.
    -   **Requirement:** Every mutator RPC (Move, Resize, Click, Type) must be immediately followed by an accessor RPC (GetWindow, GetElement, Traverse) to assert the *Delta* between Pre-State and Post-State matches the expected mutation.

2.  **Wait-For-Convergence Pattern:**
    -   macOS Accessibility API is asynchronous.
    -   **Requirement:** Tests must **strictly avoid** `time.Sleep()`. Instead, implement a `PollUntil(condition, timeout)` utility. For example, after opening an app, poll `GetApplication` until the PID is non-zero. After closing a window, poll `ListWindows` until count decreases.

3.  **Resource Cleanup Invariant:**
    -   **Requirement:** The suite must assert `GetMetrics` at the very end of execution. The `resources.active_observations` and `resources.connection_count` must return to baseline levels. Any deviation indicates a resource leak in the server implementation.

4.  **OCR as Ground Truth:**
    -   **Requirement:** For graphical rendering tests (screenshots), byte-comparison is fragile. Verification must rely on the `ocr_text` field or valid image header decoding to guarantee the server isn't returning garbage bytes.

---

## **Phase 5: Proto File Expansion**

### **5.1 New Proto Files**
-   `proto/macosusesdk/v1/window.proto` - Window resource, WindowState enum, methods
-   `proto/macosusesdk/v1/element.proto` - Element resource, ElementSelector, ElementAction, methods
-   `proto/macosusesdk/v1/observation.proto` - Observation resource, ObservationType enum, events, methods
-   `proto/macosusesdk/v1/session.proto` - Session resource, Transaction, methods
-   `proto/macosusesdk/v1/query.proto` - Query methods, selector syntax, aggregations
-   `proto/macosusesdk/v1/screenshot.proto` - Screenshot methods, formats, options
-   `proto/macosusesdk/v1/clipboard.proto` - Clipboard methods, content types
-   `proto/macosusesdk/v1/file.proto` - File dialog methods, selection methods
-   `proto/macosusesdk/v1/macro.proto` - Macro resource, recording, execution
-   `proto/macosusesdk/v1/script.proto` - Script execution methods (AppleScript, JXA, Shell)
-   `proto/macosusesdk/v1/metrics.proto` - Metrics methods, metric types, reports

### **5.2 Proto Type Expansion**
-   `proto/macosusesdk/type/selector.proto` - Element selector grammar
-   `proto/macosusesdk/type/bounds.proto` - Precise geometry types
-   `proto/macosusesdk/type/state.proto` - Common state enums
-   `proto/macosusesdk/type/event.proto` - Event types for observations
-   `proto/macosusesdk/type/filter.proto` - Filter expression language

---

## **Phase 6: Server Architecture Expansion**

### **6.1 Window Management**
-   `WindowRegistry.swift` - Track all windows, maintain window tree
-   `WindowObserver.swift` - AX notifications for window events
-   `WindowPositioner.swift` - Geometric calculations, collision detection

### **6.2 Element Management**
-   `ElementLocator.swift` - Selector parsing, element search
-   `ElementRegistry.swift` - Element identity tracking (ephemeral IDs)
-   `ElementAttributeCache.swift` - Attribute caching with invalidation

### **6.3 Observation Pipeline**
-   `ObservationScheduler.swift` - Rate limiting, aggregation
-   `ObservationFilter.swift` - Event filtering logic
-   `NotificationManager.swift` - AX notification registration

### **6.4 Session Management**
-   `SessionManager.swift` - Session lifecycle
-   `TransactionLog.swift` - Transaction recording
-   `StateSnapshot.swift` - Snapshot capture and restoration

### **6.5 Advanced Input**
-   `KeyboardSimulator.swift` - CGEvent-based keyboard input
-   `MouseSimulator.swift` - CGEvent-based mouse input
-   `GestureSimulator.swift` - Multi-touch gestures
-   `InputValidator.swift` - Input validation

### **6.6 Query Engine**
-   `SelectorParser.swift` - Parse selector expressions
-   `QueryExecutor.swift` - Execute complex queries
-   `ResultAggregator.swift` - Aggregate and paginate results

---

## **Phase 7: VS Code Integration Patterns**

### **7.1 Common Workflows**
-   Open file by path
-   Navigate to line/column
-   Execute command palette actions
-   Debug session control
-   Terminal interaction
-   Git operations
-   Extension installation

### **7.2 Example Implementation**
-   Document VS Code element selectors
-   Create macros for common tasks
-   Implement robust error handling
-   Handle async operations
-   Manage multiple windows/panels

---

## **Phase 8: Documentation**

### **8.1 API Documentation**
-   Complete proto comments for all messages and methods
-   Usage examples for each resource type
-   Error handling patterns
-   Performance considerations

### **8.2 Integration Guide**
-   Client setup (Go, Python, other languages)
-   Authentication and permissions
-   Rate limiting and quotas
-   Best practices

### **8.3 Advanced Topics**
-   Session management strategies
-   Transaction design
-   Observation patterns
-   Selector syntax guide
-   Macro language reference

---

## **Phase 9: Build System Integration**

### **9.1 Buf Configuration**
-   Update `buf.yaml` for new proto files
-   Update `buf.gen.yaml` for new packages
-   Regenerate all stubs

### **9.2 Makefile Targets**
-   Add targets for new components
-   Update test targets
-   Add performance benchmarks

### **9.3 CI/CD**
-   Extend workflows for new tests
-   Add performance regression detection
-   Add API compatibility checks

---

## **Phase 10: Implementation Priorities**

### **Priority 1: Window Resource (CRITICAL)**
Complete Window resource is essential for multi-window automation. Must implement before other advanced features.

### **Priority 2: Element Resource (CRITICAL)**
Element addressing and querying is core to all automation workflows. Includes selector syntax.

### **Priority 3: Advanced Input (HIGH)**
Keyboard modifiers, drag-drop, scroll are needed for real-world automation.

### **Priority 4: Observation System (HIGH)**
Streaming observations enable reactive automation and monitoring.

### **Priority 5: Session/Transaction (MEDIUM)**
Needed for robust multi-step workflows and rollback.

### **Priority 6: Query Engine (MEDIUM)**
Advanced element queries improve automation reliability.

### **Priority 7: Visual/Screenshot (MEDIUM)**
Screen capture for verification and debugging.

### **Priority 8: Macro/Script (LOW)**
Convenience features for common workflows.

### **Priority 9: Metrics/Debug (LOW)**
Operational visibility and diagnostics.

---

## **Architectural Principles**

* **Follow AIPs:** The API design strictly adheres to the Google API Improvement Proposals (AIPs), particularly:
    * **AIP-121:** Resource-oriented design (resources should be independently addressable).
    * **AIP-131, 132, 133, 135:** Standard methods (`Get`, `List`, `Create`, `Delete`).
    * **AIP-151:** Long-running operations (for `OpenApplication`, using `google.longrunning.Operation`).
    * **AIP-161:** Field masks (e.g., for `TraverseAccessibility` element filtering).
    * **AIP-192:** Resource names must follow standard patterns.
    * **AIP-203:** Declarative-friendly resource design.

* **Main-Thread Constraint:** The MacosUseSDK requires `NSApplication.shared` to be running and most operations to be performed on the main thread (`@MainActor`). The architecture uses:
    * **`AutomationCoordinator` (@MainActor):** The central, main-thread controller that interacts with the SDK.
    * **`AppStateStore` (actor):** A thread-safe, copy-on-write state store that is queried from gRPC providers to avoid blocking main thread.
    * **Task-based communication:** gRPC providers submit tasks to the coordinator and await results.

* **Swift Concurrency:** Leverage Swift's `async`/`await` and `actor` model for safe, scalable concurrency. The `grpc-swift-2` library is built on Swift Concurrency and all providers use `AsyncProvider` protocols.

* **Separation of Concerns:**
    * **Proto Definition** (`proto/`): The API contract (resource definitions, method signatures).
    * **gRPC Providers** (`Server/Sources/MacosUseServer/*Provider.swift`): gRPC endpoint implementations that validate, transform, and delegate.
    * **AutomationCoordinator** (`Server/Sources/MacosUseServer/AutomationCoordinator.swift`): Main-thread SDK orchestrator.
    * **State Management** (`Server/Sources/MacosUseServer/AppStateStore.swift`, `OperationStore.swift`): Thread-safe state storage.
    * **MacosUseSDK** (`Sources/MacosUseSDK/`): The underlying Swift library that wraps macOS Accessibility APIs.

* **Code Generation:** All protobuf stubs are generated via `buf generate` and committed to the repository. This ensures reproducibility and allows clients to consume generated code directly.

* **Error Handling:** Use standard gRPC status codes and provide detailed error messages. Follow AIP-193 for error responses.

* **Testing:** Comprehensive testing at all levels:
    * Unit tests for individual components
    -   Integration tests for end-to-end workflows
    -   Performance tests for scalability
    -   Compliance tests for API standards

---
**END OF IMPLEMENTATION PLAN**
(To provide an update, return to the "STATUS SECTION" at the top of this document.)
