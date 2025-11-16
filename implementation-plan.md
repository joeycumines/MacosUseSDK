**This is `./implementation-plan.md`. KEEP THE PLAN UP TO DATE AS YOU EVOLVE THE CODE. DEVIATIONS TO THE PLAN MUST BE LOGGED WITHIN THE PLAN. THE PLAN MUST BE REASSESSED HOLISTICALLY AFTER ANY CHANGE OF ANY SIZE.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

---

# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION (ACTION-FOCUSED)**

> **GUIDANCE: TRACK ONLY WHAT REMAINS OR MUST NOT BE FORGOTTEN**
>
> This section MUST stay short and focused on *remaining* work, unresolved discrepancies, and critical patterns to follow. Do NOT accumulate historic "done" items, emojis, or log-style updates.
>
> Before trusting any "done" status, you MUST verify it against the actual code and tests. If there is any doubt, treat the item as **not done** and list the verification work here.

### **Current Reality (Single-Sentence Snapshot)**

The gRPC Swift 2 migration is verified complete; `MacosUseServer` builds with zero warnings on macOS 15+, UDS support is restored, and `ScreenCaptureKit` is fully integrated; the focus now shifts strictly to verification, pagination compliance, and integration testing.

### **Immediate Action Items (Next Things To Do)**

1. **Run comprehensive verification:** Execute `make all` to run linting, all unit tests, and integration tests to verify the migration hasn't broken existing functionality.
2. **Fix pagination to use opaque tokens everywhere:** AIP-158 requires `page_token` to be treated as an opaque string by clients. `listInputs` and `listWindows` currently use a readable `"offset:N"` format; keep any internal structure server-side only and update code/comments so tokens are generated and documented as opaque (no client should depend on their structure). Ensure all List/Find RPCs use pagination with opaque tokens.
3. **Paginate all List/Find RPCs consistently:** `ListApplications` and any other list RPCs that currently return unpaginated results must be updated to support `page_size`, `page_token`, and `next_page_token` with deterministic ordering. Remove the notion that it might be acceptable to leave some list RPCs unpaginated in v1 and align Phase 1/3 wording with the "everything paginated" requirement.
4. **Tighten `PerformElementAction` and related tests:** After confirming its actual coverage in `MacosUseServiceProvider.swift`, either extend it to the minimal, well-documented set of additional actions we care about for v1 or clearly constrain and test the limited set it supports today. Reflect this decision and the implemented set in Phase 3.2.
5. **Reconcile observation behavior with tests:** `ObservationManager` implements element and window change detection with polling, but current Go integration tests (`integration/main_test.go` and siblings) still rely on sleeps and basic List-based checks instead of a full PollUntil + delta pattern. Update Phase 4 to call out the concrete missing tests and add explicit tasks to replace sleeps with PollUntil and add delta assertions.
6. **Clarify golden app lifecycle guarantees vs actual harness:** The integration harness kills Calculator/TextEdit up front but does not yet implement per-test `DeleteApplication` RPC cleanup or full session/resource teardown. Reflect this gap in Phase 4.2 and add tasks for a proper fixture lifecycle aligned with the constraints.

### **Standing Guidance For Future Edits To This Section**

- Only track **open work** or **must-not-forget patterns** here.
- When a task is actually complete *and verified in code/tests*, remove it from the Immediate Action Items and, if necessary, adjust the relevant phase section below to reflect the new reality.
- Never add completion emojis, running logs, or historical commentary; this section is a *queue of remaining work*, not a scrapbook.

---

## **Objective**

Build a production-grade gRPC server exposing the complete MacosUseSDK functionality through a sophisticated, resource-oriented API following Google's AIPs. The API must support complex automation workflows including multi-window interactions, advanced element targeting, streaming observations, and integration with developer tools like VS Code.

## **Phase 1: API Definition (Reality-Aligned)**

Phase 1 is no longer about **creating** resources and services; those already exist in `proto/macosusesdk/v1/*.proto` and `proto/macosusesdk/type/*.proto`. The focus is now on **ensuring AIP-compliant semantics**, consistent resource naming, and correctness features like pagination and filtering.

### **1.1 Core Resources (Already Defined)**

For each resource below, the corresponding proto file **exists**. Phase 1 work is to verify and refine:
- Resource names and patterns (AIP-121, AIP-192, AIP-190, AIP-191).
- Method sets and request/response shapes (AIP-131/132/133/135/151).
- Pagination, filtering, and field masks where appropriate.

#### **Application** (`applications/{application}`)
- Represents a running application tracked by the server.
- Proto: `proto/macosusesdk/v1/application.proto`.
- Standard Methods: `GetApplication`, `ListApplications`, `DeleteApplication`.
- Custom Methods:
    - `OpenApplication` (LRO per AIP-151).
    - `TraverseAccessibility` – UI tree snapshot.
    - `WatchAccessibility` (server-streaming) – real-time UI changes.
- **Phase 1 tasks:**
    - Confirm resource name format and patterns follow AIPs.
    - Ensure request/response messages are co-located with the service and documented.
    - Review `ListApplications` for pagination semantics (currently single page only).

#### **Window** (`applications/{application}/windows/{window}`)
- Represents individual windows within an application.
- Proto: `proto/macosusesdk/v1/window.proto`.
- Key properties: title, bounds, zIndex, visibility, minimized state, bundle ID.
- Standard Methods: `GetWindow`, `ListWindows`.
- Custom Methods: `FocusWindow`, `MoveWindow`, `ResizeWindow`, `MinimizeWindow`, `RestoreWindow`, `CloseWindow`.
- **Phase 1 tasks:**
    - Validate window resource name pattern and parent application relationship.
    - Specify and document which fields are guaranteed vs best-effort (e.g. bundle ID, z-index).
    - Design pagination for `ListWindows` (see Phase 3 for implementation details).

#### **Element** (`applications/{application}/windows/{window}/elements/{element}`)
- Represents UI elements (buttons, text fields, etc.).
- Types: `proto/macosusesdk/type/element.proto`, `proto/macosusesdk/type/selector.proto`.
- Properties: role, text, bounds, states, actions, hierarchy path.
- Standard Methods: `GetElement`, `ListElements` (via find APIs).
- Custom Methods: `FindElements`, `FindRegionElements`, `ClickElement`, `WriteElementValue`, `GetElementActions`, `PerformElementAction`, `WaitElement`, `WaitElementState`.
- **Phase 1 tasks:**
    - Ensure selector and element types are documented and align with AIP-213 guidance.
    - Define and document element ID stability and staleness semantics.
    - Specify how pagination and filtering apply to `FindElements` and `FindRegionElements`.

#### **Input** (`applications/{application}/inputs/{input}` | `desktopInputs/{input}`)
- Timeline of input actions associated with an application or the desktop.
- Proto: `proto/macosusesdk/v1/input.proto`.
- Standard Methods: `CreateInput`, `GetInput`, `ListInputs`.
- Enhanced types: keyboard, mouse, composite/multi-step sequences.
- **Phase 1 tasks:**
    - Confirm resource name patterns for application vs desktop inputs.
    - Define retention and circular-buffer behaviour for completed inputs.
    - Specify pagination guarantees for `ListInputs`.

#### **Observation** (`applications/{application}/observations/{observation}`)
- Long-running watchers for UI state.
- Proto: `proto/macosusesdk/v1/observation.proto`.
- Types: polling-based, event-based, condition-based.
- Standard Methods: `CreateObservation` (LRO), `GetObservation`, `ListObservations`, `CancelObservation`.
- Streaming: `StreamObservations`.
- **Phase 1 tasks:**
    - Validate observation types and event shapes vs AIP guidance on streaming.
    - Define semantics for observation lifetimes and cancellation.
    - Plan for pagination on `ListObservations`.

#### **Session** (`sessions/{session}`)
- Groups related operations and maintains context.
- Proto: `proto/macosusesdk/v1/session.proto`.
- Standard Methods: `CreateSession`, `GetSession`, `ListSessions`, `DeleteSession`.
- Custom Methods: `BeginTransaction`, `CommitTransaction`, `RollbackTransaction`, `GetSessionSnapshot`.
- **Phase 1 tasks:**
    - Confirm resource names and parentage (if any) follow AIPs.
    - Clarify semantics for transactions and snapshots in proto comments.
    - Ensure `ListSessions` pagination behaviour is well-documented and testable.

### **1.2 Advanced Input Types (Baseline vs Future Extension)**

The proto and server already support a subset of advanced input types (keyboard and mouse). Phase 1 should distinguish **baseline support** from **future extensions** and make this explicit in proto comments.

#### **Keyboard Input (Baseline)**
- Key combinations with modifiers (Command, Option, Control, Shift).
- Text input.
- Some special keys/shortcuts where supported by the current implementation.

#### **Mouse Input (Baseline)**
- Clicks (including coordinate-based fallback where needed).
- Basic drag operations for window movement.

#### **Future Extensions (Documented but NOT required for initial production)**
- Scroll with momentum/precision.
- Advanced drag-and-drop and hover-duration semantics.
- Multi-button mouse configurations.
- Touch/gesture inputs (pinch, zoom, rotate, multi-finger swipes, force touch).

**Phase 1 tasks:**
- Ensure `input.proto` clearly separates currently supported actions from planned ones.
- Avoid over-promising gestures/multi-touch in comments until designs and platform feasibility are nailed down.

### **1.3 Element Targeting System**

Selector and element types already exist and are in active use.

#### **Selector Syntax** (`proto/macosusesdk/type/selector.proto`)
- By role and attributes (AX properties).
- By text content (exact, contains, possibly regex-like semantics where implemented).
- By position (relative, absolute, screen coordinates).
- By hierarchy (parent/child relationships, depth).
- By state (focused, enabled, visible).
- Compound selectors (AND, OR, NOT) and relative selectors (nth-child, sibling) as supported by `SelectorParser`.

#### **Query System**
- `FindElements` – selector-based search.
- `FindRegionElements` – region-bounded search.
- `WaitElement` (LRO) – wait for appearance.
- `WaitElementState` (LRO) – wait for state change.

**Phase 1 tasks:**
- Document the selector grammar in `selector.proto` and `proto/README.md` with concrete examples.
- Clarify which selector features are implemented today vs reserved for future.
- Align error codes for invalid selectors with AIP-193.

### **1.4 Window Management API**

Multi-window operations are already supported at the resource level; Phase 1 ensures the API surface is clearly documented and AIP-aligned.

#### **Multi-Window Operations**
- List windows for an application and (where appropriate) across applications.
- Focus/switch between windows.
- Move/resize windows using `MoveWindow` and `ResizeWindow`.
- Minimize/restore windows.

**Phase 1 tasks:**
- Document window lifecycle and expected behaviours when a window is closed externally.
- Clearly state any limitations (e.g. no explicit Mission Control/spaces integration in v1).
- Align docs and implementation of `MacosUseServiceProvider.listWindows` with AIP-158: ensure pagination exists, that `page_token` is **explicitly opaque to clients**, and that ordering and default/maximum `page_size` semantics are clearly defined without exposing internal token structure.

### **1.5 Automation Workflows**

#### **Macro System** (`proto/macosusesdk/v1/macro.proto`)
- Macro resources and CRUD/execute RPCs already exist.
- **Phase 1 tasks:**
    - Document macro semantics (idempotency, parameterisation, and error handling) in proto comments.
    - Defer full "record/loop/conditional" language design to later phases, marking them clearly as future enhancements.

#### **Script Execution** (`proto/macosusesdk/v1/script.proto`)
- RPCs for AppleScript, JXA, and shell execution already exist.
- `GetScriptingDictionaries` is implemented but currently uses placeholder bundle IDs.
- **Phase 1 tasks:**
    - Document security considerations and sandbox expectations.
    - Clarify script timeouts and output size limits.
    - Note current limitations around non-Apple scripting languages as future scope.

### **1.6 Advanced Accessibility Features**

These features are partially implemented; Phase 1 should capture what is real today.

#### **Attribute Monitoring**
- `StreamObservations` already exposes change events; polling vs event-based mechanisms vary per type.
- **Phase 1 tasks:**
    - Document which attributes can be observed and how frequently.
    - Clarify rate limits and aggregation behaviour (even if currently basic).

#### **Action Discovery**
- `GetElementActions` exposes available AX actions for elements.
- **Phase 1 tasks:**
    - Ensure action names and descriptions are documented and stable.
    - Document `PerformElementAction` behaviour for unsupported actions (UNIMPLEMENTED).

#### **Hierarchy Navigation**
- Traversal RPCs and selector paths provide limited navigation capabilities.
- **Phase 1 tasks:**
    - Align comments and examples with the actual path encoding used in `ElementRegistry`.

### **1.7 Visual/Screen Capture**

#### **Screenshot API** (`proto/macosusesdk/v1/screenshot.proto`)
- Capture full screen, windows, elements, and regions is implemented.
- OCR text fields exist for some RPCs.
- **Phase 1 tasks:**
    - Document which formats and resolutions are supported.
    - Clarify expected latency and size constraints.

#### **Screen Recording (Future)**
- Screen recording is not yet implemented.
- **Phase 1 tasks:**
    - Treat recording as a future extension and avoid implying current support in API docs.

### **1.8 Clipboard Operations**

#### **Clipboard API** (`proto/macosusesdk/v1/clipboard.proto`)
- Read/write/clear/history RPCs are implemented.
- **Phase 1 tasks:**
    - Specify supported content types and their serialisation.
    - Document error cases (e.g. unsupported formats).

### **1.9 File System Integration**

File dialog automation is implemented via `FileDialogAutomation.swift` and the existing v1 protos (no dedicated `file.proto`).

**Phase 1 tasks:**
- Clarify in docs how file dialogs are modelled (e.g. which RPCs and resources are used).
- Avoid referencing a non-existent `file.proto`; instead, document the actual service methods.

### **1.10 VS Code Integration Support (Use-Case Layer)**

These are high-level **use cases**, not separate API surfaces.

**Phase 1 tasks:**
- Identify which existing RPCs are sufficient to power VS Code/Xcode workflows.
- Document example flows (in docs, not in proto) that show how to build such automations using the existing `MacosUse` service.

---

## **Phase 2: Server Architecture (Grounded in Existing Components)**

Phase 2 focuses on clarifying and strengthening the architecture **as it exists today**, rather than inventing new actors unless needed. The main architectural primitives are:
- `AutomationCoordinator` (@MainActor): central orchestrator for SDK interactions.
- `AppStateStore` (actor): copy-on-write state view for queries.
- `WindowRegistry`, `ElementLocator`, `ElementRegistry`: window and element tracking.
- `ObservationManager`, `SessionManager`, `OperationStore`, `ChangeDetector`: long-running operations and state change tracking.

### **2.1 State Management & Registries**

**Current reality:**
- `AppStateStore` manages high-level state; `WindowRegistry` tracks windows; `ElementRegistry` manages element identities; `ObservationManager` and `SessionManager` track long-lived operations.

**Phase 2 tasks:**
- Tighten state ownership boundaries (which actor owns which slice of state).
- Ensure copy-on-write snapshots used for queries cannot observe partially-applied mutations.
- Document lifecycle and cleanup rules for windows, elements, observations, sessions, and operations.

### **2.2 Command & Transaction Handling**

**Current reality:**
- There is no explicit `CommandQueue` or `TransactionManager` actor; commands are executed via gRPC handlers calling into `AutomationCoordinator` and related actors.
- Sessions implement basic begin/commit/rollback semantics, but rollback is not yet a true undo of side effects.

**Phase 2 tasks:**
- Clearly document the command flow: gRPC → provider → coordinator → SDK/state stores.
- Decide whether a dedicated `CommandQueue` actor is warranted or whether structured use of Swift concurrency is sufficient.
- Define a realistic scope for transactional behaviour (what can and cannot be rolled back) and write it down.

### **2.3 Event & Change Propagation**

**Current reality:**
- `ChangeDetector` and `ObservationManager` handle polling-based detection of changes.
- There is no explicit `EventBus` actor; events are delivered via method calls and callbacks.

**Phase 2 tasks:**
- Formalise the internal event model (what constitutes an event, who publishes, who subscribes).
- Decide whether a light-weight event bus abstraction adds clarity or just complexity.
- Plan the transition path from polling to AXObserver-based event delivery where justified.

### **2.4 Resource Tracking & Cleanup**

**Current reality:**
- Resource lifecycles (observations, sessions, operations, connections) are tracked across several components, but there is no single `ResourceTracker` actor.

**Phase 2 tasks:**
- Define a consolidated resource model (what counts as an active resource, who owns it).
- Implement or designate a component (e.g. `OperationStore`/`ObservationManager`) responsible for enforcing the "Zombie Resource Reaper" invariant.

### **2.5 Error Handling & Recovery**

**Current reality:**
- Error handling is implemented locally in providers and helpers, using gRPC status codes.

**Phase 2 tasks:**
- Establish shared patterns for mapping internal errors to gRPC statuses (AIP-193).
- Identify operations that would benefit from retries or circuit-breaking and capture this in design docs, even if not yet implemented.

### **2.6 Performance, Caching & Rate Limiting**

**Current reality:**
- Some caching and performance considerations exist (e.g. element caching), but there is no central `CacheManager` or `RateLimiter` actor.

**Phase 2 tasks:**
- Document existing caching behaviour (which actors cache what, and for how long).
- Identify hotspots (e.g. large traversals, heavy queries) where explicit caching or rate limiting is needed.
- Decide whether to introduce dedicated caching/rate-limiting components or to extend existing actors.

---

## **Phase 3: Service Completeness (Concrete Gaps)**

Phase 3 narrows to **specific, high-impact gaps** between the existing service and the production-ready bar.

### **3.1 Application & Window Services**

**Current reality:**
- Application and Window RPCs are implemented and usable.

**Phase 3 tasks:**
- Harden error handling when applications or windows terminate unexpectedly.
- Ensure window metadata (title, bounds, visibility, minimized state, bundle ID) is populated consistently.
- Implement and test bundle ID resolution in `WindowRegistry` via `NSRunningApplication` to eliminate "unknown" bundle IDs.

### **3.2 Element & Input Services**

**Current reality:**
- Element targeting and input execution work for a broad set of scenarios.

**Phase 3 tasks:**
- Address element path and staleness issues (document semantics; improve cache invalidation where feasible).
- Expand `PerformElementAction` support for a curated set of additional actions (double-click, right-click, hover, drag) that are realistically needed.
- Clarify which advanced input types are supported and ensure errors are predictable for unsupported types.

### **3.3 Observation & Session Services**

**Current reality:**
- Observations and sessions are implemented, including LRO creation and streaming.

**Phase 3 tasks:**
- Implement window change detection and diffing in `ObservationManager`, surfacing appropriate events via `StreamObservations`.
- Define practical semantics for session rollback (what is logically rolled back vs what is not) and reflect this in server behaviour and documentation.

### **3.4 Query & Pagination (MANDATORY)**

**Current reality:**
- Query-like behaviours are provided via `FindElements`, `FindRegionElements`, and list RPCs, but pagination is incomplete.

**Phase 3 tasks (AIP‑158 blockers):**
- Confirm, by reading the concrete Swift implementations, that **every** List/Find RPC supports `page_size`/`page_token`/`next_page_token` and uses an opaque token format in line with AIP-158. Where coverage is missing (e.g. `FindElements`, `FindRegionElements`, `ListObservations`, `ListApplications`), implement pagination.
- Add explicit tests for all paginated RPCs to ensure deterministic ordering, stable pagination, and correct `next_page_token` behaviour. Proto comments must describe that tokens are opaque, and only high-level semantics (e.g. presence/absence, not structure) may be relied upon by clients.

### **3.5 Scope-Managed Future Enhancements**

To avoid over-scoping Phase 3, the following remain **explicit future work** beyond the first production-ready milestone:
- Full screen recording and animated outputs.
- Rich macro-language features (record/loop/conditional programming model).
- Advanced script analytics, history, and long-running streaming outputs.
- Dedicated debug RPCs beyond what is needed for supportability and testing.

---

## **Phase 4: Testing Strategy (Grounded & Prioritised)**

**Objective:** Engineer a deterministic test suite that validates functional correctness, state convergence, and error handling for the `MacosUse` gRPC service, with **state-difference assertions** for all mutations.

### **4.1 Unit Tests**

**Current reality:**
- Some Swift unit tests exist for server and SDK components; Go integration tests exist under `integration/`.

**Phase 4 tasks:**
- Add focused unit tests for existing components:
    - `WindowRegistry`.
    - `ObservationManager` (including window-change diffs once implemented).
    - `OperationStore` (lifecycles, timestamps).
    - `SessionManager`.
    - `SelectorParser` / `ElementLocator`.
- Cover edge cases such as:
    - Element not found / invalid selectors.
    - Windows closing mid-operation.
    - Applications quitting while operations are in-flight.
    - Permission-denied behaviours where system APIs refuse access.

**MANDATORY PROCESS REQUIREMENTS (UNIT TESTS):**
- For EVERY new Swift server component, SDK helper, or Go client helper, a corresponding unit test case MUST be added or extended in the SAME change set.
- When modifying existing behavior, existing tests MUST be updated or new tests added to exercise both the previous bug condition and the corrected behavior.
- No public API surface change (proto, gRPC method semantics, or exported Swift/Go symbol) is allowed without at least one test that fails before the change and passes after.

### **4.2 Test Harness & Environment Standardisation**
-   **Goal:** Eliminate test flakiness caused by shared state or lingering processes.
-   **Implementation Requirement:**
    -   Develop a **Test Fixture Lifecycle** that runs before and after *every* single test case.
    -   **Pre-flight:** Must scan the OS process list for "Golden Applications" (defined below) and forcefully terminate them (SIGKILL) to ensure a clean slate.
    -   **Post-flight (TearDown):**
        -   Must aggressively issue `DeleteApplication` RPCs for any resources created during the test, followed by a verify-kill of the OS process.
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
        1.  **Launch Verification:** Invoke `OpenApplication` for TextEdit. **Poll** `GetApplication` (max 2s) until status is `STATE_COMPLETED`.
        2.  **Persistence Check:** Immediately invoke `ListApplications`. Assert that the list contains exactly the app opened in step 1.
        3.  **Termination Verification:** Invoke `DeleteApplication` (graceful). Verify via `ListApplications` that the app is removed from the server's tracking.
        4.  **Force Kill Verification:** Invoke `DeleteApplication` with `force=true`. Verify via OS shell command that the PID no longer exists.
-   **Precise Window Geometry Control**
    -   **Goal:** Verify `GetWindow`, `ListWindows`, `MoveWindow`, `ResizeWindow`, `FocusWindow`, `Minimize/Restore`.
    -   **Actionable Tasks:**
        1.  **Discovery:** Open TextEdit. **Poll** `ListWindows` until count >= 1. Capture the `name` (resource ID) of the main window.
        2.  **Geometry Mutation:** Invoke `ResizeWindow` setting dimensions to strictly `500x500`. **Poll** `GetWindow` in a tight loop (max 2s) until `bounds.width` and `bounds.height` are within a 2-pixel tolerance of 500. Fail if timeout.
        3.  **Position Mutation:** Invoke `MoveWindow` to coordinates `100,100`. **Poll** `GetWindow` until `bounds.x` and `bounds.y` reflect this change.
        4.  **State Mutation:** Invoke `MinimizeWindow`. **Poll** `GetWindow` until `minimized=true`. Invoke `RestoreWindow`. **Poll** until `minimized=false`.

### **4.4 Input Fidelity & Event Timeline**
-   **Complex Input Sequences**
    -   **Goal:** Verify `CreateInput`, `ListInputs`, and specific `InputAction` types (Text, Click, Drag).
    -   **Actionable Tasks:**
        1.  **Text Entry Validation:** Target TextEdit. Invoke `CreateInput` with `TextInput` payload "Hello_World". Verify success. **Poll** `TraverseAccessibility` and recursively search the element tree until a `StaticText` or `TextArea` node contains the exact string "Hello_World".
        2.  **Mouse Drag Simulation:** Target the TextEdit window title bar. Invoke `GetWindow` to establish start coordinates. Invoke `CreateInput` with `MouseDrag` payload. Verify execution. **Poll** `GetWindow` to confirm the window coordinates have shifted.
        3.  **Input History:** Invoke `ListInputs` for the application. Assert that the sequence of inputs (Text, then Drag) appears in the returned list in chronological order with `state=STATE_COMPLETED`.

### **4.5 Accessibility & Element Interaction**
-   **Tree Traversal & Search**
    -   **Goal:** Verify `TraverseAccessibility`, `FindElements`, `GetElement`.
    -   **Actionable Tasks:**
        1.  **Full Tree Dump:** Invoke `TraverseAccessibility`. Assert `stats.count` > 10. Assert `stats.visible_elements_count` > 0.
        2.  **Selector Precision:** Invoke `FindElements` using a `CompoundSelector`. Verify it returns specific controls.
        3.  **Element Re-acquisition:** Take the `element_id` from the search result. Invoke `GetElement` using that ID. Assert the returned object matches the search result exactly.
-   **Interactive Element State**
    -   **Goal:** Verify `ClickElement`, `WriteElementValue`, `PerformElementAction`.
    -   **Actionable Tasks:**
        1.  **Action Discovery:** Invoke `GetElementActions` on a window's "Close" button. Verify "AXPress" exists.
        2.  **Direct Action:** Invoke `PerformElementAction` with "AXPress". **Poll** `ListWindows` until the window count has decreased by 1.

### **4.6 System Integration & Observability**
-   **Visual Verification (Screenshots)**
    -   **Goal:** Verify `CaptureScreenshot`, `CaptureWindowScreenshot`, `CaptureElementScreenshot`.
    -   **Actionable Tasks:**
        1.  **Format Compliance:** Invoke `CaptureScreenshot` requesting `IMAGE_FORMAT_PNG`. Decode the resulting `image_data`.
        2.  **Contextual Capture:** Invoke `CaptureWindowScreenshot` for Calculator with `include_ocr_text=true`. Assert `ocr_text` contains displayed numeric values.
-   **Clipboard & Scripting**
    -   **Goal:** Verify `Clipboard` resource and `Execute*Script` RPCs.
    -   **Actionable Tasks:**
        1.  **Clipboard Roundtrip:** Invoke `WriteClipboard`. **Poll** `GetClipboard` until content matches.
        2.  **Polyglot Execution:** Verify `ExecuteShellCommand`, `ExecuteAppleScript`, and `ExecuteJavaScript`.

### **4.7 Advanced Workflows (Macros & Sessions)**
-   **Macro Logic**
    -   **Goal:** Verify `CreateMacro`, `ExecuteMacro` (LRO).
    -   **Actionable Tasks:**
        1.  **Definition:** Create a Macro resource.
        2.  **Execution:** Invoke `ExecuteMacro`. Poll the returned Operation.
        3.  **Verification:** Assert `actions_executed`. **Poll** the target app state to verify effects.
-   **Session Transactions**
    -   **Goal:** Verify `Session` resource and `Begin/Commit/Rollback Transaction`.
    -   **Actionable Tasks:**
        1.  **Transaction Integrity:** Perform ops in a transaction.
        2.  **Audit Trail:** Invoke `GetSessionSnapshot`. Verify history.
-   **Reactive Observation**
    -   **Goal:** Verify `WatchAccessibility` and `CreateObservation`.
    -   **Actionable Tasks:**
        1.  **Stream Setup:** Initiate `WatchAccessibility`.
        2.  **Trigger:** Invoke `CreateInput` to click a button.
        3.  **Event Capture:** Verify receipt of a response where `modified` elements contains the expected change.

### **4.8 Integration Tests (Prioritised Matrix)**

Instead of attempting a full matrix at once, Phase 4 focuses on a **prioritised subset** of high-value scenarios:
- Calculator: core arithmetic flows using element targeting and inputs.
- TextEdit: open, type, resize/move window, and verify via traversal.
- Finder: basic navigation and clipboard/file dialog interactions.
- Multi-window scenarios within a single app (e.g. multiple TextEdit windows).
- Basic multi-app coordination (e.g. copy from one app, paste in another).
- Error recovery and resource cleanup.

**MANDATORY PROCESS REQUIREMENTS (INTEGRATION TESTS):**
- New or changed end-to-end behaviors (e.g. new RPCs, new observation types, pagination semantics) MUST be covered by at least one integration test that exercises the full stack: client → gRPC → server actors → macOS APIs.
- Integration tests MUST rely on `PollUntil` and state-delta assertions rather than fixed sleeps; introducing `sleep`-based timing in tests is FORBIDDEN unless there is no viable alternative, in which case the constraint and rationale MUST be documented in this plan.
- Any regression reported against a previously working scenario MUST result in an additional integration test that reproduces the issue and remains in the suite permanently.

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

### **4.12 Immediate End-to-End Verification Plan**
*(Specific Plan for Current Cycle)*

- **Build/Run Preconditions:**
    - macOS 12+ (headless or with simulator; server requires Accessibility & Screen Recording).
    - Integration tests run via `cd integration; go test -v`, using generated Go stubs in `gen/go/*`.
    - Use `INTEGRATION_SERVER_ADDR` env to test against existing server.

- **Verify Baseline Health & Simple Operations:**
    - Test: `ListApplications`, `OpenApplication`, `GetApplication`, `DeleteApplication`.
    - Approach: Call `OpenApplication` (LRO), wait for op completion, verify `GetApplication` returns correct PID.

- **Test: Input & Element Actions:**
    - Use a test app (Calculator or TextEdit):
        - Find a button via `FindElements`, `ClickElement` and verify effect (e.g., Calculator displays result).
    - Run `PerformElementAction` with AX-based action (press) and coordinate fallback.

- **Test: Find and Pagination:**
    - Create a test that ensures `FindElements` returns page results with `nextPageToken` and request subsequent page to iterate.

- **Test: Observation Streams:**
    - Create observation on elements, make application change (open/close windows, change text), verify:
        - Streamed events include changes.
        - `createObservation` LRO returns proper result.
        - `StreamObservations` receives events.

- **Test: Window Changes Detection:**
    - Create Observation for window changes; open/close windows in the app; expect window add/remove events in the stream.

- **Test: Scripting:**
    - `GetScriptingDictionaries` returns bundle ID & command set for a given app.

- **Test: Macro Management:**
    - Create macros, update, list paginated results, execute macros, verify action effects & operation response.

- **Test: Screen Capturing:**
    - Capture screenshot & window screenshot; ensure image/data returns match expected size or MIME type.

- **Test: Error Handling:
    - Invalid inputs: Call `GetElement` with invalid resource names, expecting `invalidArgument`/`notFound`.

### **Correctness & Verification Guarantees (MANDATORY)**

To ensure this implementation plan provides a **guarantee** of correctness, the following validation logic must be strictly adhered to. **ANY DEVIATION IS A CRITICAL FAILURE.**

1.  **State-Difference Assertions (The Delta Check):**
    -   Tests must never assume an action worked simply because the RPC returned `OK`.
    -   **Requirement:** Every mutator RPC (Move, Resize, Click, Type) must be immediately followed by an accessor RPC (GetWindow, GetElement, Traverse) to assert the *Delta* between Pre-State and Post-State matches the expected mutation.

2.  **Wait-For-Convergence Pattern (PollUntil):**
    -   macOS Accessibility API is asynchronous. Standard `Assert` will fail due to race conditions.
    -   **Requirement:** Tests must **strictly avoid** `time.Sleep()`. Instead, implement a `PollUntil(condition, timeout)` utility.
    -   **Implementation:** Loop `GetWindow` (or relevant accessor) every 100ms up to a 2s deadline. Only pass if the state condition is met. Fail immediately if timeout occurs.

3.  **OCR as Ground Truth:**
    -   **Requirement:** For graphical rendering tests (screenshots), byte-comparison is fragile. Verification must rely on the `ocr_text` field or valid image header decoding to guarantee the server isn't returning garbage bytes.

---

## **Phase 5: Proto Refinement (Not Creation)**

Most core proto files already exist. Phase 5 focuses on **refinement** and AIP compliance rather than adding new top-level files.

### **5.1 Existing v1 Protos**

Files already present under `proto/macosusesdk/v1/`:
- `application.proto`
- `clipboard.proto`
- `input.proto`
- `macos_use.proto`
- `macro.proto`
- `observation.proto`
- `screenshot.proto`
- `script.proto`
- `session.proto`
- `window.proto`

**Phase 5 tasks:**
- Ensure each file has required options and metadata per AIPs.
- Verify resource name patterns and method names against AIP-121/190/191.
- Align request/response messages with AIP guidelines (e.g. `List*`/`Get*` shapes, LRO use).
- Document semantics (including pagination, filters, and field masks) in proto comments.

### **5.2 Type Protos**

Files already present under `proto/macosusesdk/type/`:
- `element.proto`
- `geometry.proto`
- `selector.proto`

**Phase 5 tasks:**
- Expand or introduce type protos for shared concepts only where needed (e.g. a `state` or `event` type file if duplication becomes a problem).
- Keep the type surface minimal and focused on genuine reuse.

---

## **Phase 6: Server Architecture – Incremental Enhancements**

Phase 6 captures architectural improvements that go beyond the immediate correctness and completeness issues tackled in Phases 2–5.

### **6.1 Window & Element Management**

**Current reality:**
- `WindowRegistry`, `ElementLocator`, `ElementRegistry`, and `SelectorParser` already exist and are central to window/element handling.

**Phase 6 tasks:**
- Improve window tracking (history, z-order where possible, better matching for identical bounds).
- Tighten element identity and caching semantics, reducing stale references where feasible.

### **6.2 Observation Pipeline**

**Current reality:**
- `ObservationManager` and `ChangeDetector` orchestrate observation lifecycles and polling.

**Phase 6 tasks:**
- Once Phase 3 observation diffs are in place, consider introducing:
    - Simple scheduling/aggregation to avoid flooding clients.
    - More configurable filters for observation streams.

### **6.3 Session & Transaction Internals**

**Current reality:**
- `SessionManager` exists and supports basic session operations.

**Phase 6 tasks:**
- Introduce internal logging/snapshotting of session operations where beneficial for debugging.
- Refine transaction recording to support more advanced rollback semantics if required by real-world usage.

### **6.4 Advanced Input & Query Engine (Future)**

These are optional enhancements to be pursued only when core correctness work is stable.

**Phase 6 tasks:**
- Extend input modelling and validation if advanced gestures or complex sequences become necessary.
- If queries grow significantly in complexity, consider a dedicated internal query execution layer to manage selectors, filters, and pagination more systematically.

---

## **Phase 7: VS Code Integration Patterns**

Phase 7 remains focused on use-case patterns, not new APIs.

### **7.1 Common Workflows**
- Open file by path.
- Navigate to line/column.
- Execute command palette actions.
- Control the debugger, terminal, and file explorer.

### **7.2 Example Implementation**
- Capture a small set of documented flows (in README/docs) that explain how to orchestrate these behaviours using existing RPCs (applications, windows, elements, inputs, observations).

---

## **Phase 8: Documentation**

### **8.1 API Documentation**
- Ensure all v1 and type protos have clear comments for messages, fields, and RPCs.
- Provide examples for each major resource interaction (Application, Window, Element, Observation, Session).

### **8.2 Integration Guide**
- Expand `proto/README.md` and top-level `README.md` with:
    - How to run the server and clients.
    - Environment variable configuration.
    - Basic usage examples for Go and Swift clients.

### **8.3 Advanced Topics**
- Document recommended patterns for sessions, transactions, observations, and selectors, once stabilised by earlier phases.

---

## **Phase 9: Build System & CI Integration**

### **9.1 Buf & Code Generation**
- Keep `buf.yaml` and `buf.gen.yaml` in sync with the existing proto set.
- Ensure Go and Swift stubs are generated deterministically and committed.

### **9.2 Make & Local Tooling**
- Maintain Make and `config.mk` targets for building/running server, SDK, and tests.
- Ensure local workflows mirror CI behaviour as closely as possible.

### **9.3 CI/CD**
- Verify GitHub Actions workflows:
    - Run buf lint and api-linter.
    - Build Swift and Go targets.
    - Run unit and integration tests.
- Add CI checks for API compatibility and performance regressions where practical.

---

## **Phase 10: Implementation Priorities (Re-ranked)**

### **Priority 1: Pagination & AIP Compliance (CRITICAL)**
Implement and test AIP-158-compliant pagination for key list/find RPCs and ensure overall AIP alignment for the existing API surface.

### **Priority 2: Observation & Window Changes (HIGH)
Add robust window and element change detection to `ObservationManager` and expose it through streaming RPCs.

### **Priority 4: Bundle IDs & Scripting (HIGH)**
Fix bundle ID resolution and `GetScriptingDictionaries` so scripting and window attribution are reliable.

### **Priority 5: Element & Input Semantics (MEDIUM)**
Refine element identity/staleness semantics and expand `PerformElementAction` to a practical, well-documented set of actions.

### **Priority 6: Sessions & Transactions (MEDIUM)**
Clarify and, where feasible, enhance rollback and snapshot behaviours.

### **Priority 7: Testing & Harness (MEDIUM)**
Build out the prioritised integration tests and PollUntil-based convergence patterns.

### **Priority 8: VS Code / Workflow Patterns (LOW)**
Document patterns for dev-tool automation using the existing API.

### **Priority 9: Advanced Features (LOW)**
Pursue advanced input, screen recording, rich macro language, and deep debug tooling after the above are solid.

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

---

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**
