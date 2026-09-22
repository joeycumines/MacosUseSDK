> [!NOTE]
>
> **ExactMac is a fork of [mediar-ai/MacosUseSDK](https://github.com/mediar-ai/MacosUseSDK);
> it is not affiliated with mediar-ai.**
> The Go MCP proxy, Swift gRPC service, 29-tool CUA surface, owned-input
> transaction model, and agent skill are work done since the fork; upstream has
> had no commits since the fork point.
> [macos-use.dev](https://macos-use.dev/) documents a different project,
> `mediar-ai/mcp-server-macos-use` (a 6-tool Swift stdio server).

[![CI](https://github.com/joeycumines/ExactMac/actions/workflows/ci.yaml/badge.svg)](https://github.com/joeycumines/ExactMac/actions/workflows/ci.yaml)
[![Go Coverage](https://img.shields.io/badge/Go%20Coverage-70%25+-blue?style=flat)](https://github.com/joeycumines/ExactMac)
[![Swift Coverage](https://img.shields.io/badge/Swift%20Coverage-see%20CI-blue?style=flat)](https://github.com/joeycumines/ExactMac/actions)

# ExactMac — macOS Computer Use for AI Coding Tools (MCP)

Give your AI coding assistant hands on your Mac: open apps, click buttons by name,
type into fields, manage windows, and verify the result — through one local
[Model Context Protocol](https://modelcontextprotocol.io/) server.

ExactMac is built for developers who already live in **Claude Code**, **Codex CLI**,
the **Codex app (Codex desktop)**, **Cursor**, **OpenCode**, **Gemini CLI**,
**VS Code**, **Windsurf**, or **Claude Desktop** and want real macOS desktop
automation — not a second agent harness to learn. If your tool speaks MCP over
stdio, it can drive your Mac through ExactMac.

## Why ExactMac instead of built-in computer use or another MCP server?

**Against built-in computer use (Claude Code's `computer-use`, Codex background use).**
Built-ins are screenshot-first fallbacks: full-screen re-described
every step, pixel-guessed clicks, per-session app approvals, one session holding a
machine-wide lock. ExactMac reads the native Accessibility tree — the same structured
data Apple gives VoiceOver — so agents click by text (`"Send"`, `"Submit"`), not
by guessed coordinates. Claude's own routing tries MCP tools first and falls back
to screen control only when nothing better exists: ExactMac is used first and
the built-in remains the fallback for custom-rendered canvases
with no Accessibility tree at all.

**Against the many macOS MCP servers.** Most wrap AppleScript (only scriptable
apps work), loop screenshots (each click costs vision-model tokens), or click
raw coordinates with no ownership model. ExactMac is:

- **AX-first, not screenshot-first.** Structured roles, labels, and coordinates;
  screenshots only for visual verification, canvas apps, and JetBrains IDEs with
  Accessibility disabled (clean visual-grounding fallback in the skill).
- **Owned input transactions.** Every click, keypress, drag, and scroll names one
  exact application, window, display, or explicit desktop target, converges on
  focus/activation at the backend, and returns a truthful terminal delivery
  result — never a bare "OK".
- **29 focused CUA tools, one server.** Screen capture, mouse, keyboard, element
  discovery and interaction, window and application management, clipboard,
  command execution, display grounding, and recorded macros — over stdio or
  Streamable HTTP, with TLS, API-key auth, rate limiting, and audit logging.
- **100% local.** Swift gRPC service plus Go MCP proxy on your machine. No SaaS,
  no network egress from the server itself.

## Quick start

Prerequisites: macOS with Accessibility permission granted to the host process
(your terminal or agent app — that is macOS's TCC model, not ours), Xcode
Command Line Tools for the Swift build, Go for the proxy build.

```sh
# Build everything (Swift + Go + protobuf checks use logged Make targets)
gmake all

# Start the Swift gRPC backend
cd Server && swift build -c release
GRPC_LISTEN_ADDRESS=127.0.0.1 GRPC_PORT=50051 ./.build/release/ExactMacServer &

# Build the MCP proxy
go build -o exactmac ./cmd/exactmac
```

Then register it in your AI tool (per-client setup guide with verification
steps: `docs/ai-artifacts/08-ai-tool-integration.md`):

| Your tool | Where | Snippet |
|-----------|-------|---------|
| **Claude Code** | `claude mcp add` (project scope; `-s user` for global) | `claude mcp add exactmac -- /path/to/exactmac mcp` |
| **Codex CLI** | `~/.codex/config.toml` | `[mcp_servers.exactmac]` + `command = "/path/to/exactmac"` + `args = ["mcp"]` |
| **Cursor** | `~/.cursor/mcp.json` (global) or `.cursor/mcp.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **OpenCode** | `opencode.jsonc` / `opencode.json` | `"exactmac": { "type": "local", "command": ["/path/to/exactmac", "mcp"] }` |
| **Gemini CLI** | `~/.gemini/settings.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **VS Code / Windsurf** | MCP settings | same stdio command shape as above |

Point `EXACTMAC_SERVER_ADDR` at the Swift backend (default `localhost:50051`).
Verify with one call: `list_apps` should return your running applications.

For repeatable GUI work, also load the agent skill in `skills/exactmac/` —
recovery procedures, coordinate math, and workflow recipes your agent follows
instead of guessing.

## Components

- **ExactMac (Swift library)**: Core Accessibility automation primitives
  (`AXUIElement`, CoreGraphics input, AppKit windows). Published as the
  `ExactMac` Swift package; embedding notes under [Using the Library](#using-the-library).
- **MCP Server (Go CLI `cmd/exactmac`, served via `exactmac mcp`)**: MCP server exposing
  **29 CUA-aligned MCP tools** via stdio or Streamable HTTP (TCP or Unix socket),
  with rate limiting, API-key auth, and audit logging.
- **gRPC Server (Swift, `Server/`)**: Resource-oriented API following
  [Google's AIPs](https://google.aip.dev/) — WindowRegistry, ObservationManager,
  SessionManager, LRO pattern for async operations.

## Documentation

| Document | Description |
|----------|-------------|
| [AI Tool Integration](docs/ai-artifacts/08-ai-tool-integration.md) | Per-client setup (Claude Code, Codex, Cursor, OpenCode, Gemini, VS Code, Windsurf, Desktop) with snippets and verification steps |
| [Agent Skill](skills/exactmac/SKILL.md) | Workflow, recovery, and troubleshooting reference your agent loads |
| [Deployment Guide](DEPLOYMENT.md) | Local single-user deployment: app bundle, LaunchAgent, Unix socket, signing, TCC grants |
| [MCP Integration](docs/ai-artifacts/05-mcp-integration.md) | Protocol compliance, transport specifications, security, and tooling details |
| [MCP Server Design](docs/ai-artifacts/11-mcp-server-design-for-computer-use-agents.md) | Design notes for the CUA-aligned MCP server surface |
| [Tool Design Review](docs/ai-artifacts/07-mcp-tool-design-review.md) | Tool surface review and rationale |

## Architecture

### Three-Layer Design

```
┌─────────────────────────────────────────────────────────────┐
│                      AI Agents / Clients                     │
│         (Claude Code, Codex, Cursor, OpenCode, Gemini)       │
└─────────────────────────┬───────────────────────────────────┘
                          │ JSON-RPC over Streamable HTTP or stdio
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Go CLI (cmd/exactmac, `exactmac mcp`)                        │
│     • 29 CUA-aligned MCP Tools                               │
│     • Streamable HTTP + stdio transports                     │
│     • Rate limiting, API key auth, audit logging             │
└─────────────────────────┬───────────────────────────────────┘
                          │ gRPC (protobuf)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Swift gRPC Server (Server/ExactMacServer)                │
│     • Resource-oriented API (Google AIPs)                    │
│     • WindowRegistry, ObservationManager, SessionManager     │
│     • LRO pattern for async operations                       │
└─────────────────────────┬───────────────────────────────────┘
                          │ Native Swift APIs
                          ▼
┌─────────────────────────────────────────────────────────────┐
│     Swift SDK (Sources/ExactMac)                          │
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

- `ListWindows` uses **Quartz** (one snapshot call plus parsing of the returned population; data may be stale)
- `GetWindow` uses **Accessibility** (fresh geometry for single window)
- Window mutations (move/resize) use **Accessibility**
- Bridging via `_AXUIElementGetWindow` with 1000px heuristic fallback

### Coordinate Systems

macOS uses **two distinct coordinate systems**:

| System | Origin | Y Direction | Used By |
|--------|--------|-------------|---------|
| **Global Display Coordinates (top-left origin)** | Top-left of main display | Down ↓ | CGWindowList, AX, CGEvent, Input APIs |
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
| `EXACTMAC_SERVER_ADDR` | gRPC server address for MCP proxy | `localhost:50051` |
| `GRPC_LISTEN_ADDRESS` | Swift server bind address | `127.0.0.1` |
| `GRPC_PORT` | Swift server port | `8080` |
| `GRPC_UNIX_SOCKET` | Launchd-activated Swift server Unix socket (overrides TCP); leave unset for manual runs | - |

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

The root Swift package intentionally publishes only the `ExactMac` library.
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

You can also use `ExactMac` as a local dependency in your own Swift projects:

```swift
dependencies: [
    .package(path: "../ExactMac"),
]
```

And add `ExactMac` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["ExactMac"]),
```

Then import the low-level SDK:

```swift
import ExactMac
```

The SDK exposes process-local Accessibility and Core Graphics primitives for
embedding. Those low-level functions do not carry the public gRPC resource
target, ownership, cancellation, or delivery receipt. Production automation
should use the generated `ExactMac` client or the MCP server so each physical
input names an exact application, window, display, or explicit desktop target
and returns a truthful terminal delivery result.

## gRPC Server

The repository includes a gRPC server that exposes all SDK functionality via a resource-oriented API.

### Features

- **29 CUA-aligned MCP tools** for focused macOS automation
- **Resource-oriented API** following [Google's AIPs](https://google.aip.dev/)
- **Multi-application support**: Automate multiple applications simultaneously
- **Real-time streaming**: Watch accessibility tree changes in real-time
- **Thread-safe architecture**: CQRS-style with central control loop
- **Flexible MCP transport**: stdio or Streamable HTTP; the HTTP listener can use TCP or a Unix socket
- **Security**: TLS, API key authentication, rate limiting, audit logging

### Quick Start

```sh
# Install buf for protobuf code generation
brew install bufbuild/buf/buf

# Generate gRPC stubs
buf generate

# Build and run the server
cd Server && swift build -c release
.build/release/ExactMacServer
```

### Environment Variables

Key configuration options (see [Server/README.md](Server/README.md) for the Swift server and [cmd/exactmac/README.md](cmd/exactmac/README.md) for the MCP proxy):

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
# Start the Go proxy with `exactmac http` and point
# EXACTMAC_SERVER_ADDR at the Swift gRPC listener (or use a Unix socket).
# Then initialize an MCP session.
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1.0"}}}'

# Call list_apps first, then pass the exact Calculator applicationBundles/*
# resource it returns to open_app.
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
	-H "MCP-Session-Id: <session-id-from-initialize>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}'

curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
	-H "MCP-Session-Id: <session-id-from-initialize>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_app","arguments":{"app":"<calculator-application-bundle-resource>"}}}'

# Call click tool at coordinates
curl -X POST http://localhost:8080/mcp \
	-H "Accept: application/json, text/event-stream" \
	-H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -H "MCP-Session-Id: <session-id-from-initialize>" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click","arguments":{"target":"desktop","x":100,"y":200}}}'
```

## Fork history

ExactMac began as a fork of `mediar-ai/MacosUseSDK` and has long since
diverged; the shipped implementation is work done since the fork. Development
used AI-assisted coding with human review, and the author is not a Swift
specialist.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.
