# MCP Tool Design for MacosUseSDK

## Overview

This document describes the redesigned MCP (Model Context Protocol) server surface for macOS automation. The Go MCP proxy exposes 23 CUA-aligned tools backed by the consolidated `MacosUse` gRPC service.

**Status:** 23 tools implemented and operational in `internal/server/mcp.go`.

## Architecture

```
MCP Server (Go executable)
├── Transport Layer
│   ├── Stdio (stdin/stdout JSON-RPC 2.0)
│   └── HTTP/SSE (Server-Sent Events)
├── Observability
│   ├── /metrics endpoint (Prometheus format)
│   ├── Audit logging (structured JSON)
│   └── Rate limiting (token bucket)
├── Security
│   ├── TLS termination
│   └── API key authentication
├── gRPC Client Connection
│   └── pb.MacosUseClient
└── Tool Registry
    └── internal/server/mcp.go
```

## Tool Categories

| Category | Tools |
|----------|-------|
| Core CUA Input | `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait` |
| Application Management | `open_app`, `list_apps`, `close_app` |
| Element Interaction | `find_elements`, `click_element`, `type_element`, `read_element` |
| Window Management | `focus_window`, `move_window`, `resize_window`, `list_windows` |
| Utility | `clipboard`, `run`, `get_display` |

## Design Notes

- Coordinate fields use **Global Display Coordinates (top-left origin)**.
- `find_elements` and `list_windows` accept `page_size` and `page_token`; returned page tokens are opaque.
- Accessibility element tools use flat parameters (`parent`, `role`, `text`, `text_contains`, `element`) rather than nested selectors.
- Input tools use CUA-friendly names: `type`, `keypress`, `move`, `drag`, and `wait`.
- Tool failures are returned as MCP soft errors with `isError: true` when possible (MCP 2025-11-25 `CallToolResult`).
- Shell execution through `run` is gated by `MCP_SHELL_COMMANDS_ENABLED`.

## Legacy Context

Earlier design notes described a 77-tool surface that exposed lower-level SDK functions directly. The current production surface intentionally consolidates those operations into the 23 tools above so clients receive a stable, CUA-aligned command model.
