# API Reference

> **Version:** 1.0.0-beta  
> **Protocol:** MCP 2025-11-25  
> **Last Updated:** 2026-02-04
>
> _Note: This API is under active development. Version follows [SemVer](https://semver.org/).
> The version will be promoted to 1.0.0 stable once the API surface is finalized and all
> integration tests pass consistently._

This document provides a comprehensive API reference for MacosUseSDK, covering all 77 MCP tools, 18 environment variables, coordinate systems, and error codes.

---

## Table of Contents

1. [Coordinate System Reference](#1-coordinate-system-reference)
2. [MCP Tools Reference](#2-mcp-tools-reference)
   - [Screenshot Tools](#21-screenshot-tools)
   - [Input Tools](#22-input-tools)
   - [Element Tools](#23-element-tools)
   - [Window Tools](#24-window-tools)
   - [Display Tools](#25-display-tools)
   - [Clipboard Tools](#26-clipboard-tools)
   - [Application Tools](#27-application-tools)
   - [Scripting Tools](#28-scripting-tools)
   - [Observation Tools](#29-observation-tools)
   - [Accessibility Tools](#210-accessibility-tools)
   - [File Dialog Tools](#211-file-dialog-tools)
   - [Session Tools](#212-session-tools)
   - [Macro Tools](#213-macro-tools)
   - [Input Query Tools](#214-input-query-tools)
3. [Environment Variable Reference](#3-environment-variable-reference)
4. [Error Code Reference](#4-error-code-reference)
5. [Resource Naming Conventions](#5-resource-naming-conventions)

---

## 1. Coordinate System Reference

macOS uses **multiple coordinate systems**. Understanding which system applies to each API is critical for correct operation.

### 1.1 Global Display Coordinates (Top-Left Origin)

Used by: CGWindowList, Accessibility APIs (AX), CGEvent, all MCP tools.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GLOBAL COORDINATE SPACE                       │
│                                                                      │
│    Secondary Display              Main Display (Primary)             │
│    ┌─────────────────┐           ┌─────────────────────────┐        │
│    │ (-1920, 0)      │           │ (0, 0) ◄── ORIGIN       │        │
│    │ ●───────────────┤           │ ●───────────────────────┤        │
│    │ │               │           │ │                       │        │
│    │ │   Display 2   │           │ │      Display 1        │        │
│    │ │   1920×1080   │           │ │      2560×1440        │        │
│    │ │               │           │ │                       │        │
│    │ │               │           │ │                       │        │
│    │ │               │           │ │                       │        │
│    │ └───────────────┼───────────┼─┴───────────────────────┤        │
│    │ (-1920, 1080)   │           │ (2560, 1440)            │        │
│    └─────────────────┘           └─────────────────────────┘        │
│                                                                      │
│    Display Below Main                                               │
│           ┌─────────────────┐                                       │
│           │ (0, 1440)       │                                       │
│           │ ●───────────────┤                                       │
│           │ │   Display 3   │                                       │
│           │ │   1920×1080   │                                       │
│           │ └───────────────┤                                       │
│           │ (1920, 2520)    │                                       │
│           └─────────────────┘                                       │
│                                                                      │
│   Y increases DOWNWARD ↓                                            │
│   X increases RIGHTWARD →                                           │
│   Negative X = left of main display                                 │
│   Negative Y = above main display                                   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Points:**
- Origin `(0, 0)` is at the **top-left corner of the main display**
- Y-axis increases **downward**
- Secondary displays can have **negative coordinates**
- All window bounds from `list_windows`/`get_window` use this system
- All input coordinates (`click`, `mouse_move`, `drag`) use this system
- **No conversion needed** between window bounds and input positions

### 1.2 AppKit Coordinates (Bottom-Left Origin)

Used by: NSWindow, NSScreen.frame (internal macOS APIs, not exposed via MCP).

```
┌─────────────────────────────────────────────────────────────────────┐
│   AppKit Coordinate System (Internal - NOT used by MCP tools)       │
│                                                                      │
│    Main Display                                                     │
│    ┌─────────────────────────┐                                      │
│    │ (0, 1440)               │ (2560, 1440)                         │
│    │ ├───────────────────────┤                                      │
│    │ │                       │                                      │
│    │ │                       │   Y increases UPWARD ↑               │
│    │ │                       │                                      │
│    │ │                       │                                      │
│    │ ●───────────────────────┤                                      │
│    │ (0, 0) ◄── ORIGIN       │ (2560, 0)                            │
│    └─────────────────────────┘                                      │
└─────────────────────────────────────────────────────────────────────┘
```

> **Note:** MCP clients do **not** need to handle AppKit coordinates. All MCP APIs use Global Display Coordinates consistently.

### 1.3 Coordinate Conversion Formula

If you ever need to convert between systems (e.g., debugging with NSWindow values):

```
globalY = mainDisplayHeight - appKitY - windowHeight
appKitY = mainDisplayHeight - globalY - windowHeight
```

---

## 2. MCP Tools Reference

MacosUseSDK exposes **77 MCP tools** organized into 14 categories.

### 2.1 Screenshot Tools

| Tool | Description |
|------|-------------|
| `capture_screenshot` | Capture full screen screenshot |
| `capture_window_screenshot` | Capture screenshot of specific window |
| `capture_region_screenshot` | Capture screenshot of screen region |

#### capture_screenshot

Capture a full screen screenshot. Returns base64-encoded image data.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `format` | string | No | Image format: `png`, `jpeg`, `tiff`. Default: `png` |
| `quality` | integer | No | JPEG quality (1-100). Default: 85 |
| `display` | integer | No | Display index for multi-monitor. Default: 0 (main) |
| `include_ocr` | boolean | No | Include OCR text extraction |
| `max_width` | integer | No | Max width for resize (token efficiency). 0 = no resize |
| `max_height` | integer | No | Max height for resize (token efficiency). 0 = no resize |

**Returns:** Base64-encoded image data.

**Example:**
```json
{
  "name": "capture_screenshot",
  "arguments": {
    "format": "jpeg",
    "quality": 80,
    "max_width": 1568
  }
}
```

#### capture_window_screenshot

Capture a screenshot of a specific window.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `window` | string | **Yes** | Window resource name (e.g., `applications/123/windows/456`) |
| `format` | string | No | Image format: `png`, `jpeg`, `tiff`. Default: `png` |
| `quality` | integer | No | JPEG quality (1-100). Default: 85 |
| `include_shadow` | boolean | No | Include window shadow. Default: false |
| `include_ocr` | boolean | No | Include OCR text extraction |

**Returns:** Base64-encoded image data.

#### capture_region_screenshot

Capture a screenshot of a specific screen region using Global Display Coordinates.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | X coordinate of region origin |
| `y` | number | **Yes** | Y coordinate of region origin |
| `width` | number | **Yes** | Width of region in pixels |
| `height` | number | **Yes** | Height of region in pixels |
| `format` | string | No | Image format: `png`, `jpeg`, `tiff` |
| `quality` | integer | No | JPEG quality (1-100) |
| `include_ocr` | boolean | No | Include OCR text extraction |

---

### 2.2 Input Tools

| Tool | Description |
|------|-------------|
| `click` | Click at screen coordinate |
| `type_text` | Type text as keyboard input |
| `press_key` | Press key combination |
| `hold_key` | Hold key for duration |
| `mouse_move` | Move cursor to position |
| `scroll` | Scroll content |
| `drag` | Drag from one position to another |
| `mouse_button_down` | Press mouse button without releasing |
| `mouse_button_up` | Release mouse button |
| `hover` | Hover at position for duration |
| `gesture` | Perform multi-touch gesture |

#### click

Click at a specific screen coordinate (Global Display Coordinates).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | X coordinate to click |
| `y` | number | **Yes** | Y coordinate to click |
| `button` | string | No | Mouse button: `left`, `right`, `middle`. Default: `left` |
| `click_count` | integer | No | Number of clicks: 1=single, 2=double, 3=triple. Default: 1 |
| `show_animation` | boolean | No | Show visual feedback animation |

**Example:**
```json
{
  "name": "click",
  "arguments": {"x": 500, "y": 300, "click_count": 2}
}
```

#### type_text

Type text as keyboard input. Simulates human typing.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `text` | string | **Yes** | Text to type |
| `char_delay` | number | No | Delay between characters in seconds |
| `use_ime` | boolean | No | Use IME for non-ASCII input |

#### press_key

Press a key combination with optional modifiers.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `key` | string | **Yes** | Key to press (e.g., `return`, `escape`, `a`, `f1`, `space`, `tab`, `delete`) |
| `modifiers` | array | No | Modifier keys: `command`, `option`, `control`, `shift`, `function`, `capslock` |

**Example:**
```json
{
  "name": "press_key",
  "arguments": {"key": "s", "modifiers": ["command"]}
}
```

#### hold_key

Hold a key down for a specified duration.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `key` | string | **Yes** | Key to hold |
| `duration` | number | **Yes** | Duration to hold in seconds |
| `modifiers` | array | No | Modifier keys to hold simultaneously |

#### mouse_move

Move the mouse cursor to a specific position.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | Target X coordinate |
| `y` | number | **Yes** | Target Y coordinate |
| `duration` | number | No | Duration for smooth animation in seconds |

#### scroll

Scroll content vertically and/or horizontally.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | No | X coordinate to scroll at |
| `y` | number | No | Y coordinate to scroll at |
| `horizontal` | number | No | Horizontal scroll (positive=right, negative=left) |
| `vertical` | number | No | Vertical scroll (positive=up, negative=down) |
| `duration` | number | No | Duration for momentum effect |

#### drag

Drag from one position to another.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `start_x` | number | **Yes** | Start X coordinate |
| `start_y` | number | **Yes** | Start Y coordinate |
| `end_x` | number | **Yes** | End X coordinate |
| `end_y` | number | **Yes** | End Y coordinate |
| `duration` | number | No | Duration of drag in seconds |
| `button` | string | No | Mouse button: `left`, `right`, `middle` |

#### mouse_button_down

Press a mouse button down without releasing. Use with `mouse_button_up` for stateful drag operations.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | X coordinate |
| `y` | number | **Yes** | Y coordinate |
| `button` | string | No | Mouse button: `left`, `right`, `middle` |
| `modifiers` | array | No | Modifier keys: `command`, `option`, `control`, `shift` |

#### mouse_button_up

Release a mouse button at a position. Use after `mouse_button_down`.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | X coordinate |
| `y` | number | **Yes** | Y coordinate |
| `button` | string | No | Mouse button: `left`, `right`, `middle` |
| `modifiers` | array | No | Modifier keys |

#### hover

Hover at a position for a specified duration to trigger hover states and tooltips.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | **Yes** | X coordinate |
| `y` | number | **Yes** | Y coordinate |
| `duration` | number | No | Duration to hover in seconds. Default: 1.0 |
| `application` | string | No | Application resource name |

#### gesture

Perform a multi-touch gesture (trackpad gestures).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `center_x` | number | **Yes** | Center X coordinate of gesture |
| `center_y` | number | **Yes** | Center Y coordinate of gesture |
| `gesture_type` | string | **Yes** | Type: `pinch`, `zoom`, `rotate`, `swipe`, `force_touch` |
| `scale` | number | No | Scale factor for pinch/zoom (0.5=zoom out, 2.0=zoom in) |
| `rotation` | number | No | Rotation angle in degrees |
| `finger_count` | integer | No | Number of fingers for swipe. Default: 2 |
| `direction` | string | No | Direction for swipe: `up`, `down`, `left`, `right` |
| `application` | string | No | Application resource name |

---

### 2.3 Element Tools

| Tool | Description |
|------|-------------|
| `find_elements` | Find UI elements by criteria |
| `get_element` | Get element details |
| `get_element_actions` | Get available actions for element |
| `click_element` | Click on a UI element via accessibility |
| `write_element_value` | Set element value |
| `perform_element_action` | Perform accessibility action |

#### find_elements

Find UI elements matching criteria.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Parent context (e.g., `applications/{id}` or `applications/{id}/windows/{id}`) |
| `selector` | object | No | Criteria: `{role, text, title}` |

**Returns:** Array of elements with role, text, bounds, and available actions.

**Example:**
```json
{
  "name": "find_elements",
  "arguments": {
    "parent": "applications/12345",
    "selector": {"role": "button", "text": "OK"}
  }
}
```

#### get_element

Get detailed information about a specific UI element.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Element resource name |

#### get_element_actions

Get available actions for a specific UI element.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Element resource name |

**Returns:** List of actions like `press`, `increment`, `decrement`.

#### click_element

Click on a UI element using accessibility APIs (more reliable than coordinates).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Parent context |
| `element_id` | string | **Yes** | Element ID from find_elements result |

#### write_element_value

Set the value of a UI element (e.g., text field).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Parent context |
| `element_id` | string | **Yes** | Element ID |
| `value` | string | **Yes** | Value to set |

#### perform_element_action

Perform an accessibility action on a UI element.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Parent context |
| `element_id` | string | **Yes** | Element ID |
| `action` | string | **Yes** | Action to perform (from element's actions list) |

---

### 2.4 Window Tools

| Tool | Description |
|------|-------------|
| `list_windows` | List all open windows |
| `get_window` | Get window details |
| `focus_window` | Focus/activate window |
| `move_window` | Move window to position |
| `resize_window` | Resize window |
| `minimize_window` | Minimize window to dock |
| `restore_window` | Restore minimized window |
| `close_window` | Close window |
| `get_window_state` | Get accessibility state of window |

#### list_windows

List all open windows across tracked applications.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | No | Filter by application |
| `page_size` | integer | No | Max results per page. Default: 100 |
| `page_token` | string | No | Token for pagination (opaque) |

**Returns:** Array of windows with title, bounds, visibility, z-index. Includes `next_page_token` if more results exist.

#### get_window

Get details of a specific window.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |

**Returns:** Window with title, bounds (Global Display Coordinates), visibility, z-index.

#### focus_window

Focus (activate) a window, bringing it to front.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |

#### move_window

Move a window to a new position in Global Display Coordinates.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |
| `x` | number | **Yes** | New X position |
| `y` | number | **Yes** | New Y position |

#### resize_window

Resize a window to new dimensions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |
| `width` | number | **Yes** | New width in pixels |
| `height` | number | **Yes** | New height in pixels |

#### minimize_window

Minimize a window to the dock.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |

#### restore_window

Restore a minimized window.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |

#### close_window

Close a window.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |
| `force` | boolean | No | Force close without saving. Default: false |

#### get_window_state

Get detailed accessibility state of a window.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Window resource name |

**Returns:** Window state including focused element and all UI elements.

---

### 2.5 Display Tools

| Tool | Description |
|------|-------------|
| `list_displays` | List all connected displays |
| `get_display` | Get display details |
| `cursor_position` | Get current cursor position |

#### list_displays

List all connected displays with frame coordinates, visible areas, and scale factors.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | - | - | - |

**Returns:** Array of displays with frame, visible frame, is_main, scale factor.

**Example Response:**
```json
{
  "displays": [
    {
      "name": "displays/12345",
      "frame": {"x": 0, "y": 0, "width": 2560, "height": 1440},
      "visible_frame": {"x": 0, "y": 25, "width": 2560, "height": 1340},
      "is_main": true,
      "scale": 2.0
    }
  ]
}
```

#### get_display

Get details of a specific display.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Display resource name |

#### cursor_position

Get the current cursor position in Global Display Coordinates.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | - | - | - |

**Returns:** X/Y coordinates and which display the cursor is on.

---

### 2.6 Clipboard Tools

| Tool | Description |
|------|-------------|
| `get_clipboard` | Get clipboard contents |
| `write_clipboard` | Write to clipboard |
| `clear_clipboard` | Clear clipboard |
| `get_clipboard_history` | Get clipboard history |

#### get_clipboard

Get clipboard contents. Supports text, RTF, HTML, images, files, URLs.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | - | - | - |

#### write_clipboard

Write content to the clipboard.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `text` | string | **Yes** | Text content to write |

#### clear_clipboard

Clear all clipboard contents.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | - | - | - |

#### get_clipboard_history

Get clipboard history (if available).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | - | - | - |

---

### 2.7 Application Tools

| Tool | Description |
|------|-------------|
| `open_application` | Launch/open application |
| `list_applications` | List tracked applications |
| `get_application` | Get application details |
| `delete_application` | Stop tracking application |

#### open_application

Open an application by name, bundle ID, or path.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | **Yes** | App identifier: name (`Calculator`), bundle ID (`com.apple.calculator`), or path (`/Applications/Calculator.app`) |

**Example:**
```json
{
  "name": "open_application",
  "arguments": {"id": "TextEdit"}
}
```

#### list_applications

List all applications currently being tracked.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_size` | integer | No | Max results per page |
| `page_token` | string | No | Pagination token |

#### get_application

Get details of a specific tracked application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Application resource name |

#### delete_application

Stop tracking an application (does not terminate process).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Application resource name |

---

### 2.8 Scripting Tools

| Tool | Description |
|------|-------------|
| `execute_apple_script` | Execute AppleScript |
| `execute_javascript` | Execute JavaScript for Automation (JXA) |
| `execute_shell_command` | Execute shell command |
| `validate_script` | Validate script without executing |
| `get_scripting_dictionaries` | Get AppleScript dictionaries |

#### execute_apple_script

Execute AppleScript code.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `script` | string | **Yes** | AppleScript source code |
| `timeout` | integer | No | Timeout in seconds. Default: 30 |

**Example:**
```json
{
  "name": "execute_apple_script",
  "arguments": {
    "script": "tell application \"Finder\" to get name of home"
  }
}
```

#### execute_javascript

Execute JavaScript for Automation (JXA) code.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `script` | string | **Yes** | JavaScript source code |
| `timeout` | integer | No | Timeout in seconds. Default: 30 |

#### execute_shell_command

Execute a shell command.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string | **Yes** | Command to execute |
| `args` | array | No | Command arguments |
| `timeout` | integer | No | Timeout in seconds. Default: 30 |

**Returns:** stdout, stderr, exit code.

> ⚠️ **Security Warning:** Shell commands are disabled by default. Set `MCP_SHELL_COMMANDS_ENABLED=true` only in trusted environments.

#### validate_script

Validate a script without executing.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `type` | string | **Yes** | Script type: `applescript`, `javascript`, `shell` |
| `script` | string | **Yes** | Script source code |

#### get_scripting_dictionaries

Get available AppleScript dictionaries for scriptable applications.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | No | Resource name |

---

### 2.9 Observation Tools

| Tool | Description |
|------|-------------|
| `create_observation` | Create observation for UI monitoring |
| `stream_observations` | Stream observation events |
| `get_observation` | Get observation status |
| `list_observations` | List observations |
| `cancel_observation` | Cancel observation |

#### create_observation

Create an observation to monitor UI changes in an application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Parent application |
| `type` | string | No | Type: `element_changes`, `window_changes`, `application_changes`, `attribute_changes`, `tree_changes` |
| `visible_only` | boolean | No | Only observe visible elements. Default: false |
| `poll_interval` | number | No | Poll interval in seconds |
| `roles` | array | No | Specific element roles to observe |
| `attributes` | array | No | Specific attributes to observe |

#### stream_observations

Stream observation events in real-time.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Observation resource name |
| `timeout` | number | No | Timeout in seconds. Default: 300, Max: 3600 |

#### get_observation

Get the current status of an observation.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Observation resource name |

#### list_observations

List all observations for an application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | No | Parent application (empty for all) |

#### cancel_observation

Cancel an active observation.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Observation resource name |

#### Observation Workflow Examples

##### Example 1: Monitoring Window Changes in TextEdit

This workflow demonstrates creating an observation to watch for window changes, then detecting when a new document appears.

**Step 1: Open the application and create observation**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "open_application",
    "arguments": {"id": "TextEdit"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"applications/12345\",\"bundle_id\":\"com.apple.TextEdit\",\"title\":\"TextEdit\"}"}]
  }
}
```

**Step 2: Create an observation for window changes**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "create_observation",
    "arguments": {
      "parent": "applications/12345",
      "type": "window_changes",
      "poll_interval": 0.5
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"applications/12345/observations/obs-001\",\"state\":\"ACTIVE\"}"}]
  }
}
```

**Step 3: Stream observations (long-polling for changes)**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "stream_observations",
    "arguments": {
      "name": "applications/12345/observations/obs-001",
      "timeout": 30
    }
  }
}
```

Response (when new window opens):
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"events\":[{\"type\":\"WINDOW_CREATED\",\"window\":{\"name\":\"applications/12345/windows/67890\",\"title\":\"Untitled\"}}]}"}]
  }
}
```

**Step 4: Cancel observation when done**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "cancel_observation",
    "arguments": {"name": "applications/12345/observations/obs-001"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"cancelled\":true}"}]
  }
}
```

##### Example 2: Watching for Element State Changes

Watch for a specific button to become enabled:

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "create_observation",
    "arguments": {
      "parent": "applications/12345",
      "type": "attribute_changes",
      "roles": ["AXButton"],
      "attributes": ["AXEnabled"],
      "visible_only": true
    }
  }
}
```

---

### 2.10 Accessibility Tools

| Tool | Description |
|------|-------------|
| `traverse_accessibility` | Traverse full accessibility tree |
| `find_region_elements` | Find elements within screen region |
| `wait_element` | Wait for element to appear |
| `wait_element_state` | Wait for element state |
| `capture_element_screenshot` | Screenshot specific element |
| `watch_accessibility` | Watch accessibility tree changes |

#### traverse_accessibility

Traverse the full accessibility tree of an application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Application resource name |
| `visible_only` | boolean | No | Only return visible elements. Default: false |

**Returns:** All UI elements with roles, text, and positions.

#### find_region_elements

Find UI elements within a screen region.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Application or window resource name |
| `x` | number | **Yes** | X coordinate of region origin |
| `y` | number | **Yes** | Y coordinate of region origin |
| `width` | number | **Yes** | Width of region |
| `height` | number | **Yes** | Height of region |
| `selector` | object | No | Optional selector for filtering |

#### wait_element

Wait for an element matching a selector to appear.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Application or window resource name |
| `selector` | object | **Yes** | Element selector: `{role, text, text_contains}` |
| `timeout` | number | No | Max wait time in seconds. Default: 30 |
| `poll_interval` | number | No | Poll interval in seconds. Default: 0.5 |

#### wait_element_state

Wait for an element to reach a specific state.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Application or window resource name |
| `element_id` | string | **Yes** | Element ID to wait on |
| `condition` | string | **Yes** | Condition: `enabled`, `focused`, `text_equals`, `text_contains` |
| `value` | string | No | Value for text conditions |
| `timeout` | number | No | Max wait time. Default: 30 |
| `poll_interval` | number | No | Poll interval. Default: 0.5 |

#### capture_element_screenshot

Capture a screenshot of a specific UI element.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | **Yes** | Application resource name |
| `element_id` | string | **Yes** | Element ID |
| `format` | string | No | Image format: `png`, `jpeg`, `tiff` |
| `quality` | integer | No | JPEG quality (1-100) |
| `padding` | integer | No | Padding around element in pixels |
| `include_ocr` | boolean | No | Include OCR text extraction |

#### watch_accessibility

Watch accessibility tree changes for an application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Application resource name |
| `poll_interval` | number | No | Poll interval in seconds |
| `visible_only` | boolean | No | Only report visible element changes |

---

### 2.11 File Dialog Tools

| Tool | Description |
|------|-------------|
| `automate_open_file_dialog` | Automate open file dialog |
| `automate_save_file_dialog` | Automate save file dialog |
| `select_file` | Select file in browser/dialog |
| `select_directory` | Select directory |
| `drag_files` | Drag files onto target element |

#### automate_open_file_dialog

Automate interacting with an open file dialog.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `application` | string | **Yes** | Application resource name |
| `file_path` | string | No | File path to select |
| `default_directory` | string | No | Directory to navigate to |
| `file_filters` | array | No | File type filters (e.g., `["*.txt", "*.pdf"]`) |
| `timeout` | number | No | Timeout for dialog to appear |
| `allow_multiple` | boolean | No | Allow multiple file selection |

#### automate_save_file_dialog

Automate interacting with a save file dialog.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `application` | string | **Yes** | Application resource name |
| `file_path` | string | **Yes** | Full file path to save to |
| `default_directory` | string | No | Directory to navigate to |
| `default_filename` | string | No | Default filename |
| `timeout` | number | No | Timeout for dialog to appear |
| `confirm_overwrite` | boolean | No | Confirm overwrite if file exists |

#### select_file

Programmatically select a file in a file browser or dialog context.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `application` | string | **Yes** | Application resource name |
| `file_path` | string | **Yes** | File path to select |
| `reveal_finder` | boolean | No | Reveal file in Finder after selection |

#### select_directory

Programmatically select a directory.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `application` | string | **Yes** | Application resource name |
| `directory_path` | string | **Yes** | Directory path to select |
| `create_missing` | boolean | No | Create directory if doesn't exist |

#### drag_files

Drag and drop files onto a target UI element.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `application` | string | **Yes** | Application resource name |
| `file_paths` | array | **Yes** | File paths to drag |
| `target_element_id` | string | **Yes** | Target element ID |
| `duration` | number | No | Drag duration in seconds |

---

### 2.12 Session Tools

| Tool | Description |
|------|-------------|
| `create_session` | Create session for workflows |
| `get_session` | Get session details |
| `list_sessions` | List all sessions |
| `delete_session` | Delete session |
| `get_session_snapshot` | Get session state snapshot |
| `begin_transaction` | Begin transaction |
| `commit_transaction` | Commit transaction |
| `rollback_transaction` | Rollback transaction |

#### Session Workflow Examples

##### Example 1: Basic Session Lifecycle (Create → Use → Delete)

Sessions provide a way to coordinate complex multi-step workflows, track metadata, and manage application state.

**Step 1: Create a session for an automation workflow**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "create_session",
    "arguments": {
      "display_name": "Document Processing Workflow",
      "metadata": {
        "task": "process_invoices",
        "started_by": "automation_script",
        "batch_id": "batch-2026-02-04"
      }
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"sessions/sess-a1b2c3\",\"display_name\":\"Document Processing Workflow\",\"create_time\":\"2026-02-04T10:00:00Z\",\"state\":\"ACTIVE\"}"}]
  }
}
```

**Step 2: Perform automation actions (open app, interact with windows)**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "open_application",
    "arguments": {"id": "TextEdit"}
  }
}
```

**Step 3: Get session snapshot to inspect tracked state**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "get_session_snapshot",
    "arguments": {"name": "sessions/sess-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"session\":\"sessions/sess-a1b2c3\",\"applications\":[{\"name\":\"applications/12345\",\"bundle_id\":\"com.apple.TextEdit\"}],\"observations\":[],\"operation_count\":5}"}]
  }
}
```

**Step 4: Get session details**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "get_session",
    "arguments": {"name": "sessions/sess-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"sessions/sess-a1b2c3\",\"display_name\":\"Document Processing Workflow\",\"metadata\":{\"task\":\"process_invoices\",\"started_by\":\"automation_script\",\"batch_id\":\"batch-2026-02-04\"},\"state\":\"ACTIVE\",\"create_time\":\"2026-02-04T10:00:00Z\"}"}]
  }
}
```

**Step 5: Delete session when workflow is complete**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "delete_session",
    "arguments": {"name": "sessions/sess-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"deleted\":true}"}]
  }
}
```

##### Example 2: Using Transactions for Atomic Operations

Transactions allow grouping operations that should succeed or fail together:

**Begin a transaction:**
```json
{
  "method": "tools/call",
  "params": {
    "name": "begin_transaction",
    "arguments": {"session": "sessions/sess-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"transaction_id\":\"txn-001\",\"session\":\"sessions/sess-a1b2c3\"}"}]
  }
}
```

**Commit if all operations succeed:**
```json
{
  "method": "tools/call",
  "params": {
    "name": "commit_transaction",
    "arguments": {
      "name": "sessions/sess-a1b2c3",
      "transaction_id": "txn-001"
    }
  }
}
```

**Or rollback if something fails:**
```json
{
  "method": "tools/call",
  "params": {
    "name": "rollback_transaction",
    "arguments": {
      "name": "sessions/sess-a1b2c3",
      "transaction_id": "txn-001"
    }
  }
}
```

##### Example 3: Listing All Sessions

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "list_sessions",
    "arguments": {"page_size": 10}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"sessions\":[{\"name\":\"sessions/sess-a1b2c3\",\"display_name\":\"Document Processing Workflow\",\"state\":\"ACTIVE\"},{\"name\":\"sessions/sess-d4e5f6\",\"display_name\":\"Daily Report Generator\",\"state\":\"ACTIVE\"}]}"}]
  }
}
```

#### create_session

Create a new session for coordinating complex workflows.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_id` | string | No | Optional session ID (server generates if not provided) |
| `display_name` | string | No | Display name for session |
| `metadata` | object | No | Session-scoped metadata (key-value pairs) |

#### get_session

Get details of a specific session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Session resource name |

#### list_sessions

List all sessions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_size` | integer | No | Max results per page |
| `page_token` | string | No | Pagination token |

#### delete_session

Delete a session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Session resource name |
| `force` | boolean | No | Force delete active sessions |

#### get_session_snapshot

Get a snapshot of session state.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Session resource name |

**Returns:** Applications, observations, and operation history.

#### begin_transaction

Begin a transaction within a session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session` | string | **Yes** | Session resource name |

#### commit_transaction

Commit a transaction.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Session resource name |
| `transaction_id` | string | **Yes** | Transaction ID |

#### rollback_transaction

Rollback a transaction.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Session resource name |
| `transaction_id` | string | **Yes** | Transaction ID |
| `revision_id` | string | No | Optional revision ID to rollback to |

---

### 2.13 Macro Tools

| Tool | Description |
|------|-------------|
| `create_macro` | Create macro for action sequences |
| `get_macro` | Get macro details |
| `list_macros` | List all macros |
| `delete_macro` | Delete macro |
| `execute_macro` | Execute macro |
| `update_macro` | Update macro metadata |

#### Macro Workflow Examples

##### Example 1: Creating and Executing a Macro

Macros allow you to define reusable action sequences that can be executed multiple times. This example shows creating a macro that opens a new TextEdit document.

**Step 1: Create a new macro**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "create_macro",
    "arguments": {
      "display_name": "New TextEdit Document",
      "description": "Opens TextEdit and creates a new document with a timestamp",
      "tags": ["textedit", "documents", "automation"]
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"macros/macro-a1b2c3\",\"display_name\":\"New TextEdit Document\",\"description\":\"Opens TextEdit and creates a new document with a timestamp\",\"tags\":[\"textedit\",\"documents\",\"automation\"],\"create_time\":\"2026-02-04T10:00:00Z\"}"}]
  }
}
```

**Step 2: Execute the macro**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "execute_macro",
    "arguments": {
      "macro": "macros/macro-a1b2c3"
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"operation\":\"operations/op-xyz789\",\"done\":true,\"result\":{\"success\":true,\"actions_executed\":3}}"}]
  }
}
```

##### Example 2: Managing Macros

**List all macros with filtering by tags:**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "list_macros",
    "arguments": {"page_size": 20}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"macros\":[{\"name\":\"macros/macro-a1b2c3\",\"display_name\":\"New TextEdit Document\",\"tags\":[\"textedit\",\"documents\",\"automation\"]},{\"name\":\"macros/macro-d4e5f6\",\"display_name\":\"Close All Windows\",\"tags\":[\"cleanup\",\"windows\"]}]}"}]
  }
}
```

**Get details of a specific macro:**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "get_macro",
    "arguments": {"name": "macros/macro-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"macros/macro-a1b2c3\",\"display_name\":\"New TextEdit Document\",\"description\":\"Opens TextEdit and creates a new document with a timestamp\",\"tags\":[\"textedit\",\"documents\",\"automation\"],\"create_time\":\"2026-02-04T10:00:00Z\",\"update_time\":\"2026-02-04T10:00:00Z\",\"execution_count\":5}"}]
  }
}
```

**Update macro metadata:**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "update_macro",
    "arguments": {
      "name": "macros/macro-a1b2c3",
      "display_name": "New TextEdit Document (v2)",
      "description": "Opens TextEdit, creates a new document, and adds timestamp header",
      "tags": ["textedit", "documents", "automation", "updated"]
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"name\":\"macros/macro-a1b2c3\",\"display_name\":\"New TextEdit Document (v2)\",\"update_time\":\"2026-02-04T11:00:00Z\"}"}]
  }
}
```

**Delete a macro when no longer needed:**

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "delete_macro",
    "arguments": {"name": "macros/macro-a1b2c3"}
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"deleted\":true}"}]
  }
}
```

##### Example 3: Executing a Parameterized Macro

Macros can accept parameter values at execution time:

Request:
```json
{
  "method": "tools/call",
  "params": {
    "name": "execute_macro",
    "arguments": {
      "macro": "macros/macro-save-file",
      "parameter_values": {
        "filename": "quarterly-report.txt",
        "directory": "/Users/myuser/Documents"
      }
    }
  }
}
```

Response:
```json
{
  "result": {
    "content": [{"type": "text", "text": "{\"operation\":\"operations/op-abc123\",\"done\":true,\"result\":{\"success\":true,\"actions_executed\":5,\"file_saved\":\"/Users/myuser/Documents/quarterly-report.txt\"}}"}]
  }
}
```

#### create_macro

Create a new macro for recording and replaying action sequences.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `macro_id` | string | No | Optional macro ID |
| `display_name` | string | **Yes** | Display name for macro |
| `description` | string | No | Description of what macro does |
| `tags` | array | No | Tags for categorization |

#### get_macro

Get details of a specific macro including its actions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Macro resource name |

#### list_macros

List all macros.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_size` | integer | No | Max results per page |
| `page_token` | string | No | Pagination token |

#### delete_macro

Delete a macro.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Macro resource name |

#### execute_macro

Execute a macro. Returns a long-running operation.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `macro` | string | **Yes** | Macro resource name |
| `parameter_values` | object | No | Parameter values for parameterized macros |

#### update_macro

Update an existing macro's metadata.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Macro resource name |
| `display_name` | string | No | New display name |
| `description` | string | No | New description |
| `tags` | array | No | New tags |

---

### 2.14 Input Query Tools

| Tool | Description |
|------|-------------|
| `get_input` | Get input action details |
| `list_inputs` | List input history |

#### get_input

Get details of a specific input action by resource name.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Input resource name |

#### list_inputs

List input history for an application.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `parent` | string | No | Parent application. Use `applications/-` for all |
| `page_size` | integer | No | Max results per page |
| `page_token` | string | No | Pagination token |
| `filter` | string | No | Filter by state: `PENDING`, `EXECUTING`, `COMPLETED`, `FAILED` |

---

## 3. Environment Variable Reference

MacosUseSDK supports **18 environment variables** for configuration.

### 3.1 Core Configuration

| Variable | Description | Type | Default | Example |
|----------|-------------|------|---------|---------|
| `MACOS_USE_SERVER_ADDR` | gRPC server address | string | `localhost:50051` | `192.168.1.100:50051` |
| `MACOS_USE_SERVER_TLS` | Enable TLS for gRPC | boolean | `false` | `true` |
| `MACOS_USE_SERVER_CERT_FILE` | gRPC server TLS certificate path | string | _(none)_ | `/etc/ssl/server.crt` |
| `MACOS_USE_REQUEST_TIMEOUT` | gRPC request timeout in seconds | integer | `30` | `60` |
| `MACOS_USE_DEBUG` | Enable debug logging | boolean | `false` | `true` |

### 3.2 Transport Configuration

| Variable | Description | Type | Default | Example |
|----------|-------------|------|---------|---------|
| `MCP_TRANSPORT` | Transport type | string | `stdio` | `sse` |
| `MCP_HTTP_ADDRESS` | HTTP/SSE listen address | string | `:8080` | `127.0.0.1:9000` |
| `MCP_HTTP_SOCKET` | Unix socket path (overrides address) | string | _(none)_ | `/tmp/mcp.sock` |
| `MCP_CORS_ORIGIN` | CORS allowed origin | string | `*` | `https://app.example.com` |
| `MCP_HEARTBEAT_INTERVAL` | SSE heartbeat interval | duration | `30s` | `15s` |
| `MCP_HTTP_READ_TIMEOUT` | HTTP read timeout | duration | `30s` | `60s` |
| `MCP_HTTP_WRITE_TIMEOUT` | HTTP write timeout | duration | `30s` | `120s` |

### 3.3 Security Configuration

| Variable | Description | Type | Default | Example |
|----------|-------------|------|---------|---------|
| `MCP_TLS_CERT_FILE` | TLS certificate for HTTPS | string | _(none)_ | `/etc/ssl/certs/server.crt` |
| `MCP_TLS_KEY_FILE` | TLS private key for HTTPS | string | _(none)_ | `/etc/ssl/private/server.key` |
| `MCP_API_KEY` | API key for Bearer token auth | string | _(none)_ | `your-secret-key-here` |
| `MCP_SHELL_COMMANDS_ENABLED` | Enable shell command execution | boolean | `false` | `true` |

### 3.4 Observability Configuration

| Variable | Description | Type | Default | Example |
|----------|-------------|------|---------|---------|
| `MCP_RATE_LIMIT` | Rate limit (requests/second) | float | `0` (disabled) | `100` |
| `MCP_AUDIT_LOG_FILE` | Audit log file path | string | _(none)_ | `/var/log/mcp-audit.log` |

### 3.5 Example Configuration

```bash
# Production configuration
export MACOS_USE_SERVER_ADDR="localhost:50051"
export MCP_TRANSPORT="sse"
export MCP_HTTP_ADDRESS=":8443"
export MCP_TLS_CERT_FILE="/etc/ssl/certs/server.crt"
export MCP_TLS_KEY_FILE="/etc/ssl/private/server.key"
export MCP_API_KEY="$(openssl rand -base64 32)"
export MCP_RATE_LIMIT="100"
export MCP_AUDIT_LOG_FILE="/var/log/mcp-audit.log"
export MCP_CORS_ORIGIN="https://myapp.example.com"
./macos-use-mcp
```

---

## 4. Error Code Reference

### 4.1 JSON-RPC Error Codes

Standard JSON-RPC 2.0 error codes used by the MCP protocol:

| Code | Constant | Description |
|------|----------|-------------|
| `-32700` | `ErrCodeParseError` | Invalid JSON received |
| `-32600` | `ErrCodeInvalidRequest` | JSON is not a valid Request object |
| `-32601` | `ErrCodeMethodNotFound` | Method does not exist |
| `-32602` | `ErrCodeInvalidParams` | Invalid method parameters |
| `-32603` | `ErrCodeInternalError` | Internal JSON-RPC error |

### 4.2 MCP Soft Errors (`is_error: true`)

MCP tools can return "soft errors" that do not use JSON-RPC error codes. These return a successful JSON-RPC response with `is_error: true` in the result:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [{"type": "text", "text": "Element not found: button with text 'Submit'"}],
    "is_error": true
  }
}
```

**Soft Error Scenarios:**
- Element not found (selector didn't match)
- Window not found (closed between calls)
- Operation timeout (wait_element exceeded timeout)
- Accessibility denial (permission not granted)
- Coordinate out of bounds (multi-monitor edge case)
- Application not running (process terminated)

### 4.3 gRPC Error Codes

The MCP server communicates with the Swift backend via gRPC. These codes may surface in error messages:

| Code | Name | Description |
|------|------|-------------|
| `0` | `OK` | Success |
| `1` | `CANCELLED` | Operation was cancelled |
| `2` | `UNKNOWN` | Unknown error |
| `3` | `INVALID_ARGUMENT` | Invalid argument provided |
| `4` | `DEADLINE_EXCEEDED` | Operation timeout |
| `5` | `NOT_FOUND` | Resource not found |
| `6` | `ALREADY_EXISTS` | Resource already exists |
| `7` | `PERMISSION_DENIED` | Accessibility or security denial |
| `8` | `RESOURCE_EXHAUSTED` | Rate limit exceeded |
| `9` | `FAILED_PRECONDITION` | Operation prerequisites not met |
| `12` | `UNIMPLEMENTED` | Method not implemented |
| `13` | `INTERNAL` | Internal server error |
| `14` | `UNAVAILABLE` | Service unavailable |

### 4.4 HTTP Error Codes (SSE Transport)

When using HTTP transport (`MCP_TRANSPORT=sse`):

| Code | Description | Cause |
|------|-------------|-------|
| `401` | Unauthorized | Missing or invalid `Authorization` header when `MCP_API_KEY` is set |
| `429` | Too Many Requests | Rate limit exceeded (includes `Retry-After: 1` header) |
| `500` | Internal Server Error | Server-side error |

---

## 5. Resource Naming Conventions

MacosUseSDK uses consistent resource naming following Google AIP patterns:

### 5.1 Resource Name Format

```
{collection}/{id}
{collection}/{id}/{sub_collection}/{sub_id}
```

### 5.2 Resource Types

| Resource | Pattern | Example |
|----------|---------|---------|
| Application | `applications/{pid}` | `applications/12345` |
| Window | `applications/{pid}/windows/{window_id}` | `applications/12345/windows/67890` |
| Element | `applications/{pid}/elements/{element_id}` | `applications/12345/elements/abc123` |
| Observation | `applications/{pid}/observations/{obs_id}` | `applications/12345/observations/obs001` |
| Display | `displays/{display_id}` | `displays/69732928` |
| Session | `sessions/{session_id}` | `sessions/sess-001` |
| Macro | `macros/{macro_id}` | `macros/macro-login` |
| Input | `applications/{pid}/inputs/{input_id}` | `applications/12345/inputs/inp-001` |

### 5.3 Wildcard Patterns

For list operations, use `-` as wildcard:

```
applications/-          # All applications
applications/-/windows  # All windows across all applications
```

---

## Cross-References

- [Production Deployment Guide](08-production-deployment.md) - Deployment patterns, TLS, reverse proxy
- [Security Hardening Guide](09-security-hardening.md) - Security best practices
- [MCP Integration Analysis](05-mcp-integration.md) - Protocol details, transport mechanisms
- [MCP Tool Design](06-mcp-tool-design.md) - Tool design philosophy
- [Window State Management](02-window-state-management.md) - AppStateStore, WindowRegistry architecture
