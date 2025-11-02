# Implementation Plan: MacosUseSDK gRPC Service

---
## **Objective**

Build a production-grade gRPC server exposing the complete MacosUseSDK functionality through a sophisticated, resource-oriented API following Google's AIPs. The API must support complex automation workflows including multi-window interactions, advanced element targeting, streaming observations, and integration with developer tools like VS Code.

## **Phase 1: Complete API Definition**

### **1.1 Core Resources**

#### **Application** (`applications/{application}`)
- Represents a running application tracked by the server
- Standard Methods: Get, List, Delete (AIP-131, 132, 135)
- Custom Methods:
  - `OpenApplication` (LRO per AIP-151)
  - `ActivateApplication` - Bring to front
  - `TraverseAccessibility` - Get UI tree snapshot
  - `WatchAccessibility` (server-streaming) - Real-time UI changes
  
#### **Window** (`applications/{application}/windows/{window}`)
- **MISSING**: Window as first-class resource
- Represents individual windows within an application
- Properties: title, bounds, zIndex, visibility, minimized state
- Standard Methods: Get, List
- Custom Methods:
  - `FocusWindow` - Bring specific window to front
  - `MoveWindow` - Reposition window
  - `ResizeWindow` - Change window dimensions
  - `MinimizeWindow` / `RestoreWindow`
  
#### **Element** (`applications/{application}/windows/{window}/elements/{element}`)
- **MISSING**: Element as addressable resource
- Represents UI elements (buttons, text fields, etc.)
- Properties: role, text, bounds, states, actions, hierarchy path
- Standard Methods: Get, List
- Custom Methods:
  - `ClickElement` - Interact with element
  - `SetElementValue` - Modify element value
  - `GetElementActions` - Available AX actions
  - `PerformElementAction` - Execute AX action

#### **Input** (`applications/{application}/inputs/{input}` | `desktopInputs/{input}`)
- Timeline of input actions (circular buffer)
- Standard Methods: Create, Get, List (AIP-133, 131, 132)
- Enhanced types:
  - Keyboard: text, keys with modifiers, shortcuts
  - Mouse: click, drag, scroll, hover
  - Composite: multi-step sequences

#### **Observation** (`applications/{application}/observations/{observation}`)
- **MISSING**: Persistent observation/monitoring
- Long-running watchers for UI state
- Types: polling-based, event-based, condition-based
- Standard Methods: Create (LRO), Get, List, Cancel
- Output: stream of observed changes

#### **Session** (`sessions/{session}`)
- **MISSING**: Session management for complex workflows
- Groups related operations and maintains context
- Supports transaction-like semantics
- Standard Methods: Create, Get, List, Delete
- Custom Methods:
  - `BeginTransaction` - Start atomic operation group
  - `CommitTransaction` - Apply all operations
  - `RollbackTransaction` - Undo operations

### **1.2 Advanced Input Types**

#### **Keyboard Input Enhancements**
- **MISSING**: Comprehensive keyboard API
- Key combinations with multiple modifiers
- Text input with IME support
- Special keys (function keys, media keys)
- Keyboard shortcuts (Cmd+Tab, etc.)

#### **Mouse Input Enhancements**
- **MISSING**: Advanced mouse operations
- Drag and drop operations
- Scroll with momentum/precision
- Right-click / context menu
- Multi-button mouse support
- Hover with duration
- Double-click, triple-click

#### **Touch/Gesture Input**
- **MISSING**: Trackpad gesture support
- Pinch, zoom, rotate gestures
- Multi-finger swipes
- Force touch

### **1.3 Element Targeting System**

#### **Selector Syntax** (`proto/macosusesdk/type/selector.proto`)
- **MISSING**: Rich element selection
- By role and attributes (AX properties)
- By text content (exact, contains, regex)
- By position (relative, absolute, screen coords)
- By hierarchy (parent/child relationships, depth)
- By state (focused, enabled, visible)
- Compound selectors (AND, OR, NOT)
- Relative selectors (nth-child, sibling)

#### **Query System**
- **MISSING**: Element query API
- `FindElements` - Search with selectors
- `FindElementsInRegion` - Spatial search
- `WaitForElement` (LRO) - Wait for appearance
- `WaitForElementState` (LRO) - Wait for state change

### **1.4 Window Management API**

#### **Multi-Window Operations**
- **MISSING**: Sophisticated window control
- List all windows across all applications
- Switch between windows
- Tile/arrange windows programmatically
- Window z-order management
- Full-screen / split-screen support
- Spaces/Mission Control integration

### **1.5 Automation Workflows**

#### **Macro System** (`proto/macosusesdk/v1/macro.proto`)
- **MISSING**: Recordable/replayable sequences
- Record user actions
- Replay with timing preservation
- Parameterized macros
- Conditional execution
- Loop constructs
- Error handling

#### **Script Execution** (`proto/macosusesdk/v1/script.proto`)
- **MISSING**: Higher-level scripting
- AppleScript integration
- JavaScript for Automation (JXA)
- Shell command execution
- Python/other language bindings

### **1.6 Advanced Accessibility Features**

#### **Attribute Monitoring**
- **MISSING**: Fine-grained AX monitoring
- Subscribe to attribute changes
- Filter by attribute types
- Batch notifications

#### **Action Discovery**
- **MISSING**: Dynamic action enumeration
- List available AX actions per element
- Action parameters and types
- Custom action support

#### **Hierarchy Navigation**
- **MISSING**: Tree traversal utilities
- Parent/child navigation
- Sibling iteration
- Depth-first/breadth-first search
- Path queries (XPath-like)

### **1.7 Visual/Screen Capture**

#### **Screenshot API** (`proto/macosusesdk/v1/screenshot.proto`)
- **MISSING**: Screen capture capabilities
- Capture full screen
- Capture specific window
- Capture element bounds
- OCR integration for text extraction
- Image comparison for visual testing

#### **Screen Recording**
- **MISSING**: Video capture
- Record screen activity
- Record specific window
- Configurable quality/format

### **1.8 Clipboard Operations**

#### **Clipboard API** (`proto/macosusesdk/v1/clipboard.proto`)
- **MISSING**: Clipboard manipulation
- Read clipboard (text, images, files)
- Write clipboard (text, images, files)
- Clipboard history
- Format conversion

### **1.9 File System Integration**

#### **File Operations** (`proto/macosusesdk/v1/file.proto`)
- **MISSING**: File interaction automation
- File dialogs (open/save)
- Drag-drop file operations
- File selection automation
- Path handling

### **1.10 Performance & Diagnostics**

#### **Performance Metrics** (`proto/macosusesdk/v1/metrics.proto`)
- **MISSING**: Observability
- Operation timing statistics
- Success/failure rates
- Resource utilization
- Accessibility tree complexity metrics

#### **Debug Tools**
- **MISSING**: Development aids
- Element inspector (real-time)
- Action replay debugger
- State snapshots
- Log streaming

### **1.11 VS Code Integration Support**

#### **Development Tool Patterns**
- Text editor element patterns
- Command palette automation
- Extension management
- Terminal automation within IDE
- File explorer navigation
- Search/replace operations
- Git integration automation
- Debug session control

---

## **Phase 2: Enhanced Server Architecture**

### **2.1 State Management Expansion**

#### **ApplicationStateManager** (actor)
- Current: Basic PID tracking
- **NEEDED**:
  - Window registry per application
  - Element cache with TTL
  - Active observations registry
  - Transaction state tracking
  - Session management
  - Resource lifecycle tracking

#### **WindowRegistry** (actor)
- **MISSING**: Window tracking system
- Window discovery and caching
- Window state updates (bounds, title, visibility)
- Window focus history
- Window-to-app mapping
- Automatic window cleanup on close

#### **ElementCache** (actor)
- **MISSING**: Element caching layer
- Cache accessibility elements with TTL
- Invalidation on UI changes
- Hierarchy caching
- Path-based lookups
- LRU eviction policy

#### **ObservationManager** (actor)
- **MISSING**: Active observation tracking
- Register ongoing observations
- Manage observation lifecycles
- Fan-out change notifications
- Resource cleanup
- Rate limiting/throttling

### **2.2 Command Processing Enhancement**

#### **CommandQueue** (actor)
- **MISSING**: Sophisticated command queuing
- Priority queuing
- Command batching
- Idempotency tracking
- Retry logic with backoff
- Command cancellation
- Deadline enforcement

#### **TransactionManager** (actor)
- **MISSING**: Transaction support
- Begin/commit/rollback semantics
- State snapshots
- Rollback operations
- Nested transactions
- Isolation levels

### **2.3 Event System**

#### **EventBus** (actor)
- **MISSING**: Internal event distribution
- Pub-sub for internal components
- Event history (circular buffer)
- Event filtering
- Async event handlers
- Backpressure handling

#### **ChangeDetector** (@MainActor)
- **MISSING**: UI change detection
- Polling-based monitoring
- Diff calculation engine
- Change event generation
- Efficient tree comparison
- Selective monitoring (by element/window)

### **2.4 Resource Management**

#### **ResourceTracker** (actor)
- **MISSING**: Resource lifecycle
- Track all active resources
- Automatic cleanup on disconnect
- Resource quotas per client
- Leak detection
- Resource usage metrics

### **2.5 Error Handling & Recovery**

#### **ErrorHandler**
- **MISSING**: Comprehensive error handling
- Error categorization
- Retry strategies
- Circuit breaker patterns
- Fallback behaviors
- Error reporting/telemetry

### **2.6 Performance Optimization**

#### **CacheManager** (actor)
- **MISSING**: Multi-level caching
- Traversal result caching
- Query result caching
- Cache coherency
- Memory limits
- Cache statistics

#### **RateLimiter** (actor)
- **MISSING**: Rate limiting
- Per-client rate limits
- Per-operation limits
- Token bucket algorithm
- Burst handling
- Quota management

---

## **Phase 3: Complete Service Implementation**

### **3.1 Application Service** (PARTIALLY COMPLETE)
#### Current:
- Basic OpenApplication (LRO)
- Get/List/Delete

#### **NEEDED**:
- `ActivateApplication` - Focus/activate
- `TraverseAccessibility` - Full implementation
- `WatchAccessibility` (server-streaming) - Real-time updates
- `GetApplicationWindows` - List windows
- `GetApplicationInfo` - Extended metadata
- Error handling for terminated apps
- Resource cleanup on app quit

### **3.2 Window Service** (IMPLEMENTED - 8/8 core methods)
#### ✅ **COMPLETED**:
- ✅ `GetWindow` - Parses resource name, uses WindowRegistry to fetch window info, returns Window proto with bounds/title/layer/visibility
- ✅ `ListWindows` - Lists all windows for given application PID using WindowRegistry
- ✅ `FocusWindow` - Uses AXUIElementSetAttributeValue with kAXMainAttribute to focus window
- ✅ `MoveWindow` - Uses AXValueCreate(.cgPoint) and AXUIElementSetAttributeValue with kAXPositionAttribute
- ✅ `ResizeWindow` - Uses AXValueCreate(.cgSize) and AXUIElementSetAttributeValue with kAXSizeAttribute
- ✅ `MinimizeWindow` - Sets kAXMinimizedAttribute to true
- ✅ `RestoreWindow` - Sets kAXMinimizedAttribute to false
- ✅ `CloseWindow` - Gets close button via kAXCloseButtonAttribute, performs kAXPressAction

#### ✅ **ENHANCED**:
- ✅ Proper windowId matching using CGWindowList bounds comparison with AXUIElement bounds
- ✅ Complete state query: minimized, focused attributes from AXUIElement (fullscreen detection not available in macOS Accessibility API)
- ✅ Window state returned in GetWindow with actual AX attribute values

#### **NEEDED** - Advanced features:
- `GetWindowBounds` - Precise positioning (can be implemented as alias to GetWindow)
- `SetWindowBounds` - Set position/size atomically (can combine MoveWindow + ResizeWindow)
- `GetWindowState` - Visibility, minimized, etc. (expand GetWindow to query all state attributes)
- `WatchWindows` (server-streaming) - Window changes (requires NotificationManager for AX notifications)

### **3.3 Element Service** (IMPLEMENTED WITH CRITICAL FIXES APPLIED)
#### ✅ **COMPLETED** (with critical fixes):
- ✅ `FindElements` - Selector-based element search with ElementLocator
- ✅ `FindRegionElements` - Spatial element search in regions  
- ✅ `GetElement` - Element details by resource name (FIXED: now queries registry)
- ✅ `ClickElement` - Click elements by ID or selector
- ✅ `WriteElementValue` - Set element text values
- ✅ `PerformElementAction` - Execute element actions (FIXED: returns errors for unimplemented actions)
- ✅ `GetElementActions` - Available actions (FIXED: queries AXUIElement first, falls back to role-based)
- ✅ `WaitElement` (LRO) - Wait for element appearance
- ✅ `WaitElementState` (LRO) - Wait for element state changes (FIXED: uses stable selector re-running)

#### ❌ **REMAINING CRITICAL ISSUES** (non-functional due to AXUIElement loss):
- **AXUIElement lifecycle broken**: Elements registered with `axElement: nil` - all element actions use stale cached coordinates
- **Invalid hierarchy paths**: Sequential indices instead of proper hierarchical paths
- **No element re-validation**: Cached elements trusted without checking if UI changed

### **3.4 Input Service** (PARTIALLY COMPLETE)
#### Current:
- Basic CreateInput
- Get/List inputs

#### **NEEDED**:
- Complete all input types:
  - Text input with IME support
  - Key combinations with modifiers
  - Special keys (Fn, media keys)
  - Mouse drag operations
  - Right-click/context menu
  - Scroll with direction/amount
  - Hover with duration
  - Double/triple click
- Input validation
- Input composition (multi-step)
- Input recording
- Input replay with timing

### **3.5 Observation Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `CreateObservation` (LRO) - Start watching
- `GetObservation` - Observation status
- `ListObservations` - Active observations
- `CancelObservation` - Stop watching
- `StreamObservations` (server-streaming) - Observation events
- Observation types:
  - ElementChanged
  - WindowChanged
  - ApplicationChanged
  - AttributeChanged
  - TreeChanged
- Filtering options
- Rate limiting
- Aggregation options

### **3.6 Session Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `CreateSession` - New session
- `GetSession` - Session details
- `ListSessions` - Active sessions
- `DeleteSession` - End session
- `BeginTransaction` - Start atomic operations
- `CommitTransaction` - Apply operations
- `RollbackTransaction` - Undo operations
- `GetSessionState` - Current state snapshot
- Session timeout handling
- Session cleanup

### **3.7 Query Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `QueryElements` - Advanced element search
- `QueryWindows` - Window search
- `QueryApplications` - Application search
- Selector syntax support
- Result pagination
- Result ordering
- Aggregations
- Explain query (optimization hints)

### **3.8 Screenshot Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `CaptureScreen` - Full screen
- `CaptureWindow` - Specific window
- `CaptureElement` - Element bounds
- `CaptureRegion` - Arbitrary rectangle
- Format options (PNG, JPEG, TIFF)
- Quality settings
- OCR integration
- Image comparison

### **3.9 Clipboard Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `GetClipboard` - Read clipboard
- `SetClipboard` - Write clipboard
- `ClearClipboard` - Clear
- Type support:
  - Plain text
  - Rich text (RTF, HTML)
  - Images
  - Files (paths)
  - Custom formats
- Clipboard history
- Format enumeration

### **3.10 File Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `AutomateOpenDialog` - Open file dialog
- `AutomateSaveDialog` - Save file dialog
- `SelectFile` - File selection
- `SelectDirectory` - Directory selection
- `DragFiles` - Drag-drop simulation
- Path manipulation
- Temporary file handling

### **3.11 Macro Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `CreateMacro` - New macro
- `GetMacro` - Macro details
- `ListMacros` - Available macros
- `UpdateMacro` - Modify macro
- `DeleteMacro` - Remove macro
- `ExecuteMacro` (LRO) - Run macro
- `RecordMacro` - Record actions
- `StopRecording` - End recording
- Macro parameters
- Conditional logic
- Loop constructs
- Error handling

### **3.12 Script Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `ExecuteAppleScript` - Run AppleScript
- `ExecuteJXA` - Run JavaScript for Automation
- `ExecuteShellCommand` - Run shell command
- Script validation
- Output capture
- Error handling
- Timeout configuration
- Environment variables

### **3.13 Metrics Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `GetMetrics` - Current metrics
- `StreamMetrics` (server-streaming) - Live metrics
- `GetPerformanceReport` - Analysis
- Metric types:
  - Operation timings
  - Success/failure rates
  - Resource utilization
  - Element counts
  - Cache hit rates
  - Rate limit status
- Metric retention
- Aggregation options

### **3.14 Debug Service** (MISSING)
#### **NEEDED** - Complete implementation:
- `InspectElement` - Element details
- `GetAccessibilityTree` - Full tree
- `StreamLogs` (server-streaming) - Live logs
- `GetSnapshot` - State snapshot
- `ListOperations` - Active operations
- `DescribeOperation` - Operation details
- `EnableTracing` - Debug mode
- `DisableTracing` - Normal mode

---

## **Phase 4: Testing Strategy**

### **4.1 Unit Tests** (INCOMPLETE)
#### Current:
- Basic `AppStateStoreTests.swift`
- Basic `ServerConfigTests.swift`

#### **NEEDED**:
- All new components:
  - WindowRegistry tests
  - ElementCache tests
  - ObservationManager tests
  - CommandQueue tests
  - TransactionManager tests
  - EventBus tests
  - ChangeDetector tests
  - ResourceTracker tests
- Edge cases:
  - Element not found
  - Window closed during operation
  - App quit during operation
  - Invalid selectors
  - Permission denied
  - Memory pressure
  - Concurrent access

### **4.2 Integration Tests** (MINIMAL)
#### Current:
- Basic calculator_test.go (opens app)

#### **NEEDED**:
- Complete test coverage:
  - Calculator: Full arithmetic operations
  - TextEdit: Text editing, formatting
  - Finder: File operations, navigation
  - Safari: Navigation, form interaction
  - System Preferences: Settings modification
  - Multi-window scenarios
  - Multi-app coordination
  - Error recovery
  - Resource cleanup

### **4.3 Performance Tests** (MISSING)
#### **NEEDED**:
- Benchmarks:
  - Element lookup speed
  - Cache hit rates
  - Traversal performance
  - Input latency
  - Memory usage patterns
  - Concurrent client handling
  - Large tree handling
  - Rate limit effectiveness

### **4.4 End-to-End Tests** (MISSING)
#### **NEEDED**:
- Real-world scenarios:
  - VS Code automation (open file, edit, save, debug)
  - Xcode automation (build, test, run)
  - Browser automation (navigation, forms, downloads)
  - Mail automation (compose, send)
  - Multi-step workflows
  - Error recovery paths
  - Session management
  - Transaction rollback

### **4.5 Compliance Tests** (MISSING)
#### **NEEDED**:
- API standards:
  - AIP compliance validation
  - Resource name formats
  - LRO patterns
  - Error handling
  - Filtering syntax
  - Pagination
  - Field masks
- Accessibility compliance:
  - Permission handling
  - Privacy protection
  - Sandbox compatibility

---

## **Phase 5: Proto File Expansion**

### **5.1 New Proto Files Needed**
- `proto/macosusesdk/v1/window.proto` - Window resource, WindowState enum, methods
- `proto/macosusesdk/v1/element.proto` - Element resource, ElementSelector, ElementAction, methods
- `proto/macosusesdk/v1/observation.proto` - Observation resource, ObservationType enum, events, methods
- `proto/macosusesdk/v1/session.proto` - Session resource, Transaction, methods
- `proto/macosusesdk/v1/query.proto` - Query methods, selector syntax, aggregations
- `proto/macosusesdk/v1/screenshot.proto` - Screenshot methods, formats, options
- `proto/macosusesdk/v1/clipboard.proto` - Clipboard methods, content types
- `proto/macosusesdk/v1/file.proto` - File dialog methods, selection methods
- `proto/macosusesdk/v1/macro.proto` - Macro resource, recording, execution
- `proto/macosusesdk/v1/script.proto` - Script execution methods (AppleScript, JXA, Shell)
- `proto/macosusesdk/v1/metrics.proto` - Metrics methods, metric types, reports

### **5.2 Proto Type Expansion**
- `proto/macosusesdk/type/selector.proto` - Element selector grammar
- `proto/macosusesdk/type/bounds.proto` - Precise geometry types
- `proto/macosusesdk/type/state.proto` - Common state enums
- `proto/macosusesdk/type/event.proto` - Event types for observations
- `proto/macosusesdk/type/filter.proto` - Filter expression language

---

## **Phase 6: Server Architecture Expansion**

### **6.1 Window Management**
- `WindowRegistry.swift` - Track all windows, maintain window tree
- `WindowObserver.swift` - AX notifications for window events
- `WindowPositioner.swift` - Geometric calculations, collision detection

### **6.2 Element Management**
- `ElementLocator.swift` - Selector parsing, element search
- `ElementRegistry.swift` - Element identity tracking (ephemeral IDs)
- `ElementAttributeCache.swift` - Attribute caching with invalidation

### **6.3 Observation Pipeline**
- `ObservationScheduler.swift` - Rate limiting, aggregation
- `ObservationFilter.swift` - Event filtering logic
- `NotificationManager.swift` - AX notification registration

### **6.4 Session Management**
- `SessionManager.swift` - Session lifecycle
- `TransactionLog.swift` - Transaction recording
- `StateSnapshot.swift` - Snapshot capture and restoration

### **6.5 Advanced Input**
- `KeyboardSimulator.swift` - CGEvent-based keyboard input
- `MouseSimulator.swift` - CGEvent-based mouse input
- `GestureSimulator.swift` - Multi-touch gestures
- `InputValidator.swift` - Input validation

### **6.6 Query Engine**
- `SelectorParser.swift` - Parse selector expressions
- `QueryExecutor.swift` - Execute complex queries
- `ResultAggregator.swift` - Aggregate and paginate results

---

## **Phase 7: VS Code Integration Patterns**

### **7.1 Common Workflows**
- Open file by path
- Navigate to line/column
- Execute command palette actions
- Debug session control
- Terminal interaction
- Git operations
- Extension installation

### **7.2 Example Implementation**
- Document VS Code element selectors
- Create macros for common tasks
- Implement robust error handling
- Handle async operations
- Manage multiple windows/panels

---

## **Phase 8: Documentation**

### **8.1 API Documentation**
- Complete proto comments for all messages and methods
- Usage examples for each resource type
- Error handling patterns
- Performance considerations

### **8.2 Integration Guide**
- Client setup (Go, Python, other languages)
- Authentication and permissions
- Rate limiting and quotas
- Best practices

### **8.3 Advanced Topics**
- Session management strategies
- Transaction design
- Observation patterns
- Selector syntax guide
- Macro language reference

---

## **Phase 9: Build System Integration**

### **9.1 Buf Configuration** (NEEDS UPDATE)
- Update `buf.yaml` for new proto files
- Update `buf.gen.yaml` for new packages
- Regenerate all stubs

### **9.2 Makefile Targets** (NEEDS UPDATE)
- Add targets for new components
- Update test targets
- Add performance benchmarks

### **9.3 CI/CD** (NEEDS UPDATE)
- Extend workflows for new tests
- Add performance regression detection
- Add API compatibility checks

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

### **Current Status Summary**

### **What Works Today**
- ✅ gRPC server infrastructure
- ✅ Basic Application resource (Open, Get, List, Delete)
- ✅ Basic Input resource (Create, Get, List)
- ✅ **Complete Window resource (Get, List, Focus, Move, Resize, Minimize, Restore, Close - 8/8 methods)**
- ✅ TraverseAccessibility (read-only)
- ✅ LRO pattern (OpenApplication with correct proto type URLs)
- ✅ Integration test suite (Calculator automation tests pass)
- ✅ Text input via AppleScript
- ✅ Server startup and connection handling
- ✅ Proper LRO response marshaling
- ✅ **COMPLETE PROTO DEFINITION LAYER (50+ methods defined)**
- ✅ **All proto files created and compiling**
- ✅ **Advanced InputAction types (MouseClick, TextInput, KeyPress, MouseMove, MouseDrag, Scroll, Hover, Gesture)**
- ✅ **Server stubs for all 50+ methods**
- ✅ **AutomationCoordinator updated for new proto structure**
- ✅ **WindowRegistry actor (thread-safe window tracking with CGWindowListCopyWindowInfo)**
- ✅ **All tests passing (9 total: 2 SDK, 7 Server)**
- ✅ **ApplicationServices import for AXUIElement APIs**
- ✅ **ZERO API linter violations achieved (23+ violations fixed)**

### **CRITICAL FLAWS FIXED** 🚨
- ✅ **ElementLocator.getElement**: Now queries ElementRegistry instead of doing broken fresh traversal
- ✅ **Redundant traversal removed**: findElements no longer calls handleTraverse twice
- ✅ **performElementAction**: Now returns `unimplemented` error for unknown actions instead of falsely reporting success
- ✅ **waitElementState**: Fixed unreliable position-based matching; now re-runs selectors for stable element identification  
- ✅ **Documentation**: Corrected fullscreen detection claim (not available in macOS Accessibility API)
- ✅ **getElementActions**: Now attempts to query actual AXUIElement for kAXActionsAttribute before falling back to role-based guesses

### **REMAINING CRITICAL ISSUES** ❌
- **AXUIElement lifecycle**: Elements are registered with `axElement: nil` because SDK doesn't return AXUIElement references - **ALL ELEMENT ACTIONS USE STALE COORDINATES**
- **Invalid hierarchy paths**: `traverseWithPaths` returns sequential indices instead of proper hierarchical paths
- **Window bounds uniqueness**: `findWindowElement` assumes bounds are unique (potential for wrong window selection)
- **Element staleness**: Methods using `elementId` trust cached elements without re-validation

### **What's Missing (Implementation Layer)**
- ✅ Window operations (8/8 core methods implemented with proper windowId matching)
- ✅ Element operations (9 methods - **CRITICAL FIXES APPLIED** but AXUIElement lifecycle broken)
- ❌ Observation streaming (5 methods - stubs exist, need implementation)
- ❌ Session/transaction support (8 methods - stubs exist, need implementation)
- ❌ Screenshot capture (4 methods - stubs exist, need implementation)
- ❌ Clipboard operations (4 methods - stubs exist, need implementation)
- ❌ File dialog automation (5 methods - stubs exist, need implementation)
- ❌ Macro execution (6 methods - stubs exist, need implementation)
- ❌ Script execution (5 methods - stubs exist, need implementation)
- ❌ Metrics collection (3 methods - stubs exist, need implementation)
- ❌ Element targeting/selector system (partially implemented but broken)
- ❌ Multi-window coordination workflows
- ❌ VS Code integration patterns
- ❌ Comprehensive integration tests (only Calculator test exists, need ~20 more tests)

### **Gap Analysis**
The current implementation is approximately **20% complete**. We have:
- ✅ Complete proto definition layer (100%)
- ✅ All RPC method signatures (100%)
- ✅ Basic server infrastructure (100%)
- ✅ Stub implementations (100%)
- ✅ Code generation pipeline (100%)
- ✅ API linter compliance (100% - ZERO violations)
- ⚠️ Business logic implementation (15% - App operations + Input operations + Window operations work, 40+ methods still stubs)
- ⚠️ Testing infrastructure (10% - only 9 tests, need ~50 more)
- ❌ Advanced features (0% - selectors, observations, sessions, macros, scripts, metrics all unimplemented)

### **Proto Definition Phase: COMPLETE**
- ✅ 7 new proto files created (session, screenshot, clipboard, file, macro, script, metrics)
- ✅ Enhanced input.proto with 8 comprehensive InputAction types
- ✅ Updated macos_use.proto with 50+ new RPC methods across 9 categories:
  * Window Operations (8 methods)
  * Element Operations (9 methods)
  * Observation Operations (5 methods)
  * Session Operations (8 methods)
  * Screenshot Operations (4 methods)
  * Clipboard Operations (4 methods)
  * File Operations (5 methods)
  * Macro Operations (6 methods)
  * Script Operations (5 methods)
  * Metrics Operations (3 methods)
- ✅ All proto files compile successfully
- ✅ Stubs regenerated (Go + Swift)
- ✅ Integration test updated for new proto structure
- ✅ Swift server updated for new proto structure
- ✅ All 50+ stub implementations added to MacosUseServiceProvider
- ✅ **API linter compliance: ZERO violations (all 23+ warnings fixed)**
  * Renamed UpdateElementValue → WriteElementValue
  * Renamed UpdateClipboard → WriteClipboard
  * Renamed all request/response messages to match RPC method names:
    - FindElementsInRegion → FindRegionElements (request/response)
    - WaitForElement → WaitElement (request/response/metadata)
    - WaitForElementState → WaitElementState (request/response/metadata)
    - ExecuteJavaScriptForAutomation → ExecuteJavaScript (request/response)
    - SetElementValue → WriteElementValue (request/response)
    - SetClipboard → WriteClipboard (request/response)
  * Fixed comment spacing violations
  * Changed REQUIRED fields to OPTIONAL where appropriate

We are now ready for:
- Incremental implementation of 50+ stub methods
- Expansion of integration tests
- Advanced server components (WindowRegistry, ElementCache, ObservationManager, etc.)

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
    * Integration tests for end-to-end workflows
    * Performance tests for scalability
    * Compliance tests for API standards

---

## **Next Steps (Implementation Roadmap)**

Given the current 15% completion state, the roadmap is:

### **Immediate (Critical Path)**
1. **Window Resource Implementation**
   - Define `proto/macosusesdk/v1/window.proto`
   - Implement WindowRegistry server component
   - Add Window methods to MacosUse service
   - Add integration tests

2. **Element Resource Implementation**
   - Define `proto/macosusesdk/v1/element.proto`
   - Implement ElementLocator and ElementRegistry
   - Add Element methods to MacosUse service
   - Design and implement selector syntax
   - Add integration tests

3. **Advanced Input Types**
   - Extend Input message with all input types
   - Implement KeyboardSimulator and MouseSimulator
   - Add input validation
   - Add integration tests

### **Short-term (High Priority)**
4. **Observation System**
   - Define `proto/macosusesdk/v1/observation.proto`
   - Implement ObservationManager and streaming
   - Add integration tests

5. **Query Engine**
   - Define `proto/macosusesdk/v1/query.proto`
   - Implement SelectorParser and QueryExecutor
   - Add integration tests

### **Medium-term**
6. **Session/Transaction Support**
7. **Visual/Screenshot Capabilities**
8. **Clipboard and File Operations**
9. **Macro System**
10. **Performance Metrics and Debugging**

### **Long-term**
11. **VS Code Integration Patterns and Documentation**
12. **Comprehensive Testing Coverage**
13. **Performance Optimization**
14. **Production Hardening**

