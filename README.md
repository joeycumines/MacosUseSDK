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

Swift library plus MCP/gRPC servers for traversing the macOS accessibility tree and performing owned user-input transactions.

## Components

- **MacosUseSDK**: Core Swift library for accessibility automation
- **MCP Server**: Production server exposing **29 CUA-aligned MCP tools** for AI agent integration via [Model Context Protocol](https://modelcontextprotocol.io/)
- **gRPC Server**: Resource-oriented gRPC API following [Google's AIPs](https://google.aip.dev/)

## Documentation

| Document | Description |
|----------|-------------|
| [Deployment Guide](DEPLOYMENT.md) | Complete local single-user deployment: app bundle, LaunchAgent, Unix socket, signing, TCC grants |
| [MCP Integration](docs/ai-artifacts/05-mcp-integration.md) | Protocol compliance, transport specifications, security, and tooling details |
| [MCP Server Design](docs/ai-artifacts/11-mcp-server-design-for-computer-use-agents.md) | Design notes for the CUA-aligned MCP server surface |
| [Tool Design Review](docs/ai-artifacts/07-mcp-tool-design-review.md) | Tool surface review and rationale |

## Architecture

### Three-Layer Design

```
┌─────────────────────────────────────────────────────────────┐
│                      AI Agents / Clients                     │
│                  (Claude, GPT, Custom MCP Clients)           │
└─────────────────────────┬───────────────────────────────────┘
                          │ JSON-RPC over Streamable HTTP or stdio
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Go MCP Server (cmd/macos-use-mcp)                        │
│     • 29 CUA-aligned MCP Tools                               │
│     • Streamable HTTP + stdio transports                     │
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
| `MCP_HTTP_ADDRESS` | HTTP server bind address | `127.0.0.1:8080` |
| `MCP_HTTP_SOCKET` | Unix socket path (overrides HTTP) | - |
| `MCP_TLS_CERT_FILE` | TLS certificate for HTTPS | - |
| `MCP_TLS_KEY_FILE` | TLS private key | - |
| `MCP_API_KEY` | API key for authentication | - |
| `MCP_RATE_LIMIT` | Max requests/second; `0` disables | `0` |
| `MCP_AUDIT_LOG_FILE` | Owner-private non-content audit log path | - |
| `MACOS_USE_SERVER_ADDR` | gRPC server address for MCP proxy | `localhost:50051` |
| `GRPC_LISTEN_ADDRESS` | Swift server bind address | `127.0.0.1` |
| `GRPC_PORT` | Swift server port | `8080` |
| `GRPC_UNIX_SOCKET` | Swift server Unix socket | - |

## MCP Tool Catalog

The server exposes **29 CUA-aligned MCP tools** organized into 6 categories:

| Category | Tools | Description |
|----------|-------|-------------|
| **Core CUA Input** | `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait` | Screen capture, mouse, keyboard, and wait input |
| **Element Interaction** | `find_elements`, `click_element`, `type_element`, `read_element` | Accessibility element discovery and interaction |
| **Window Management** | `focus_window`, `move_window`, `resize_window`, `list_windows` | Window enumeration and manipulation |
| **Application Management** | `open_app`, `list_apps`, `close_app` | Application lifecycle management |
| **Utility** | `clipboard`, `run`, `get_display` | Clipboard, command execution, and display grounding |
| **Macros** | `create_macro`, `get_macro`, `list_macros`, `update_macro`, `delete_macro`, `execute_macro` | Recorded multi-step automation sequences |


https://github.com/user-attachments/assets/d8dc75ba-5b15-492c-bb40-d2bc5b65483e

Highlight whatever is happening on the computer: text elements, clicks, typing
![Image](https://github.com/user-attachments/assets/9e182bbc-bd30-4285-984a-207a58b32bc0)

Listen to changes in the UI, elements changed, text changed
![Image](https://github.com/user-attachments/assets/4a972dfa-ce4d-4b1a-9781-43379375b313)

## Building

Use the repository's logged GNU Make targets so Swift, Go, protobuf generation,
and contract checks run with the supported configuration:

```sh
gmake all
```

The logged variant (output capped to the last lines, full log in
`build.log`) is available as `gmake make-all-with-log` when the local
`config.mk` defines it — see `example.config.mk`.

The root Swift package intentionally publishes only the `MacosUseSDK` library.
The former standalone command-line products are not part of the supported
surface; server deployments should use the owned gRPC transaction or MCP tool
boundary.

### Running Tests

Run only specific tests or test classes, use the --filter option.
Run a specific test method: Provide the full identifier TestClassName/testMethodName

```sh
swift test
# Example: Run the physical-input timing contract suite (SDK package)
swift test --filter InputTimingContractTests
# Example: Run the owned input-overlay contract suite (Server package)
(cd Server && swift test --filter InputOverlayPresenterTests)
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

Then import the low-level SDK:

```swift
import MacosUseSDK
```

The SDK exposes process-local Accessibility and Core Graphics primitives for
embedding. Those low-level functions do not carry the public gRPC resource
target, ownership, cancellation, or delivery receipt. Production automation
should use the generated `MacosUse` client or the MCP server so each physical
input names an exact application, window, display, or explicit desktop target
and returns a truthful terminal delivery result.

## gRPC Server

The repository includes a production-ready gRPC server that exposes all SDK functionality via a resource-oriented API.

### Features

- **29 CUA-aligned MCP tools** for focused macOS automation
- **Resource-oriented API** following [Google's AIPs](https://google.aip.dev/)
- **Multi-application support**: Automate multiple applications simultaneously
- **Real-time streaming**: Watch accessibility tree changes in real-time
- **Thread-safe architecture**: CQRS-style with central control loop
- **Flexible transport**: Streamable HTTP or Unix domain sockets
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

Key configuration options (see [Server/README.md](Server/README.md) for the Swift server and [cmd/macos-use-mcp/README.md](cmd/macos-use-mcp/README.md) for the MCP proxy):

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_HTTP_ADDRESS` | HTTP server address | `127.0.0.1:8080` |
| `MCP_HTTP_SOCKET` | Unix socket path (if set, uses UDS) | - |
| `MCP_TLS_CERT_FILE` | TLS certificate file path | - |
| `MCP_TLS_KEY_FILE` | TLS private key file path | - |
| `MCP_API_KEY` | API key for authentication | - |
| `MCP_RATE_LIMIT` | Requests per second limit; `0` disables | `0` |

See [Server/README.md](Server/README.md) for detailed server documentation.

### API Example

Open Calculator and click using MCP tools over HTTP:

```sh
# Initialize MCP session
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"example"}}}'

# Call open_app tool (list_apps first returns the exact applicationBundles/* resource)
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_app","arguments":{"app":"applicationBundles/1c8c8d1c8d1c8d1c8d1c8d1c8d1c8d1c"}}}'

# Call click tool at coordinates
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"target":"desktop","x":100,"y":200}}}'
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.
