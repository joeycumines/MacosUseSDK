# MCP Tool Design for MacosUseSDK

## Overview

This document describes the design of an MCP (Model Context Protocol) tool for standard output integration with the MacosUseSDK Go API. The MCP tool provides a JSON-RPC 2.0 interface over stdin/stdout for AI assistants to interact with the macOS automation capabilities.

## Architecture

### Component Structure

```
MCP Tool (Go executable)
├── stdin/stdout JSON-RPC 2.0 communication
├── gRPC client connection to MacosUseServer
└── Tool definitions and handlers
```

### Communication Protocol

The MCP tool uses JSON-RPC 2.0 over stdio:
- **Request format**: `{"jsonrpc": "2.0", "id": <number>, "method": "<method>", "params": <object>}`
- **Response format**: `{"jsonrpc": "2.0", "id": <number>, "result": <object>}` or `{"jsonrpc": "2.0", "id": <number>, "error": <object>}`
- **Notification format**: `{"jsonrpc": "2.0", "method": "<method>", "params": <object>}`

### MCP Methods

#### Server Lifecycle
- `initialize`: Handshake and capability negotiation
- `notifications/initialized`: Server ready notification
- `shutdown`: Graceful shutdown request
- `exit`: Exit the server

#### Tool Discovery
- `tools/list`: List available tools
- `tools/call`: Execute a tool

### Available Tools

The MCP tool exposes the following categories of operations:

#### Application Management
- `open_application`: Open or activate an application
- `get_application`: Get a specific application
- `list_applications`: List tracked applications
- `delete_application`: Stop tracking an application

#### Window Operations
- `get_window`: Get a specific window
- `list_windows`: List windows for an application
- `focus_window`: Focus a specific window
- `move_window`: Move a window to a new position
- `resize_window`: Resize a window
- `minimize_window`: Minimize a window
- `restore_window`: Restore a minimized window
- `close_window`: Close a window

#### Element Operations
- `find_elements`: Find elements matching a selector
- `find_region_elements`: Find elements within a screen region
- `get_element`: Get a specific element
- `click_element`: Click an element
- `write_element_value`: Write an element's value
- `perform_element_action`: Perform an accessibility action

#### Display Operations
- `list_displays`: List all displays
- `get_display`: Get a specific display

#### Clipboard Operations
- `get_clipboard`: Get clipboard contents
- `write_clipboard`: Write clipboard contents
- `clear_clipboard`: Clear clipboard contents
- `get_clipboard_history`: Get clipboard history

#### Input Operations
- `create_input`: Create an input action
- `list_inputs`: List inputs

#### Observation Operations
- `create_observation`: Create an observation
- `get_observation`: Get an observation
- `list_observations`: List observations
- `cancel_observation`: Cancel an observation

#### Scripting Operations
- `execute_apple_script`: Execute AppleScript
- `execute_javascript`: Execute JavaScript for Automation
- `execute_shell_command`: Execute a shell command
- `validate_script`: Validate a script

#### Screenshot Operations
- `capture_screenshot`: Capture a full screen screenshot
- `capture_window_screenshot`: Capture a window screenshot
- `capture_element_screenshot`: Capture an element screenshot
- `capture_region_screenshot`: Capture a region screenshot

#### Session Operations
- `create_session`: Create a session
- `get_session`: Get a session
- `list_sessions`: List sessions
- `delete_session`: Delete a session

#### Macro Operations
- `create_macro`: Create a macro
- `get_macro`: Get a macro
- `list_macros`: List macros
- `execute_macro`: Execute a macro

### Tool Parameters Schema

Each tool follows a consistent parameter schema:

```json
{
  "type": "object",
  "properties": {
    "application": {
      "type": "string",
      "description": "Application ID, bundle ID, or path"
    },
    "window": {
      "type": "string",
      "description": "Window resource name"
    },
    "element": {
      "type": "string",
      "description": "Element ID or selector"
    },
    // ... tool-specific parameters
  },
  "required": ["application"]
}
```

### Error Handling

Errors follow JSON-RPC 2.0 error codes:
- `-32600`: Invalid Request
- `-32601`: Method Not Found
- `-32602`: Invalid Params
- `-32603`: Internal Error
- `-32000`: Server Error (custom, for gRPC errors)

### Configuration

Environment variables:
- `MACOS_USE_SERVER_ADDR`: gRPC server address (default: `localhost:50051`)
- `MACOS_USE_SERVER_TLS`: Use TLS for gRPC (default: false)

## Implementation Plan

### Phase 1: Core Infrastructure
1. Create MCP tool package structure
2. Implement JSON-RPC 2.0 transport over stdio
3. Implement server lifecycle methods (initialize, shutdown)

### Phase 2: Tool Definitions
1. Define tool schemas for each operation
2. Implement tool registration system
3. Implement `tools/list` method

### Phase 3: gRPC Integration
1. Create gRPC client connection manager
2. Implement request/response mapping
3. Implement error handling and conversion

### Phase 4: Tool Handlers
1. Implement application management handlers
2. Implement window operations handlers
3. Implement element operations handlers
4. Implement remaining operation handlers

### Phase 5: Testing
1. Write unit tests for core functionality
2. Write integration tests with the server
3. Test MCP protocol compliance

## File Structure

```
cmd/mcp-tool/
└── main.go

internal/
├── transport/
│   └── stdio.go          # JSON-RPC 2.0 over stdio
├── server/
│   └── mcp.go            # MCP server implementation
├── tools/
│   ├── registry.go       # Tool registry
│   ├── definitions.go    # Tool schemas
│   └── handlers/         # Tool handlers
│       ├── application.go
│       ├── window.go
│       ├── element.go
│       ├── display.go
│       ├── clipboard.go
│       ├── input.go
│       ├── observation.go
│       ├── scripting.go
│       ├── screenshot.go
│       ├── session.go
│       └── macro.go
└── config/
    └── config.go         # Configuration

mcp_tool_test.go          # Integration tests
```

## Example Usage

### Starting the MCP Tool

```bash
# Start with default settings
./mcp-tool

# Start with custom server address
MACOS_USE_SERVER_ADDR=localhost:50052 ./mcp-tool
```

### Example MCP Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "list_applications",
    "arguments": {}
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
        "type": "text",
        "text": "Found 2 applications:\\n- Calculator (applications/1)\\n- TextEdit (applications/2)"
      }
    ]
  }
}
```

## Security Considerations

1. **Input Validation**: All tool parameters are validated before being sent to the gRPC server
2. **Resource Limits**: Timeouts and limits are enforced on all operations
3. **Sandboxing**: The tool runs with the same permissions as the user

## Compatibility

- Go 1.21+
- MacOS 12.0+ (for full accessibility support)
- MCP Protocol 2024-11-05
