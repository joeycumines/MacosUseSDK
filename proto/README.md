# MacosUseSDK Proto API

This directory contains the Protocol Buffer definitions for the MacosUseSDK gRPC API.

## Structure

```
proto/
├── macosusesdk/
│   ├── type/              # Common type definitions (AIP-213)
│   │   ├── element.proto    # UI element and traversal types
│   │   ├── geometry.proto   # Point and geometric types
│   │   └── selector.proto   # Selector grammar definitions
│   └── v1/                # API v1 definitions
│       ├── application.proto # Application resource
│       ├── clipboard.proto   # Clipboard resource
│       ├── condition.proto   # Condition types
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

3.  **Input** (`applications/{application}/inputs/{input}` or `desktopInputs/{input}`)

      * Represents a discrete input action (click, type, gesture) within a timeline.

4.  **Session** (`sessions/{session}`)

      * Maintains context across complex workflows.
      * Supports transactional semantics for atomic operations.

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

  * **`GetWindow` (AX-First Hybrid Authority):**
    Returns fresh Accessibility API (AX) data for geometry (bounds) and title, ensuring mutation
    responses (MoveWindow/ResizeWindow) reflect the exact requested values without polling delays.
    Visibility uses an AX-first optimistic approach: assumes visible=true if not minimized/hidden,
    only falling back to cached registry data when AX state indicates the window is not on screen.
    This eliminates false negatives from stale CGWindowList during rapid mutations.

  * **`ListWindows` (Registry-Only Performance):**
    Returns cached CoreGraphics data (CGWindowList via WindowRegistry) with ZERO per-window AX queries.
    Completes in <50ms regardless of window count, suitable for high-frequency polling and UI rendering.
    Registry data (bounds, title, visible) may lag 10-100ms behind actual state during rapid mutations.

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
  * **Transactions:** Sessions support ACID-like transactions via `BeginTransaction`, `CommitTransaction`, and `RollbackTransaction`.
  * **Isolation:** Clients can specify isolation levels (e.g., `ISOLATION_LEVEL_SERIALIZABLE`) to ensure that a sequence of operations (like navigating a menu) is treated atomically. If a step fails, the session can be rolled back to a known good state.

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

  * **`OpenApplication`**: Launches or activates apps.
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
  * `SelectFile`, `SelectDirectory`, `DragFiles`

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

### Input Timeline & Circular Buffer

Inputs (`CreateInput`) form a timeline. The server maintains a configurable circular buffer of `COMPLETED` inputs, allowing clients to query recent history for debugging or pattern analysis.

### Standard Methods (AIP-130 - AIP-135)

All resources (`Application`, `Input`, `Window`, `Macro`, `Session`, `Observation`) implement standard `Get`, `List`, `Create`, `Update`, and `Delete` methods where applicable.

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
make generate
```

## Linting

The API is validated with `buf lint` and `api-linter`.

```sh
make lint
```

## Dependencies

  - `buf.build/googleapis/googleapis`: Google API common protos

## Versioning

The API is versioned as `v1`.

## HTTP/JSON Mapping

All RPCs include HTTP annotations enabling REST/JSON access via grpc-gateway.

## Contributing

When modifying the API:

1.  Follow all applicable AIPs
2.  Regenerate code with `buf generate`
3.  Run linters for all protos and code using `make lint`
4.  Update this README with structural or design changes, notable AIPs, or learnings
5.  Update `implementation-plan.md` with significant changes
