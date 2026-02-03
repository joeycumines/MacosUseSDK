# MCP Tool Design for MacosUseSDK

## Overview

This document describes the design of an MCP (Model Context Protocol) tool for standard output integration with the MacosUseSDK Go API. The MCP tool provides a JSON-RPC 2.0 interface over stdin/stdout for AI assistants to interact with the macOS automation capabilities.

**Status:** 47 tools implemented and operational.

## Architecture

### Component Structure

```
MCP Tool (Go executable)
├── stdin/stdout JSON-RPC 2.0 communication
├── gRPC client connection to MacosUseServer
│   ├── pb.MacosUseClient (primary operations)
│   └── longrunningpb.OperationsClient (async operations)
└── Tool definitions and handlers
    ├── internal/server/mcp.go (registry + lifecycle)
    ├── internal/server/screenshot.go
    ├── internal/server/input.go
    ├── internal/server/element.go
    ├── internal/server/window.go
    ├── internal/server/display.go
    ├── internal/server/clipboard.go
    ├── internal/server/application.go
    ├── internal/server/scripting.go
    └── internal/server/observation.go
```

### Communication Protocol

The MCP tool uses JSON-RPC 2.0 over stdio:
- **Request format**: `{"jsonrpc": "2.0", "id": <number>, "method": "<method>", "params": <object>}`
- **Response format**: `{"jsonrpc": "2.0", "id": <number>, "result": <object>}` or `{"jsonrpc": "2.0", "id": <number>, "error": <object>}`
- **Notification format**: `{"jsonrpc": "2.0", "method": "<method>", "params": <object>}`

### MCP Methods

#### Server Lifecycle
- `initialize`: Handshake and capability negotiation (returns display grounding info)
- `notifications/initialized`: Server ready notification _(not yet implemented)_
- `shutdown`: Graceful shutdown request _(not yet implemented)_
- `exit`: Exit the server _(not yet implemented)_

#### Tool Discovery
- `tools/list`: List available tools (47 tools)
- `tools/call`: Execute a tool

## Implemented Tools (47 Total)

### Screenshot Operations (3 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `capture_screenshot` | Capture full screen or window screenshot | `display_id`, `window_id`, `format`, `include_ocr`, `max_width`, `max_height` |
| `capture_region_screenshot` | Capture a region screenshot | `x`, `y`, `width`, `height`, `display_id`, `format`, `include_ocr` |
| `capture_window_screenshot` | Capture a specific window screenshot | `window`, `format`, `quality`, `include_shadow`, `include_ocr` |

### Input Operations (8 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `click` | Click at screen coordinates | `x`, `y`, `button`, `click_count`, `show_animation` |
| `type_text` | Type text (with optional modifiers) | `text`, `modifiers` |
| `press_key` | Press a key combination | `key`, `modifiers` |
| `mouse_move` | Move mouse to coordinates | `x`, `y`, `smooth`, `duration_ms` |
| `scroll` | Scroll at coordinates | `x`, `y`, `delta_x`, `delta_y` |
| `drag` | Drag from one point to another | `start_x`, `start_y`, `end_x`, `end_y`, `duration_ms` |
| `hover` | Hover at position for duration | `x`, `y`, `duration` |
| `gesture` | Multi-touch gesture (trackpad) | `center_x`, `center_y`, `gesture_type`, `scale`, `rotation`, `finger_count`, `direction` |

### Element Operations (6 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `find_elements` | Find elements matching selector | `parent`, `role`, `title`, `identifier`, `page_size`, `page_token` |
| `get_element` | Get a specific element | `parent`, `element_id` |
| `get_element_actions` | Get available actions for an element | `parent`, `element_id` |
| `click_element` | Click an element | `parent`, `element_id` |
| `write_element_value` | Write value to an element | `parent`, `element_id`, `value` |
| `perform_element_action` | Perform accessibility action | `parent`, `element_id`, `action` |

### Window Operations (8 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `list_windows` | List windows | `parent`, `page_size`, `page_token` |
| `get_window` | Get a specific window | `name` |
| `focus_window` | Focus a window | `name` |
| `move_window` | Move a window | `name`, `x`, `y` |
| `resize_window` | Resize a window | `name`, `width`, `height` |
| `minimize_window` | Minimize a window | `name` |
| `restore_window` | Restore a minimized window | `name` |
| `close_window` | Close a window | `name` |

### Display Operations (2 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `list_displays` | List all displays | `page_size`, `page_token` |
| `get_display` | Get a specific display | `name` |

### Clipboard Operations (4 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `get_clipboard` | Get clipboard contents | _(none)_ |
| `write_clipboard` | Write to clipboard | `text`, `type` |
| `clear_clipboard` | Clear clipboard contents | _(none)_ |
| `get_clipboard_history` | Get clipboard history | `limit`, `offset` |

### Application Operations (4 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `open_application` | Open or activate an application | `application_id` |
| `list_applications` | List tracked applications | `page_size`, `page_token` |
| `get_application` | Get a specific application | `name` |
| `delete_application` | Stop tracking an application | `name` |

### Scripting Operations (4 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `execute_apple_script` | Execute AppleScript | `script`, `timeout`, `compile_only` |
| `execute_javascript` | Execute JavaScript for Automation | `script`, `timeout`, `compile_only` |
| `execute_shell_command` | Execute a shell command | `command`, `args`, `working_directory`, `environment`, `timeout`, `stdin`, `shell` |
| `validate_script` | Validate a script without executing | `script`, `type`, `compile_only` |

### Observation Operations (5 tools)
| Tool | Description | Parameters |
|------|-------------|------------|
| `create_observation` | Create an observation | `parent`, `type`, `poll_interval_ms`, `visible_only`, `roles`, `attributes` |
| `stream_observations` | Stream observation updates | `parent`, `types`, `roles`, `attributes`, `poll_interval_ms` |
| `get_observation` | Get observation state | `name` |
| `list_observations` | List observations | `parent`, `page_size`, `page_token` |
| `cancel_observation` | Cancel an observation | `name` |

## Session Operations (deferred)
- `create_session`, `get_session`, `list_sessions`, `delete_session`

## Macro Operations (deferred)
- `create_macro`, `get_macro`, `list_macros`, `execute_macro`

## Blocked by Proto Limitations

The following actions from docs/05-mcp-integration.md are not implementable without proto schema changes:

### Input Operations (requires proto changes)
- `cursor_position`: Get current mouse cursor position. Requires new `GetCursorPosition` RPC.
- `left_mouse_down` / `left_mouse_up`: Stateful mouse button events for complex gestures. Proto only supports atomic click/drag operations.
- `hold_key`: Hold a modifier key for a duration. Requires `duration` field in `KeyPress` message.

### Screenshot Operations (partially covered)
- `zoom(coordinate, scale)`: High-res crop with scale factor. Functionally similar to `capture_region_screenshot` which captures a rectangular region. The "zoom" concept of preserving 1:1 pixel density is implicit when requesting a small region.

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
  "protocolVersion": "2024-11-05",
  "capabilities": {"tools": {}},
  "serverInfo": {"name": "macos-use-sdk", "version": "0.1.0"},
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
```

## Configuration

Environment variables:
- `MACOS_USE_SERVER_SOCKET`: Unix socket path (default: `/tmp/macos_use_server.sock`)
- `MACOS_USE_SERVER_ADDR`: gRPC server address (alternative to socket)

## File Structure

```
cmd/mcp-tool/
└── main.go

internal/
├── transport/
│   └── stdio.go          # JSON-RPC 2.0 over stdio
├── server/
│   ├── mcp.go            # MCP server + tool registry
│   ├── screenshot.go     # Screenshot handlers
│   ├── input.go          # Input handlers
│   ├── element.go        # Element handlers
│   ├── window.go         # Window handlers
│   ├── display.go        # Display handlers
│   ├── clipboard.go      # Clipboard handlers
│   ├── application.go    # Application handlers
│   ├── scripting.go      # Scripting handlers
│   └── observation.go    # Observation handlers
└── config/
    └── config.go         # Configuration

integration/                # Integration tests
```

## Example Usage

### Starting the MCP Tool

```bash
# Start with default socket
./mcp-tool

# Start with custom socket path
MACOS_USE_SERVER_SOCKET=/tmp/custom.sock ./mcp-tool
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
- MCP Protocol 2024-11-05
