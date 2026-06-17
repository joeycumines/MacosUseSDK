# Internal Packages

This directory contains unexported implementation packages for the MCP server.

## Package Structure

### `config/`

Configuration loading from environment variables. Handles all MCP server settings including transport, security, and tuning parameters.

```go
cfg, err := config.Load()
```

### `server/`

Core MCP server implementation with 23 redesigned CUA-aligned tool handlers organized by category:

- **Core CUA Input** - `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait`
- **Application** - `open_app`, `list_apps`, `close_app`
- **Element** - `find_elements`, `click_element`, `type_element`, `read_element`
- **Window** - `focus_window`, `move_window`, `resize_window`, `list_windows`
- **Utility** - `clipboard`, `run`, `get_display`

Each tool follows MCP soft-error semantics (isError in ToolResult).

### `server/tools/`

Tool registration utilities and schema definitions.

### `transport/`

MCP transport implementations:

- **stdio** - JSON-RPC 2.0 over stdin/stdout (for Claude Desktop)
- **sse** - SSE-based HTTP transport with TLS, API key auth, rate limiting, metrics

## Testing

Each package has comprehensive unit tests in `*_test.go` files:

```sh
# Run all internal package tests
go test -v ./internal/...
```

## Documentation

See [docs/10-api-reference.md](../docs/ai-artifacts/10-api-reference.md) for the complete tool reference.
