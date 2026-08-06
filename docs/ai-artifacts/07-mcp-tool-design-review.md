# MCP Tool Design Review: Historical Analysis

> **Historical document.** This review was conducted on 2026-02-03 against an
> older 39-tool implementation. It is retained as design history, not as a
> current implementation checklist.

## Current status

The current Go MCP registry exposes **29 CUA-aligned tools** in six groups:

| Group | Count |
|---|---:|
| Core CUA input | 9 |
| Application management | 3 |
| Element interaction | 4 |
| Window management | 4 |
| Utility | 3 |
| Macro management | 6 |

The authoritative current signatures are in
[`skills/macos-use/references/workflows-and-tools.md`](../../skills/macos-use/references/workflows-and-tools.md),
and the registry is implemented in `internal/server/toolregistry.go`.

## Important supersessions

### Screenshot consolidation

The MCP `screenshot` tool accepts an exact display or window resource, or a
region described by `x`, `y`, `width`, and `height`. There are no separate MCP
`capture_window_screenshot` or `capture_region_screenshot` tools. The gRPC
service still exposes the corresponding capture RPCs.

### Coordinate contract

The MCP server passes physical input coordinates through as
**Global Display Coordinates (top-left origin)**. It does not know whether an
MCP host resized a screenshot before presenting it to a model and therefore does
not perform host-specific model-space scaling. A host that resizes images must
convert coordinates back to the global display coordinate system before calling
`click`, `move`, `scroll`, or `drag`.

### Input surface

The current physical tools are `click`, `double_click`, `type`, `keypress`,
`scroll`, `drag`, `move`, and `wait`. `keypress` supports an optional
`hold_duration`; `click_count` is optional and defaults to one. Gesture,
mouse-down/up, `hold_key`, and `use_ime` are not current MCP interfaces.

### Element surface

`find_elements` returns compact text lines containing the element ID, text, and
role. `read_element` combines element detail and action lookup, returning
bounds, enabled/focused state, and available actions. A bare element ID from
`find_elements` requires the discovery `parent` when passed to `read_element`.

### Observation and scripting

Observation RPCs, including `StreamObservations`, remain part of the gRPC
service but are not registered as MCP tools. The MCP scripting surface is the
single `run` tool; shell execution is disabled unless
`MCP_SHELL_COMMANDS_ENABLED=true`. There is no MCP `validate_script` tool.

### Transport

The current proxy supports:

- stdio, the default local transport; and
- Streamable HTTP at `/mcp`, with synchronous JSON responses and bounded
  in-memory sessions.

Successful HTTP `initialize` responses return `MCP-Session-Id`; later requests
require that header. Sessions expire after one hour of inactivity and can be
deleted with `DELETE /mcp`. The proxy does not expose the historical `/message`
and `/events` SSE endpoint pair, heartbeat protocol, or `Last-Event-ID`
reconnection behavior.

HTTP TLS, API-key authentication, rate limiting, CORS origin validation, and
owner-private audit logging are Go proxy features. The Swift gRPC server uses
plaintext transport and should remain on loopback or an owner-private Unix
socket unless a separately secured deployment boundary is provided.

## Verification references

- Tool count and schemas: `internal/server/toolregistry.go`
- HTTP lifecycle and sessions: `internal/transport/http.go`
- Configuration and defaults: `internal/config/config.go`
- Current workflow reference: `skills/macos-use/references/workflows-and-tools.md`
- Current MCP integration notes: `docs/ai-artifacts/05-mcp-integration.md`
