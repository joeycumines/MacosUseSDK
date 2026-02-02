# MCP Tool Design Review - Alignment Analysis

## Executive Summary

**VERDICT: MAJOR GAPS IDENTIFIED**

Document 06 lists 34 MCP tools; only 5 are implemented (~85% gap). Critical Computer Use actions from doc05 (screenshot, click, type, key) are missing entirely. The MCP server cannot currently function as a Computer Use agent interface.

## Critical Gaps (P0 - Blocking)

1. **No screenshot tool** - Cannot observe screen state (doc05 Section 2.1.2 `screenshot` action)
2. **No coordinate-based click** - Can only click elements, not arbitrary coordinates (doc05 `left_click`, `right_click`, etc.)
3. **No type_text tool** - Cannot inject keyboard text (doc05 `type` action)
4. **No press_key tool** - Cannot execute keyboard shortcuts (doc05 `key` action)

## Severe Gaps (P1 - Limiting)

5. **No is_error soft failure pattern** - All errors are hard JSON-RPC errors (doc05 Section 2.3.2)
6. **No screenshot scaling** - Native 4K images waste tokens (doc05 Section 2.3.1)
7. **No display grounding in initialize** - Missing `display_width_px`, `display_height_px` (doc05 Section 2.1.1)
8. **No cursor_position** - Cannot verify mouse position (doc05 "proprioception")
9. **No mouse_move/scroll tools** - Cannot hover or navigate content

## Protocol Gaps

| Missing Protocol Feature | Doc05 Reference |
|--------------------------|-----------------|
| `notifications/initialized` | Section 1.1.2 |
| `shutdown` / `exit` methods | Section 1.1.1 |
| `resources/list` / `resources/read` | Section 1.2 |
| Empty `capabilities` object | Section 1.1.2 |
| No SSE transport | Section 1.2.2 |

## Action Space Comparison (doc05 Table 2 vs Implementation)

| Doc05 Action | gRPC API | MCP Tool | Status |
|--------------|----------|----------|--------|
| `mouse_move` | `MouseMove` | - | ❌ Missing |
| `cursor_position` | - | - | ❌ API+MCP Missing |
| `left_click` | `MouseClick.CLICK_TYPE_LEFT` | - | ❌ MCP Missing |
| `right_click` | `MouseClick.CLICK_TYPE_RIGHT` | - | ❌ MCP Missing |
| `double_click` | `MouseClick.click_count=2` | - | ❌ MCP Missing |
| `left_click_drag` | `MouseDrag` | - | ❌ MCP Missing |
| `left_mouse_down` | - | - | ❌ API+MCP Missing |
| `left_mouse_up` | - | - | ❌ API+MCP Missing |
| `type` | `TextInput` | - | ❌ MCP Missing |
| `key` | `KeyPress` | - | ❌ MCP Missing |
| `hold_key` | - | - | ❌ API+MCP Missing |
| `scroll` | `Scroll` | - | ❌ MCP Missing |
| `screenshot` | `CaptureScreenshot` | - | ❌ MCP Missing |
| `zoom` (high-res crop) | - | - | ❌ API+MCP Missing |

## Accessibility Integration Gaps

1. **States array missing** - Element proto lacks `focusable`, `clickable`, `selected`, `expanded`, `checked`
2. **No Set-of-Marks (SoM)** - Cannot overlay element IDs on screenshots (doc05 Section 4.2)
3. **No hybrid screenshot+A11y response** - Screenshots don't include accessibility tree
4. **WatchAccessibility not exposed** - Streaming RPC exists but no MCP tool

## Implemented vs Required Tools

### Currently Implemented (5)
- `find_elements`
- `list_windows`
- `list_displays`
- `get_display`
- `get_clipboard`

### Doc06 Required but Missing (29)
- `open_application`, `get_application`, `list_applications`, `delete_application`
- `get_window`, `focus_window`, `move_window`, `resize_window`, `minimize_window`, `restore_window`, `close_window`
- `click_element`, `write_element_value`, `perform_element_action`
- `find_region_elements`, `get_element`
- `write_clipboard`, `clear_clipboard`, `get_clipboard_history`
- `create_input`, `list_inputs`
- `create_observation`, `get_observation`, `list_observations`, `cancel_observation`
- `execute_apple_script`, `execute_javascript`, `execute_shell_command`, `validate_script`
- `capture_screenshot`, `capture_window_screenshot`, `capture_element_screenshot`, `capture_region_screenshot`
- `create_session`, `get_session`, `list_sessions`, `delete_session`
- `create_macro`, `get_macro`, `list_macros`, `execute_macro`

### Doc05 Actions Requiring New Design (not in doc06)
- `click` (coordinate-based, not element-based)
- `type_text` (simple text injection as doc05 `type`)
- `press_key` (key combo as doc05 `key`)
- `mouse_move`
- `scroll`
- `drag`
- `cursor_position` (new API needed)
- `wait` (delay action)
- `zoom` (high-res region crop, new API needed)

## Schema Issues

1. **`get_display` bug**: Schema defines `display_id`, handler reads `name`
2. **Missing `required` arrays** in tool schemas
3. **No nested selector schema** - `selector` property lacks property enumeration
4. **Inadequate descriptions** - Tools lack content type documentation

## Coordinate System Considerations

The proto API correctly documents Global Display Coordinates (top-left origin). However:

1. **No coordinate validation** before execution
2. **No scaling pipeline** as described in doc05 Section 5.1
3. **No display grounding** in MCP initialize handshake
4. **No multi-monitor targeting** in input tools

## File Structure Deviation

Doc06 specifies:
```
internal/tools/
├── registry.go
├── definitions.go
└── handlers/
    ├── application.go
    ├── window.go
    └── ...
```

Actual:
```
internal/server/
├── mcp.go (all-in-one)
├── element.go, window.go, display.go, clipboard.go
└── tools/helpers.go
```

## Recommendations Summary

### Immediate Actions (P0)
1. Implement `capture_screenshot` tool with scaling/resizing
2. Implement `click` tool for coordinate-based clicking
3. Implement `type_text` tool
4. Implement `press_key` tool

### Short-term Actions (P1)
5. Implement `is_error` pattern for soft failures
6. Add display grounding to initialize response
7. Implement `mouse_move`, `scroll`, `drag` tools
8. Add `cursor_position` API and tool

### Medium-term Actions (P2)
9. Expose remaining doc06 tools (29 missing)
10. Add A11y states to Element proto
11. Implement Set-of-Marks overlay option
12. Expose streaming observations

### Architectural Actions (P3)
13. Restructure files per doc06 layout
14. Fix schema inconsistencies
15. Implement SSE transport
16. Add security intercept layer

## Verification Notes

- **TRUSTED**: Proto schema content (directly read)
- **TRUSTED**: mcp.go implementation (directly read)
- **TRUSTED**: Gap analysis methodology (systematic comparison)
- **VERIFIED**: Build passes with current 5 tools
