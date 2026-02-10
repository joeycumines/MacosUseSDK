> [!IMPORTANT]
>
> **Experimental AI-Driven Fork**
>
> This project was developed by [@joeycumines](https://github.com/joeycumines) with heavy usage of Agentic AI as part of refining a more AI-involved development workflow.
>
> While strict architectural direction was given (particularly around API semantics) and tooling was written by hand, **I am not a native Swift developer.** The code reflects an iterative AI generation process rather than expert-level fluency, though the project served as a surprisingly-successful learning vehicle, and regular human reviews were performed.

[![CI](https://github.com/joeycumines/MacosUseSDK/actions/workflows/ci.yaml/badge.svg)](https://github.com/joeycumines/MacosUseSDK/actions/workflows/ci.yaml)
[![Go Coverage](https://img.shields.io/badge/Go%20Coverage-70%25+-blue?style=flat)](https://github.com/joeycumines/MacosUseSDK)
[![Swift Coverage](https://img.shields.io/badge/Swift%20Coverage-see%20CI-blue?style=flat)](https://github.com/joeycumines/MacosUseSDK/actions)

# MacosUseSDK

Library, command-line tools, and MCP/gRPC server to traverse the macOS accessibility tree and simulate user input actions. Allows interaction with UI elements of other applications.

## Components

- **MacosUseSDK**: Core Swift library for accessibility automation
- **Command-line Tools**: Standalone executables for common automation tasks
- **MCP Server**: Production-ready server exposing **77 MCP tools** for AI agent integration via [Model Context Protocol](https://modelcontextprotocol.io/)
- **gRPC Server**: Resource-oriented gRPC API following [Google's AIPs](https://google.aip.dev/)

## Documentation

| Document | Description |
|----------|-------------|
| [API Reference](docs/ai-artifacts/10-api-reference.md) | Complete reference for all 77 MCP tools, 18 environment variables, coordinate systems, and error codes |
| [Production Deployment](docs/ai-artifacts/08-production-deployment.md) | Deployment guide with TLS, authentication, reverse proxy patterns, and monitoring |
| [Security Hardening](docs/ai-artifacts/09-security-hardening.md) | Security best practices, shell command risks, authentication options |
| [MCP Integration](docs/ai-artifacts/05-mcp-integration.md) | Protocol compliance, transport specifications, tool design |
| [MCP Tool Design](docs/ai-artifacts/06-mcp-tool-design.md) | Detailed tool catalog with all 77 tools organized by category |

## Architecture

### Three-Layer Design

```
┌─────────────────────────────────────────────────────────────┐
│                      AI Agents / Clients                     │
│                  (Claude, GPT, Custom MCP Clients)           │
└─────────────────────────┬───────────────────────────────────┘
                          │ JSON-RPC over HTTP/SSE or stdio
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Go MCP Server (cmd/macos-use-mcp)                        │
│     • 77 MCP Tools                                           │
│     • HTTP/SSE + stdio transports                            │
│     • Rate limiting, API key auth, audit logging             │
└─────────────────────────┬───────────────────────────────────┘
                          │ gRPC (protobuf)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Swift gRPC Server (Server/MacosUseServer)                │
│     • Resource-oriented API (Google AIPs)                    │
│     • WindowRegistry, ObservationManager, SessionManager     │
│     • LRO pattern for async operations                       │
└─────────────────────────┬───────────────────────────────────┘
                          │ Native Swift APIs
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Swift SDK (Sources/MacosUseSDK)                          │
│     • Accessibility APIs (AXUIElement)                       │
│     • CoreGraphics for input simulation                      │
│     • AppKit for window management                           │
└─────────────────────────────────────────────────────────────┘
```

### Hybrid Authority Model

Window and element management uses a **dual-API approach** (see [window-state-management.md](docs/window-state-management.md)):

| Authority | API | Use Case |
|-----------|-----|----------|
| **Quartz (CG)** | `CGWindowListCopyWindowInfo` | Fast enumeration, global window list, metadata |
| **Accessibility (AX)** | `AXUIElement` | Precise geometry, mutations, element interaction |

- `ListWindows` uses **Quartz** (fast, may lag 10-100ms)
- `GetWindow` uses **Accessibility** (fresh geometry for single window)
- Window mutations (move/resize) use **Accessibility**
- Bridging via `_AXUIElementGetWindow` with 1000px heuristic fallback

### Coordinate Systems

macOS uses **two distinct coordinate systems**:

| System | Origin | Y Direction | Used By |
|--------|--------|-------------|---------|
| **Global Display** | Top-left of main display | Down ↓ | CGWindowList, AX, CGEvent, Input APIs |
| **AppKit** | Bottom-left of main display | Up ↑ | NSWindow, NSScreen |

**Important**: Window bounds and input coordinates both use **Global Display Coordinates**. No conversion needed between them. Secondary displays may have negative X (left of main) or negative Y (above main).

### Environment Variable Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_HTTP_ADDR` | HTTP server bind address | `127.0.0.1:8080` |
| `MCP_UNIX_SOCKET` | Unix socket path (overrides HTTP) | - |
| `MCP_TLS_CERT_FILE` | TLS certificate for HTTPS | - |
| `MCP_TLS_KEY_FILE` | TLS private key | - |
| `MCP_API_KEY` | API key for authentication | - |
| `MCP_RATE_LIMIT` | Max requests/second | `100` |
| `MCP_AUDIT_LOG` | Audit log file path | - |
| `MCP_SERVER_ADDR` | gRPC server address for MCP proxy | `127.0.0.1:50051` |
| `GRPC_LISTEN_ADDRESS` | Swift server bind address | `127.0.0.1` |
| `GRPC_PORT` | Swift server port | `50051` |
| `GRPC_UNIX_SOCKET` | Swift server Unix socket | - |

## MCP Tool Catalog

The server exposes **77 MCP tools** organized into 14 categories. See the [full tool reference](docs/ai-artifacts/06-mcp-tool-design.md) for details.

| Category | Tools | Description |
|----------|-------|-------------|
| **Screenshot** | `capture_screenshot`, `capture_window_screenshot`, `capture_region_screenshot`, `capture_element_screenshot` | Screen, window, region, and element capture with OCR support |
| **Input** | `click`, `type_text`, `press_key`, `hold_key`, `mouse_move`, `scroll`, `drag`, `mouse_button_down`, `mouse_button_up`, `hover`, `gesture` | Keyboard, mouse, and gesture input simulation |
| **Element** | `find_elements`, `get_element`, `get_element_actions`, `click_element`, `write_element_value`, `perform_element_action` | UI element discovery and interaction |
| **Window** | `list_windows`, `get_window`, `focus_window`, `move_window`, `resize_window`, `minimize_window`, `restore_window`, `close_window` | Window enumeration and manipulation |
| **Display** | `list_displays`, `get_display`, `cursor_position` | Multi-monitor support and cursor tracking |
| **Clipboard** | `get_clipboard`, `write_clipboard`, `clear_clipboard`, `get_clipboard_history` | Clipboard read/write operations |
| **Application** | `open_application`, `list_applications`, `get_application`, `delete_application` | Application lifecycle management |
| **Scripting** | `execute_apple_script`, `execute_javascript`, `execute_shell_command`, `validate_script`, `get_scripting_dictionaries` | AppleScript, JXA, and shell execution |
| **Observation** | `create_observation`, `stream_observations`, `get_observation`, `list_observations`, `cancel_observation` | Real-time UI change monitoring |
| **Accessibility** | `traverse_accessibility`, `get_window_state`, `find_region_elements`, `wait_element`, `wait_element_state`, `watch_accessibility` | Accessibility tree traversal and queries |
| **File Dialog** | `automate_open_file_dialog`, `automate_save_file_dialog`, `select_file`, `select_directory`, `drag_files` | File/folder dialog automation |
| **Session** | `create_session`, `get_session`, `list_sessions`, `delete_session`, `get_session_snapshot`, `begin_transaction`, `commit_transaction`, `rollback_transaction` | Session and transaction management |
| **Macro** | `create_macro`, `get_macro`, `list_macros`, `delete_macro`, `execute_macro`, `update_macro` | Macro recording and playback |
| **Input Query** | `get_input`, `list_inputs` | Input history and state queries |


https://github.com/user-attachments/assets/d8dc75ba-5b15-492c-bb40-d2bc5b65483e

Highlight whatever is happening on the computer: text elements, clicks, typing
![Image](https://github.com/user-attachments/assets/9e182bbc-bd30-4285-984a-207a58b32bc0)

Listen to changes in the UI, elements changed, text changed
![Image](https://github.com/user-attachments/assets/4a972dfa-ce4d-4b1a-9781-43379375b313)

## Building the Tools

To build the command-line tools provided by this package, navigate to the root directory (`MacosUseSDK`) in your terminal and run:

```sh
swift build
```

This will compile the tools and place the executables in the `.build/debug/` directory (or `.build/release/` if you use `swift build -c release`). You can run them directly from there (e.g., `.build/debug/TraversalTool`) or use `swift run <ToolName>`.

## Available Tools

All tools output informational logs and timing data to `stderr`. Primary output (like PIDs or JSON data) is sent to `stdout`.

### AppOpenerTool

*   **Purpose:** Opens or activates a macOS application by its name, bundle ID, or full path. Outputs the application's PID on success.
*   **Usage:** `AppOpenerTool <Application Name | Bundle ID | Path>`
*   **Examples:**
    ```sh
    # Open by name
    swift run AppOpenerTool Calculator
    # Open by bundle ID
    swift run AppOpenerTool com.apple.Terminal
    # Open by path
    swift run AppOpenerTool /System/Applications/Utilities/Terminal.app
    # Example output (stdout)
    # 54321
    ```

### TraversalTool

*   **Purpose:** Traverses the accessibility tree of a running application (specified by PID) and outputs a JSON representation of the UI elements to `stdout`.
*   **Usage:** `TraversalTool [--visible-only] <PID>`
*   **Options:**
    *   `--visible-only`: Only include elements that have a position and size (are geometrically visible).
*   **Examples:**
    ```sh
    # Get only visible elements for Messages app
    swift run TraversalTool --visible-only $(swift run AppOpenerTool Messages)
    ```

### HighlightTraversalTool

*   **Purpose:** Traverses the accessibility tree of a running application (specified by PID) and draws temporary red boxes around all visible UI elements. Also outputs traversal data (JSON) to `stdout`. Useful for debugging accessibility structures.
*   **Usage:** `HighlightTraversalTool <PID> [--duration <seconds>]`
*   **Options:**
    *   `--duration <seconds>`: Specifies how long the highlights remain visible (default: 3.0 seconds).
*   **Examples:**
    ```sh
    # Combine with AppOpenerTool to open Messages and highlight it
    swift run HighlightTraversalTool $(swift run AppOpenerTool Messages) --duration 5
    ```
    *Note: This tool needs to keep running for the duration specified to manage the highlights.*

### InputControllerTool

*   **Purpose:** Simulates keyboard and mouse input events without visual feedback.
*   **Usage:** See `swift run InputControllerTool --help` (or just run without args) for actions.
*   **Examples:**
    ```sh
    # Press the Enter key
    swift run InputControllerTool keypress enter
    # Simulate Cmd+C (Copy)
    swift run InputControllerTool keypress cmd+c
    # Simulate Shift+Tab
    swift run InputControllerTool keypress shift+tab
    # Left click at screen coordinates (100, 250)
    swift run InputControllerTool click 100 250
    # Double click at screen coordinates (150, 300)
    swift run InputControllerTool doubleclick 150 300
    # Right click at screen coordinates (200, 350)
    swift run InputControllerTool rightclick 200 350
    # Move mouse cursor to (500, 500)
    swift run InputControllerTool mousemove 500 500
    # Type the text "Hello World!"
    swift run InputControllerTool writetext "Hello World!"
    ```

### VisualInputTool

*   **Purpose:** Simulates keyboard and mouse input events *with* visual feedback (currently a pulsing green circle for mouse actions).
*   **Usage:** Similar to `InputControllerTool`, but adds a `--duration` option for the visual effect. See `swift run VisualInputTool --help`.
*   **Options:**
    *   `--duration <seconds>`: How long the visual feedback effect lasts (default: 0.5 seconds).
*   **Examples:**
    ```sh
    # Left click at (100, 250) with default 0.5s feedback
    swift run VisualInputTool click 100 250
    # Right click at (800, 400) with 2 second feedback
    swift run VisualInputTool rightclick 800 400 --duration 2.0
    # Move mouse to (500, 500) with 1 second feedback
    swift run VisualInputTool mousemove 500 500 --duration 1.0
    # Keypress and writetext (currently NO visualization implemented)
    swift run VisualInputTool keypress cmd+c
    swift run VisualInputTool writetext "Testing"
    ```
    *Note: This tool needs to keep running for the duration specified to display the visual feedback.*

### Running Tests

Run only specific tests or test classes, use the --filter option.
Run a specific test method: Provide the full identifier TestClassName/testMethodName

```sh
swift test
# Example: Run only the multiply test in CombinedActionsDiffTests
swift test --filter CombinedActionsDiffTests/testCalculatorMultiplyWithActionAndTraversalHighlight
# Example: Run all tests in CombinedActionsFocusVisualizationTests
swift test --filter CombinedActionsFocusVisualizationTests
```


## Using the Library

You can also use `MacosUseSDK` as a dependency in your own Swift projects. Add it to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "/* path or URL to your MacosUseSDK repo */", from: "1.0.0"),
]
```

And add `MacosUseSDK` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["MacosUseSDK"]),
```

Then import and use the public functions:

```swift
import MacosUseSDK
import Foundation // For Dispatch etc.

// Example: Get elements from Calculator app
Task {
    do {
        // Find Calculator PID (replace with actual logic or use AppOpenerTool output)
        // let calcPID: Int32 = ...
        // let response = try MacosUseSDK.traverseAccessibilityTree(pid: calcPID, onlyVisibleElements: true)
        // print("Found \(response.elements.count) visible elements.")

        // Example: Click at a point
        let point = CGPoint(x: 100, y: 200)
        try MacosUseSDK.clickMouse(at: point)

        // Example: Click with visual feedback (needs main thread for UI)
        DispatchQueue.main.async {
            do {
                 try MacosUseSDK.clickMouseAndVisualize(at: point, duration: 1.0)
            } catch {
                 print("Visualization error: \(error)")
            }
        }

    } catch {
        print("MacosUseSDK Error: \(error)")
    }
}

// Remember to keep the run loop active if using async UI functions like highlightVisibleElements or *AndVisualize
// RunLoop.main.run() // Or use within an @main Application structure
```

## gRPC Server

The repository includes a production-ready gRPC server that exposes all SDK functionality via a resource-oriented API.

### Features

- **77 MCP Tools** for comprehensive macOS automation
- **Resource-oriented API** following [Google's AIPs](https://google.aip.dev/)
- **Multi-application support**: Automate multiple applications simultaneously
- **Real-time streaming**: Watch accessibility tree changes in real-time
- **Thread-safe architecture**: CQRS-style with central control loop
- **Flexible transport**: HTTP+SSE or Unix domain sockets
- **Production-ready**: TLS, API key authentication, rate limiting, audit logging

### Quick Start

```sh
# Install buf for protobuf code generation
brew install bufbuild/buf/buf

# Generate gRPC stubs
buf generate

# Build and run the server
cd Server && swift build -c release
.build/release/MacosUseServer
```

### Environment Variables

Key configuration options (see [API Reference](docs/ai-artifacts/10-api-reference.md#3-environment-variable-reference) for complete list):

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_HTTP_ADDR` | HTTP server address | `127.0.0.1:8080` |
| `MCP_UNIX_SOCKET` | Unix socket path (if set, uses UDS) | - |
| `MCP_TLS_CERT_FILE` | TLS certificate file path | - |
| `MCP_TLS_KEY_FILE` | TLS private key file path | - |
| `MCP_API_KEY` | API key for authentication | - |
| `MCP_RATE_LIMIT` | Requests per second limit | `100` |

See [Server/README.md](Server/README.md) for detailed server documentation.

### API Example

Open Calculator and click using MCP tools over HTTP:

```sh
# Initialize MCP session
curl -X POST http://localhost:8080/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"example"}}}'

# Call open_application tool
curl -X POST http://localhost:8080/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_application","arguments":{"identifier":"Calculator"}}}'

# Call click tool at coordinates
curl -X POST http://localhost:8080/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"x":100,"y":200}}}'
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.
