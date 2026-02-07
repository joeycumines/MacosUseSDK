# MCP Tool Design for MacosUseSDK

## Overview

This document describes the design of the MCP (Model Context Protocol) server for macOS automation. The MCP server provides a JSON-RPC 2.0 interface for AI assistants to interact with macOS via screen capture, input simulation, accessibility APIs, and scripting.

**Status:** 77 tools implemented and operational.

## Architecture

### Component Structure

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
│   ├── pb.MacosUseClient (primary operations)
│   └── longrunningpb.OperationsClient (async operations)
└── Tool Handlers (77 tools)
    ├── internal/server/mcp.go (registry + lifecycle)
    ├── internal/server/screenshot.go
    ├── internal/server/input.go
    ├── internal/server/element.go
    ├── internal/server/window.go
    ├── internal/server/display.go
    ├── internal/server/clipboard.go
    ├── internal/server/application.go
    ├── internal/server/scripting.go
    ├── internal/server/observation.go
    ├── internal/server/session.go
    └── internal/server/file.go
```

### Communication Protocol

The MCP server supports two transport modes:

**Stdio Transport (default):**
- Request: `{"jsonrpc": "2.0", "id": <number>, "method": "<method>", "params": <object>}`
- Response: `{"jsonrpc": "2.0", "id": <number>, "result": <object>}` or `{"jsonrpc": "2.0", "id": <number>, "error": <object>}`

**HTTP/SSE Transport:**
- POST `/message`: Submit JSON-RPC requests
- GET `/events`: Server-Sent Events stream
- GET `/health`: Health check
- GET `/metrics`: Prometheus metrics

### MCP Methods

#### Server Lifecycle
- `initialize`: Handshake and capability negotiation (returns display grounding info)
- `notifications/initialized`: Client acknowledgment notification
- `shutdown`: Graceful shutdown request
- `exit`: Exit the server

#### Tool Discovery
- `tools/list`: List available tools (77 tools)
- `tools/call`: Execute a tool

## Implemented Tools (77 Total)

### Screenshot Operations (4 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `capture_screenshot` | Capture full screen screenshot | `format`, `quality`, `display`, `include_ocr`, `max_width`, `max_height` |
| `capture_window_screenshot` | Capture a specific window | `window`, `format`, `include_shadow`, `include_ocr` |
| `capture_region_screenshot` | Capture a screen region | `x`, `y`, `width`, `height`, `format`, `include_ocr` |
| `capture_element_screenshot` | Capture a UI element | `parent`, `element_id`, `format`, `padding`, `include_ocr` |

### Input Operations (11 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `click` | Click at screen coordinates | `x`, `y`, `button`, `click_count`, `show_animation` |
| `type_text` | Type text as keyboard input | `text`, `char_delay`, `use_ime` |
| `press_key` | Press a key combination | `key`, `modifiers` |
| `hold_key` | Hold a key for a duration | `key`, `duration`, `modifiers` |
| `mouse_move` | Move mouse cursor | `x`, `y`, `duration` |
| `scroll` | Scroll content | `x`, `y`, `horizontal`, `vertical`, `duration` |
| `drag` | Drag from one point to another | `start_x`, `start_y`, `end_x`, `end_y`, `duration` |
| `mouse_button_down` | Press mouse button without release | `x`, `y`, `button`, `modifiers` |
| `mouse_button_up` | Release mouse button | `x`, `y`, `button`, `modifiers` |
| `hover` | Hover at position | `x`, `y`, `duration`, `application` |
| `gesture` | Multi-touch gesture | `center_x`, `center_y`, `gesture_type`, `scale`, `rotation`, `direction` |

### Element Operations (6 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `find_elements` | Find UI elements by criteria | `parent`, `selector` |
| `get_element` | Get element details | `name` |
| `get_element_actions` | Get available actions | `name` |
| `click_element` | Click on an element | `parent`, `element_id` |
| `write_element_value` | Set element value | `parent`, `element_id`, `value` |
| `perform_element_action` | Perform accessibility action | `parent`, `element_id`, `action` |

### Window Operations (8 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `list_windows` | List open windows | `parent`, `page_size`, `page_token` |
| `get_window` | Get window details | `name` |
| `focus_window` | Focus a window | `name` |
| `move_window` | Move a window | `name`, `x`, `y` |
| `resize_window` | Resize a window | `name`, `width`, `height` |
| `minimize_window` | Minimize a window | `name` |
| `restore_window` | Restore minimized window | `name` |
| `close_window` | Close a window | `name`, `force` |

### Display Operations (3 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `list_displays` | List connected displays | _(none)_ |
| `get_display` | Get display details | `name` |
| `cursor_position` | Get current cursor position | _(none)_ |

### Clipboard Operations (4 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_clipboard` | Get clipboard contents | _(none)_ |
| `write_clipboard` | Write to clipboard | `text` |
| `clear_clipboard` | Clear clipboard | _(none)_ |
| `get_clipboard_history` | Get clipboard history | _(none)_ |

### Application Operations (4 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `open_application` | Open an application | `id` |
| `list_applications` | List tracked applications | `page_size`, `page_token` |
| `get_application` | Get application details | `name` |
| `delete_application` | Stop tracking application | `name` |

### Scripting Operations (5 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `execute_apple_script` | Execute AppleScript | `script`, `timeout` |
| `execute_javascript` | Execute JXA script | `script`, `timeout` |
| `execute_shell_command` | Execute shell command | `command`, `args`, `timeout` |
| `validate_script` | Validate script syntax | `type`, `script` |
| `get_scripting_dictionaries` | Get AppleScript dictionaries | `name` |

### Observation Operations (5 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_observation` | Create UI observation | `parent`, `type`, `poll_interval`, `visible_only`, `roles` |
| `stream_observations` | Stream observation events | `name`, `timeout` |
| `get_observation` | Get observation status | `name` |
| `list_observations` | List observations | `parent` |
| `cancel_observation` | Cancel an observation | `name` |

### Accessibility Operations (6 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `traverse_accessibility` | Traverse accessibility tree | `name`, `visible_only` |
| `get_window_state` | Get window accessibility state | `name` |
| `find_region_elements` | Find elements in region | `parent`, `x`, `y`, `width`, `height` |
| `wait_element` | Wait for element to appear | `parent`, `selector`, `timeout`, `poll_interval` |
| `wait_element_state` | Wait for element state | `parent`, `element_id`, `condition`, `value`, `timeout` |
| `watch_accessibility` | Watch accessibility changes | `name`, `poll_interval`, `visible_only` |

### File Dialog Operations (5 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `automate_open_file_dialog` | Automate open file dialog | `application`, `file_path`, `default_directory` |
| `automate_save_file_dialog` | Automate save file dialog | `application`, `file_path`, `default_filename` |
| `select_file` | Select a file | `application`, `file_path`, `reveal_finder` |
| `select_directory` | Select a directory | `application`, `directory_path`, `create_missing` |
| `drag_files` | Drag and drop files | `application`, `file_paths`, `target_element_id` |

### Session Operations (8 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_session` | Create a session | `session_id`, `display_name`, `metadata` |
| `get_session` | Get session details | `name` |
| `list_sessions` | List sessions | `page_size`, `page_token` |
| `delete_session` | Delete a session | `name`, `force` |
| `get_session_snapshot` | Get session snapshot | `name` |
| `begin_transaction` | Begin a transaction | `session` |
| `commit_transaction` | Commit a transaction | `name`, `transaction_id` |
| `rollback_transaction` | Rollback a transaction | `name`, `transaction_id`, `revision_id` |

### Macro Operations (6 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `create_macro` | Create a macro | `macro_id`, `display_name`, `description`, `tags` |
| `get_macro` | Get macro details | `name` |
| `list_macros` | List macros | `page_size`, `page_token` |
| `delete_macro` | Delete a macro | `name` |
| `execute_macro` | Execute a macro | `macro`, `parameter_values` |
| `update_macro` | Update macro metadata | `name`, `display_name`, `description`, `tags` |

### Input Query Operations (2 tools)
| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `get_input` | Get input action details | `name` |
| `list_inputs` | List input history | `parent`, `page_size`, `page_token`, `filter` |

## Coordinate Scaling

**Important:** The MCP server expects coordinates in **native pixel values** as reported by the display grounding information. MCP hosts that resize screenshots (e.g., to fit model context windows) **must** upscale predicted coordinates back to native resolution before sending to this server.

For multi-monitor setups:
- Use `screens[].origin_x` and `screens[].origin_y` to translate between display-local and global coordinates
- Secondary displays may have negative origin coordinates
- The `pixel_density` field indicates Retina scaling (2.0 = @2x, 1.0 = @1x)

## Error Handling

### Soft Failures (is_error pattern)

Tool handlers return soft failures via the `is_error` field in the ToolResult:
- Non-blocking errors (e.g., element not found) return `is_error: true` with descriptive text
- Client can decide how to proceed based on the error message
- This follows MCP conventions for tool error reporting

## Display Grounding

The `initialize` response includes display grounding information for coordinate-based operations. The format follows the MCP computer tool specification:

```json
{
  "protocolVersion": "2025-11-25",
  "capabilities": {"tools": {}},
  "serverInfo": {"name": "macos-use-sdk", "version": "0.1.0"},
  "displayInfo": {
    "screens": [
      {
        "id": "main",
        "width": 2560,
        "height": 1440,
        "pixel_density": 2,
        "origin_x": 0,
        "origin_y": 0
      }
    ]
  }
}
```

## Configuration

### Core Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MACOS_USE_SERVER_ADDR` | gRPC server address | `localhost:50051` |
| `MACOS_USE_SERVER_TLS` | Enable TLS for gRPC | `false` |
| `MACOS_USE_SERVER_CERT_FILE` | Path to server TLS certificate | _(none)_ |
| `MACOS_USE_REQUEST_TIMEOUT` | gRPC request timeout in seconds | `30` |
| `MACOS_USE_DEBUG` | Enable debug logging | `false` |

### Transport Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TRANSPORT` | Transport type: `stdio` or `sse` | `stdio` |
| `MCP_HTTP_ADDRESS` | HTTP/SSE listen address | `:8080` |
| `MCP_HTTP_SOCKET` | Unix socket path for HTTP | _(none)_ |
| `MCP_CORS_ORIGIN` | CORS allowed origin | `*` |
| `MCP_HEARTBEAT_INTERVAL` | SSE heartbeat interval | `30s` |
| `MCP_HTTP_READ_TIMEOUT` | HTTP read timeout | `30s` |
| `MCP_HTTP_WRITE_TIMEOUT` | HTTP write timeout | `30s` |

### Security Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TLS_CERT_FILE` | Path to TLS certificate for HTTPS | _(none)_ |
| `MCP_TLS_KEY_FILE` | Path to TLS private key for HTTPS | _(none)_ |
| `MCP_API_KEY` | API key for authentication | _(none)_ |
| `MCP_SHELL_COMMANDS_ENABLED` | Enable shell command execution | `false` |

### Observability Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_RATE_LIMIT` | Rate limit in requests/second | `0` (disabled) |
| `MCP_AUDIT_LOG_FILE` | Path to audit log file | _(none)_ |

## File Structure

```
cmd/macos-use-mcp/
└── main.go

internal/
├── transport/
│   ├── stdio.go          # JSON-RPC 2.0 over stdio
│   ├── http.go           # HTTP/SSE transport
│   ├── metrics.go        # Prometheus metrics
│   └── ratelimit.go      # Token bucket rate limiter
├── server/
│   ├── mcp.go            # MCP server + tool registry
│   ├── audit.go          # Structured audit logging
│   ├── screenshot.go     # Screenshot handlers
│   ├── input.go          # Input handlers
│   ├── element.go        # Element handlers
│   ├── window.go         # Window handlers
│   ├── display.go        # Display handlers
│   ├── clipboard.go      # Clipboard handlers
│   ├── application.go    # Application handlers
│   ├── scripting.go      # Scripting handlers
│   ├── observation.go    # Observation handlers
│   ├── session.go        # Session/transaction handlers
│   └── file.go           # File dialog handlers
└── config/
    └── config.go         # Configuration

integration/                # Integration tests
```

## Example Usage

### Starting with Stdio Transport (Default)

```bash
# Start with default configuration
./macos-use-mcp

# Start with custom gRPC address
MACOS_USE_SERVER_ADDR=localhost:50052 ./macos-use-mcp
```

### Starting with HTTP/SSE Transport

```bash
# Enable HTTP transport on port 8080
MCP_TRANSPORT=sse MCP_HTTP_ADDRESS=:8080 ./macos-use-mcp

# With TLS and authentication
MCP_TRANSPORT=sse \
  MCP_TLS_CERT_FILE=/path/to/cert.pem \
  MCP_TLS_KEY_FILE=/path/to/key.pem \
  MCP_API_KEY=your-secret-key \
  ./macos-use-mcp
```

### Example MCP Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "capture_screenshot",
    "arguments": {
      "max_width": 1280,
      "include_ocr": true
    }
  }
}
```

### Example Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "image",
        "data": "base64-encoded-png...",
        "mimeType": "image/png"
      },
      {
        "type": "text",
        "text": "OCR text extracted from screenshot..."
      }
    ]
  }
}
```

## Compatibility

- Go 1.21+
- macOS 12.0+ (for full accessibility support)
- MCP Protocol 2025-11-25
