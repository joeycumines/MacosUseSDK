# Internal Packages

This directory contains unexported implementation packages for the MCP server.

## Package Structure

### `config/`

Configuration loading from environment variables. Handles all MCP server settings including transport, security, and tuning parameters.

```go
cfg, err := config.Load()
```

### `server/`

Core MCP server implementation with 29 CUA-aligned tool handlers organized by category:

- **Core CUA Input** - `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait`
- **Application** - `open_app`, `list_apps`, `close_app`
- **Element** - `find_elements`, `click_element`, `type_element`, `read_element`
- **Window** - `focus_window`, `move_window`, `resize_window`, `list_windows`
- **Utility** - `clipboard`, `run`, `get_display`
- **Macros** - `create_macro`, `get_macro`, `list_macros`, `update_macro`, `delete_macro`, `execute_macro`

Each tool follows MCP soft-error semantics (isError in ToolResult).

### `server/tools/`

Tool registration utilities and schema definitions.

### `transport/`

MCP transport implementations:

- **stdio** - JSON-RPC 2.0 over stdin/stdout (for Claude Desktop)
- **streamable-http** - synchronous JSON responses at `/mcp` with TLS, API key auth, rate limiting, metrics, and bounded sessions

## Testing

Each package has comprehensive unit tests in `*_test.go` files:

```sh
# Run all internal package tests
go test -v ./internal/...
```

## Documentation

See [the MCP tool reference](../skills/exactmac/references/workflows-and-tools.md) for the complete current tool reference.
