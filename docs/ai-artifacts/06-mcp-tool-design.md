# MCP Tool Design for ExactMac

## Overview

This document describes the redesigned MCP (Model Context Protocol) server surface for macOS automation. The Go MCP proxy exposes 29 CUA-aligned tools backed by the consolidated `ExactMac` gRPC service.

**Status:** 29 tools implemented and operational in `internal/server/toolregistry.go` (registered by `registerTools`).

## Architecture

```
MCP Server (Go executable)
├── Transport Layer
│   ├── Stdio (stdin/stdout JSON-RPC 2.0)
│   └── Streamable HTTP (no standalone SSE)
├── Observability
│   ├── /metrics endpoint (Prometheus format)
│   ├── Audit logging (structured JSON)
│   └── Rate limiting (token bucket)
├── Security
│   ├── TLS termination
│   └── API key authentication
├── gRPC Client Connection
│   └── pb.ExactMacClient
└── Tool Registry
    └── internal/server/toolregistry.go
```

## Tool Categories

| Category | Tools |
|----------|-------|
| Core CUA Input | `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait` |
| Application Management | `open_app`, `list_apps`, `close_app` |
| Element Interaction | `find_elements`, `click_element`, `type_element`, `read_element` |
| Window Management | `focus_window`, `move_window`, `resize_window`, `list_windows` |
| Utility | `clipboard`, `run`, `get_display` |
| Macros | `create_macro`, `get_macro`, `list_macros`, `update_macro`, `delete_macro`, `execute_macro` |

## Design Notes

- Coordinate fields use **Global Display Coordinates (top-left origin)**.
- `find_elements` and `list_windows` accept `page_size` and `page_token`; returned page tokens are opaque.
- Accessibility element tools take `parent` plus one `key:value` `selector` string (e.g. `role:AXButton`) or a parent-bound element handle; selectors must resolve uniquely.
- Input tools use CUA-friendly names: `type`, `keypress`, `move`, `drag`, and `wait`.
- Tool failures are returned as MCP soft errors with `isError: true` when possible (MCP 2025-11-25 `CallToolResult`).
- Shell execution through `run` is gated by `MCP_SHELL_COMMANDS_ENABLED`.

## Legacy Context

Earlier design notes described a 76-tool surface (see the 0.1.0 inventory in CHANGELOG.md) that exposed lower-level SDK functions directly. The production surface first consolidated those operations into 23 tools, then added the 6 macro tools, for the current 29-tool CUA-aligned command model.
