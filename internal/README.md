# Internal Packages

This directory contains unexported implementation packages for the MCP server.

## Package Structure

### `config/`

Configuration loading from environment variables. Handles all MCP server settings including transport, security, and tuning parameters.

```go
cfg, err := config.Load()
```

### `server/`

Core MCP server implementation with 77 tool handlers organized by category:

- **Screenshot** - Screen capture with format/quality options
- **Input** - Mouse, keyboard, drag, scroll operations
- **Element** - Accessibility element queries and actions
- **Window** - Window management (move, resize, minimize, close)
- **Display** - Multi-monitor enumeration and cursor position
- **Clipboard** - Read/write/history management
- **Application** - App lifecycle control
- **Scripting** - AppleScript, JavaScript, shell execution
- **Observation** - Long-running element monitoring
- **Session/Macro** - Stateful automation sequences
- **File Dialog** - Open/save dialog automation

Each tool follows MCP soft-error semantics (isError in ToolResult).

### `server/tools/`

Tool registration utilities and schema definitions.

### `transport/`

MCP transport implementations:

- **stdio** - JSON-RPC 2.0 over stdin/stdout (for Claude Desktop)
- **http** - SSE-based HTTP transport with TLS, API key auth, rate limiting, metrics

## Testing

Each package has comprehensive unit tests in `*_test.go` files:

```sh
# Run all internal package tests
go test -v ./internal/...
```

## Documentation

See [docs/10-api-reference.md](../docs/ai-artifacts/10-api-reference.md) for the complete tool reference.
