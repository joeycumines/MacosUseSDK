# MacosUseSDK Proto API

This directory contains the Protocol Buffer definitions for the MacosUseSDK gRPC API.

## Structure

```
proto/
├── macosusesdk/
│   ├── type/              # Common type definitions (AIP-213)
│   │   ├── traversal.proto  # Traversal types
│   │   ├── geometry.proto   # Point and geometric types
│   │   └── selector.proto   # Selector grammar definitions
│   └── v1/                # API v1 definitions
│       ├── application.proto # Application resource
│       ├── clipboard.proto   # Clipboard resource
│       ├── condition.proto   # Condition types
│       ├── display.proto     # Display resource
│       ├── element.proto     # Element resource
│       ├── input.proto       # Input resource
│       ├── macos_use.proto   # MacosUse service and methods
│       ├── macro.proto       # Macro resource
│       ├── observation.proto # Observation resource
│       ├── screenshot.proto  # Screenshot types
│       ├── script.proto      # Scripting definitions
│       ├── session.proto     # Session and transaction resources
│       └── window.proto      # Window resource
└── README.md
```

## API Design Principles

This API follows [Google's API Improvement Proposals (AIPs)](https://google.aip.dev/) strictly:

### Resource-Oriented Design

The API is built around a hierarchy of resources that represent the state and capabilities of the macOS environment:

1.  **Application** (`applications/{application}`)

      * Represents a running macOS application being tracked.
      * Parent to Inputs, Windows, and Observations.

2.  **Window** (`applications/{application}/windows/{window}`)

      * Represents an on-screen window.
      * Designed for high-performance enumeration (see *Window Design Pattern* below).

3.  **Input** (`applications/{application}/inputs/{input}`; use application `-` for desktop-wide input)

      * Represents one owned physical input transaction with an exact application, window, display, or explicit desktop target.
      * Preserves immutable action and target intent plus truthful delivery commitment and posted-event evidence.

4.  **Session** (`sessions/{session}`)

      * Maintains context across complex workflows.
       * Supports transaction-like session bookkeeping; rollback truncates recorded history and does not undo
         already-applied macOS side effects.

5.  **Macro** (`macros/{macro}`)

      * Represents a recorded or defined sequence of actions (loops, conditionals, inputs).
      * Persisted resources that can be executed as Long-Running Operations.

6.  **Observation** (`applications/{application}/observations/{observation}`)

      * Represents an active monitor for UI changes (elements, windows, or attributes).
      * Streams events back to the client.

7.  **Clipboard** (`clipboard`)

      * Singleton resource representing the system clipboard.
      * Supports rich content types (Text, RTF, HTML, Images, Files).

8.  **Scripting Dictionary** (`scriptingDictionaries/{name}`)

      * Represents the AppleScript/JXA capabilities and terminology available for specific applications.

### Window Design Pattern (Data Authority)

A specific design pattern is applied to Windows to balance performance with data accuracy:

   * **`GetWindow` (AX-Validated Hybrid Authority):**
    Returns fresh Accessibility API (AX) data for geometry (bounds) and title, ensuring mutation
     responses (MoveWindow/ResizeWindow) return after cancellation-aware AX
     convergence polling observes a stable result, or report a timeout if the
     requested state does not converge.
     Visibility requires the admitted registry row to be on screen and fresh AX state to report
     neither a minimized window nor a hidden owner.
     This avoids trusting AX alone for visibility; a stale registry row can still
     report `visible=false`, so callers should treat the result as the admitted
     hybrid snapshot rather than a guarantee against every Quartz false negative.

  * **`ListWindows` (Registry-Only Performance):**
    Returns cached CoreGraphics data (CGWindowList via WindowRegistry) with ZERO per-window AX queries.
     Performs one Core Graphics snapshot and parses the returned population, with no per-window AX queries.
     Registry data (bounds, title, visible) is a volatile snapshot and may lag
     actual state during rapid mutations.

  * **`GetWindowState` Singleton (Deep AX Authority):**
    For authoritative accessibility details, the API exposes a singleton sub-resource: `WindowState`
    (`applications/{app}/windows/{window}/state`). Fetching this resource triggers fresh, expensive
    queries to the Accessibility API for deep state: `minimized`, `ax_hidden`, `modal`, `focused`,
    `resizable`, `minimizable`, `closable`, etc.

  * **Principle:**
    - Use `ListWindows` for fast enumeration and discovery
    - Use `GetWindow` for authoritative data after mutations or before acting on a specific window
    - Use `GetWindowState` only when making logic decisions requiring expensive AX state
      (e.g., "Is this window actually capable of receiving input right now?")

### Session & Transaction Model

To support complex automation workflows that require reliability, the API introduces **Sessions**:

  * **Context:** Sessions allow the server to maintain state (metadata, active targets) across multiple RPCs.
  * **Transactions:** Sessions support transaction-like bookkeeping via `BeginTransaction`, `CommitTransaction`, and `RollbackTransaction`.
  * **Isolation:** Clients can record a workflow under an isolation setting, but rollback only removes recorded operations; it does not reverse external macOS side effects.

### Service Structure (AIP-190, AIP-191)

  * Single service: `MacosUse`
  * File: `macos_use.proto` contains the service definition.
  * Resources are modularized into their own `.proto` files.

### Selector Grammar (Element Selection)

The `ElementSelector` type in `type/selector.proto` provides a declarative way to query UI elements.

**Implemented Features:**

  * **Simple:** Role, Text (Exact/Contains/Regex), Position, Attributes.
  * **Compound:** AND, OR, NOT logic.
  * **Performance:** Simple selectors are optimized; Regex/Attributes require full tree traversal.

### Long-Running Operations (AIP-151)

Operations that take significant time or wait for external state changes return `google.longrunning.Operation`. Clients can poll, cancel, or wait for these operations.

**Implemented LROs:**

  * **`WaitElement` / `WaitElementState`**: Suspends execution until a UI element appears or satisfies a condition (e.g., becomes enabled).
  * **`ExecuteMacro`**: Runs a stored sequence of actions.
  * **`CreateObservation`**: Initializes a monitoring stream.

### Custom Methods (AIP-136)

The API exposes extensive custom methods categorized by capability:

**Window Management:**

  * `FocusWindow`, `MoveWindow`, `ResizeWindow`
  * `MinimizeWindow`, `RestoreWindow`, `CloseWindow`

**Element Operations:**

  * `ClickElement`, `WriteElementValue`, `PerformElementAction`
  * `FindElements`, `FindRegionElements`

**File System & Dialogs:**

  * `AutomateOpenFileDialog`, `AutomateSaveFileDialog`

**Script Execution:**

  * `ExecuteAppleScript`, `ExecuteJavaScript` (JXA), `ExecuteShellCommand`
  * Includes validation (`ValidateScript`) and timeout management.

**Screen Capture:**

  * `CaptureScreenshot` (Full screen)
  * `CaptureWindowScreenshot`, `CaptureElementScreenshot`, `CaptureRegionScreenshot`
  * Supports OCR text extraction and various image formats.

**Observation & Streaming:**

  * `WatchAccessibility` (stream tree changes)
  * `StreamObservations` (stream specific monitored events)

### Input Lifecycle

`CreateInput` requires a caller identity and exact target. A queued input remains
`PENDING`, changes to `EXECUTING` only after final target admission, then settles
as `COMPLETED`, `FAILED`, or `CANCELLED`. Completed inputs require
`COMMITTED_AND_SETTLED`, a positive post count, and routed-delivery observation;
failed or cancelled inputs retain precise `NO_EFFECT` or
`POSSIBLY_COMMITTED` truth. `GetInput` and `ListInputs` expose persisted history
without changing the immutable action or target.

### Standard Methods (AIP-130 - AIP-135)

Resources expose the standard and custom methods defined for each resource in
`macos_use.proto`; the surface is not a uniform Get/List/Create/Update/Delete
set for every resource.

### Pagination (AIP-158)

List methods support pagination via `page_size` and `page_token`.

## File Options

All proto files include mandatory options per AIP-191:

```protobuf
option go_package = "github.com/joeycumines/MacosUseSDK/gen/go/...";
option java_multiple_files = true;
option java_outer_classname = "...Proto";
option java_package = "com.macosusesdk...";
```

## Code Generation

Generated code is committed to the repository:

  - `Server/Sources/MacosUseProto/`: Swift server stubs
  - `gen/go/`: Go client stubs

### Regenerating Code

```sh
gmake generate
```

## Linting

The API is validated with `buf lint` and `api-linter`.

```sh
gmake lint
```

## Dependencies

  - `buf.build/googleapis/googleapis`: Google API common protos

## Versioning

The API is versioned as `v1`.

## HTTP/JSON Mapping

RPCs include Google HTTP annotations as contract/mapping metadata. This
repository does not ship a grpc-gateway runtime or REST endpoint.

## Contributing

When modifying the API:

1.  Follow all applicable AIPs
2.  Regenerate code with `buf generate`
3.  Run linters for all protos and code using `gmake lint`
4.  Update this README with structural or design changes, notable AIPs, or learnings
5.  Update `WIP.md` with significant execution-state changes
