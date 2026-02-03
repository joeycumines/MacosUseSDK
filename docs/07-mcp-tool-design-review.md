# MCP Tool Design Review: Comprehensive Analysis

**Review Date:** 2026-02-03  
**Reviewer:** Takumi (匠)  
**Documents Reviewed:**
- `docs/06-mcp-tool-design.md` (Design Document)
- `docs/05-mcp-integration.md` (Research Document)
- Proto definitions in `proto/macosusesdk/v1/`
- Implementation in `internal/server/`

---

## Executive Summary

**Status:** PRODUCTION-READY with IDENTIFIED IMPROVEMENTS

The MCP tool implementation (39 tools) is fundamentally sound and aligns with the research document's architectural principles. This review identifies critical gaps between documented design and research-backed best practices, plus implementation inconsistencies that require attention to guarantee PR correctness with maximum alignment to cutting-edge MCP standards.

**Critical Findings:**
1. **Coordinate System Documentation Gap:** Research doc specifies detailed coordinate scaling (1.54× factor from 1568→1024), but MCP implementation lacks coordinate normalization
2. **Missing Tools vs. Proto:** Proto exposes `capture_window_screenshot` but MCP tool is absent
3. **Observation Pattern Mismatch:** Research specifies streaming `StreamObservations` RPC, but MCP only supports polling via `create_observation`
4. **Gesture Tool Incomplete:** Research documents multi-touch gestures with 2D scrolling, but implementation lacks `pinch` and `zoom` gesture variants
5. **Error Handling Inconsistency:** Research specifies structured `is_error` semantics, but implementation doesn't follow Anthropic's expected format
6. **Transport Mode Limitation:** Current implementation only supports stdio transport; SSE/HTTP endpoint mode is required for streaming capabilities

---

## 1. Alignment Analysis: Research vs. Design vs. Implementation

### 1.1 Tool Completeness Matrix

| Category | Research | Design Doc | Proto | Implemented | Gap |
|----------|----------|------------|-------|-------------|-----|
| Screenshot | capture_screenshot, capture_region_screenshot, capture_window_screenshot | 2 tools | 4 RPCs | 2 tools | **MISSING** capture_window_screenshot |
| Input | click, type, key, mouse_move, scroll, drag, left_mouse_down/up, hold_key, cursor_position | 8 tools | 8 types | 8 tools | **MISSING** left_mouse_down/up, hold_key, cursor_position |
| Element | find, get, click, write, action | 5 tools | 6 RPCs | 5 tools | **MISSING** get_element_actions |
| Window | list, get, focus, move, resize, minimize, restore, close | 8 tools | 8 RPCs | 8 tools | ✓ |
| Display | list, get | 2 tools | 2 RPCs | 2 tools | ✓ |
| Clipboard | get, write, clear, history | 3 tools | 4 RPCs | 3 tools | **MISSING** get_clipboard_history |
| Application | open, list, get, delete | 4 tools | 4 RPCs | 4 tools | ✓ |
| Scripting | apple_script, javascript, shell, validate | 3 tools | 5 RPCs | 3 tools | **MISSING** validate_script |
| Observation | create, get, list, cancel, stream | 4 tools | 7 RPCs | 4 tools | **MISSING** stream_observations |
| **TOTAL** | ~55 | 39 | ~50 | 39 | **11 missing** |

### 1.2 Critical Gaps Requiring Resolution

#### Gap #1: `capture_window_screenshot` Tool Missing
**Severity:** HIGH  
**Research Requirement:** The research document emphasizes "screenshot-based visual feedback loops" and window-specific capture is critical for VS Code multi-window workflows.

**Proto Definition:**
```proto
rpc CaptureWindowScreenshot(CaptureWindowScreenshotRequest) returns (CaptureWindowScreenshotResponse)
```

**Current Implementation:** Not present in `mcp.go` tool registry.

**Required Action:** ADD `capture_window_screenshot` tool.

#### Gap #2: `get_clipboard_history` Tool Missing
**Severity:** MEDIUM  
**Research Reference:** Clipboard history is essential for workflow continuity.

**Proto Definition:**
```proto
rpc GetClipboardHistory(GetClipboardHistoryRequest) returns (ClipboardHistory)
```

**Current Implementation:** Documented as "deferred" but proto is complete.

**Required Action:** ADD `get_clipboard_history` tool.

#### Gap #3: `validate_script` Tool Missing
**Severity:** MEDIUM  
**Research Reference:** Pre-execution validation prevents catastrophic errors (e.g., `rm -rf`).

**Proto Definition:**
```proto
rpc ValidateScript(ValidateScriptRequest) returns (ValidateScriptResponse)
```

**Current Implementation:** Documented as "deferred."

**Required Action:** ADD `validate_script` tool.

#### Gap #4: `stream_observations` Tool Missing
**Severity:** HIGH  
**Research Reference:** The research document emphasizes "streaming accessibility tree changes" as a core capability. Current polling-only approach introduces latency.

**Proto Definition:**
```proto
rpc StreamObservations(StreamObservationsRequest) returns (stream StreamObservationsResponse)
```

**Current Implementation:** Only polling-based `create_observation` (returns operation) is exposed.

**Required Action:** ADD `stream_observations` tool (long-running streaming call).

#### Gap #5: `get_element_actions` Tool Missing
**Severity:** MEDIUM  
**Research Reference:** Accessibility action discovery is critical for "element-centric" interaction patterns.

**Proto Definition:**
```proto
rpc GetElementActions(GetElementActionsRequest) returns (ElementActions)
```

**Current Implementation:** Not in MCP tool registry.

**Required Action:** ADD `get_element_actions` tool.

---

## 2. Coordinate System Compliance Analysis

### 2.1 Research Document Requirements

The research document (docs/05-mcp-integration.md, Section 5.1) specifies a critical **Coordinate Scaling Pipeline**:

```
1. Capture: Screen at W_native, H_native
2. Resscale to W_model, H_model (preserving aspect ratio)
3. Inference: Model predicts atize: Down (x_model, y_model)
4. Upscaling: x_native = x_model × (W_native / W_model)
```

**Key insight:** Anthropic's API handles images up to ~1568px on longest edge. The typical resize is 1568→1024 (1.54× factor).

### 2.2 Current Implementation Analysis

**docs/06-mcp-tool-design.md** states:
> "Input coordinates (clicks, mouse moves) sent via `CreateInput` are interpreted as **Global Display Coordinates** (top-left origin)."

**Implementation (`internal/server/input.go`):**
```go
// handleClick passes coordinates directly without scaling
Position: &typepb.Point{
    X: params.X,
    Y: params.Y,
}
```

### 2.3 Problem Identified

**CRITICAL ISSUE:** The MCP tool does NOT perform coordinate scaling from model-space to native-space.

When Claude Desktop (or any MCP Host) resizes a 2560×1440 screenshot to fit context window limits (e.g., 1024×576), it generates predictions in scaled coordinates. The MCP server receives these scaled coordinates and passes them directly to the gRPC server without inverse transformation.

**Example:**
- Native display: 2560×1440
- Model sees: 1024×576 (resized by MCP Host)
- Model predicts click at (512, 288) [center of scaled image]
- MCP server passes (512, 288) to gRPC
- Actual click happens at wrong location

### 2.4 Required Action

The MCP server needs coordinate normalization support. However, this is complex because:

1. MCP hosts (Claude Desktop, etc.) perform their own coordinate scaling
2. The server doesn't know the scaling factor used by the host
3. Different MCP hosts may use different strategies

**REQUIRED ACTION:** Implement coordinate scaling support by adding `scaling_factor` parameter to input tools or require MCP hosts to pass native coordinates. Add `max_width`/`max_height` parameters to screenshot tools (already implemented) so hosts can compute scaling.

---

## 3. Input Tool Completeness vs. Research

### 3.1 Research-Required Input Actions

The research document (Table 2, Section 2.1.2) specifies:
- `left_mouse_down` / `left_mouse_up` (stateful for complex gestures)
- `hold_key` (hold modifier for duration)
- `cursor_position` (get current mouse position)

### 3.2 Proto Availability

**Proto DOES NOT support these operations:**
- No `GetCursorPosition` RPC in `input.proto`
- No `duration` field in `KeyPress` message for `hold_key`
- No separate mouse down/up input types (only `MouseClick`)

### 3.3 Resolution Required

**Current State:** The design doc correctly identifies these as "Blocked by Proto Limitations."

**REQUIRED ACTION:** Proto changes are needed before these tools can be implemented. This is tracked in the design doc's "Not Yet Implemented" section and must be addressed.

---

## 4. Gesture Tool Analysis

### 4.1 Research Requirements

Research document specifies gesture types:
- Pinch (zoom out)
- Zoom (zoom in)  
- Rotate
- Swipe
- Force touch

### 4.2 Current Implementation

**Proto Definition (`input.proto`):**
```proto
message Gesture {
  GestureType gesture_type = 2;
  double scale = 3;       // For pinch/zoom
  double rotation = 4;    // For rotation
  int32 finger_count = 5; // For swipe
  Direction direction = 6; // For swipe
}
```

**MCP Tool Input Schema:**
```json
{
  "gesture_type": "pinch|zoom|rotate|swipe|force_touch",
  "scale": 0.5,    // e.g., 0.5 = zoom out, 2.0 = zoom in
  "rotation": 45,  // degrees
  "finger_count": 2
}
```

### 4.3 Issue: Missing Direction Enum in Tool

The proto defines `Direction` enum but the tool's `handleGesture` function only checks `params.Direction` after it's already processed. Looking at `handleGesture` in `input.go`:

```go
// Map direction string to proto enum
directionPB := pb.Gesture_DIRECTION_UNSPECIFIED
switch strings.ToLower(params.Direction) {
case "up":
    directionPB = pb.Gesture_DIRECTION_UP
// ... etc
}
```

This IS implemented correctly. The issue is the **tool schema** doesn't include `direction` as a property for non-swipe gestures, which is confusing.

**REQUIRED ACTION:** Update gesture tool schema to clarify `direction` is for swipe only, OR add it conditionally.

---

## 5. Observation Tool Architecture Mismatch

### 5.1 Research Pattern: Streaming Events

Research emphasizes streaming for real-time monitoring:
> "The Harness handles the translation of the abstract MCP protocol into concrete OS events."

The `StreamObservations` RPC provides:
```proto
rpc StreamObservations(StreamObservationsRequest) returns (stream StreamObservationsResponse)
```

### 5.2 Current Implementation: Polling Only

**MCP Tool (`create_observation`):**
```go
// Returns operation name, requires polling to get results
op, err := s.client.CreateObservation(ctx, &pb.CreateObservationRequest{...})
```

**Issue:** This creates a long-running operation but doesn't expose streaming. The client must poll `GetObservation` to check state changes.

### 5.3 Required Action

ADD `stream_observations` tool that:
1. Accepts observation name
2. Returns a streaming response of `ObservationEvent` messages
3. Client consumes events until completion/cancellation

**Complexity:** Requires handling streaming over stdio (JSON-RPC). MCP protocol supports this via SSE in HTTP transport, but stdio transport is simpler. Alternative: Add polling-interval parameter to `create_observation` and use `notifications` for events.

---

## 6. Error Handling Compliance

### 6.1 Research Specification

Research (Section 2.3.2) specifies:
> "The harness does not crash. Instead, it returns a tool_result with the is_error: true flag."

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01...",
  "content": [{"type": "text", "text": "Coordinate out of bounds"}],
  "is_error": true
}
```

### 6.2 Current Implementation

**Implementation (`mcp.go`):**
```go
resultMap := map[string]interface{}{
    "content": result.Content,
}
if result.IsError {
    resultMap["isError"] = true
}
```

**Issue:** The key is `isError` (camelCase) but research specifies `is_error` (snake_case). Both are technically valid, but for consistency with Anthropic's expected format, we should match the research specification.

### 6.3 Required Action

Change `isError` to `is_error` in tool response marshaling.

---

## 7. Display Grounding Verification

### 7.1 Research Requirement

Display grounding is critical for coordinate-based operations:
```json
{
  "display_width_px": 1024,
  "display_height_px": 768,
  "display_number": 1
}
```

### 7.2 Implementation Verification

**Initialize Response (`mcp.go`):**
```go
displayInfo := s.getDisplayGroundingInfo()
// Returns: {"display_width_px": 2560, "display_height_px": 1440, ...}
```

**Issue:** Implementation returns all displays info but the format doesn't match Anthropic's expected structure exactly.

**REQUIRED ACTION:** Align `displayInfo` structure with Anthropic's convention:
```json
{
  "display_width_px": <main_width>,
  "display_height_px": <main_height>,
  "display_number": <main_display_index>
}
```

---

## 8. Tool Schema Precision Issues

### 8.1 Click Tool Schema

**Current Schema:**
```json
{
  "button": {"enum": ["left", "right", "middle"]},
  "click_count": {"description": "1=single, 2=double, 3=triple"}
}
```

**Issue:** Missing `click_count` from required fields (should be required for predictable double-click behavior).

### 8.2 Type Text Schema

**Current Schema:**
```json
{
  "text": {"type": "string"},
  "char_delay": {"type": "number"}
}
```

**Issue:** Missing `use_ime` in description (documented but description is incomplete).

### 8.3 Required Actions

1. Add `click_count` to required fields in click tool
2. Complete `type_text` schema with full `use_ime` documentation
3. Add `page_size` and `page_token` parameters to paginated tools

---

## 9. Pagination Implementation Gaps

### 9.1 Research Requirement (AIP-158)

All List/Find RPCs MUST implement:
- `page_size` 
- `page_token`
- `next_page_token`

### 9.2 Current Tool Schemas

**Missing pagination parameters:**
- `list_windows` - no pagination
- `list_applications` - has `page_size`, `page_token` ✓
- `list_observations` - has `page_size`, `page_token` ✓
- `list_displays` - no pagination (but typically 1-4 displays, low priority)
- `find_elements` - has `page_size`, `page_token` ✓

### 9.3 Required Actions

1. Add pagination to `list_windows`
2. Document that `page_token` is opaque (no internal structure assumptions)

---

## 10. Test Coverage Analysis

### 10.1 Existing Tests

**`internal/server/mcp_test.go`** provides:
- Tool call JSON marshaling
- Tool result JSON marshaling  
- Enum value alignment tests
- Schema structure tests
- All 39 tools existence validation
- Naming convention validation
- Click button mapping
- Modifier string mapping
- Coordinate validation
- Click count defaulting

### 10.2 Test Gaps

**Missing tests for:**
- Pagination token round-trip
- Error response format (`is_error` key)
- Display grounding response format
- Streaming observation (not implemented)
- Coordinate scaling (not implemented)

### 10.3 Required Actions

ADD tests:
1. `TestPaginationTokenOpaque` - verify page tokens are opaque
2. `TestErrorResponseFormat` - verify `is_error` field
3. `TestDisplayGroundingFormat` - verify init response structure

---

## 11. MCP Transport Mode Implementation

### 11.1 Transport Mode Requirements

The MCP protocol specification requires support for multiple transport mechanisms to enable different use cases and deployment scenarios. The implementation MUST support both standard IO mode and Server-Sent Events (SSE) HTTP endpoint mode for complete protocol compliance and maximum flexibility.

#### 11.1.1 Standard IO Mode (Required)
**Specification:** MCP/stdio transport as defined in the protocol specification.

**Implementation Requirements:**
- Single stdin/stdout communication channel
- JSON-RPC 2.0 message framing over text streams
- Blocking synchronous request/response patterns
- Parent process lifecycle binding
- No external network dependencies

**Current Implementation Status:** ✓ Implemented in `transport/stdio.go`

#### 11.1.2 Server-Sent Events (SSE) HTTP Endpoint Mode (Required)
**Specification:** MCP/sse transport for HTTP-based streaming communication.

**Implementation Requirements:**
- HTTP POST endpoint for client-to-server messages
- SSE endpoint for server-to-client streaming (events)
- Long-running HTTP connections for streaming responses
- Support for `Last-Event-ID` header for reconnection
- Connection lifecycle management (heartbeat, timeout, cleanup)
- CORS headers for cross-origin requests
- Separate JSON-RPC message framing for HTTP body

**Implementation Architecture:**
```
HTTP Transport Layer
├── POST /message (JSON-RPC requests)
├── GET /events (SSE streaming responses)
├── Heartbeat mechanism (30s interval)
├── Connection registry (track active connections)
└── Cleanup goroutine (remove stale connections)
```

**Required Implementation Components:**

1. **HTTP Server Initialization (`transport/http.go`):**
   ```go
   type HTTPTransport struct {
       server          *http.Server
       connections     map[string]*SSEConnection
       messageHandler  MessageHandler
       heartbeatTick   time.Duration
   }
   ```

2. **SSE Connection Management:**
   ```go
   type SSEConnection struct {
       id              string
       eventChan       chan []byte
       lastEventID     string
       createdAt       time.Time
       lastActivity    time.Time
   }
   ```

3. **Message Framing (HTTP Body):**
   ```go
   func (t *HTTPTransport) handleMessage(w http.ResponseWriter, r *http.Request) {
       var request JSONRPCMessage
       decoder := json.NewDecoder(r.Body)
       decoder.Decode(&request)
       // Process request and send response via SSE
   }
   ```

4. **SSE Event Streaming:**
   ```go
   func (c *SSEConnection) writeEvent(eventType string, data []byte) error {
       event := fmt.Sprintf("event: %s\ndata: %s\n\n", eventType, data)
       _, err := c.writer.Write([]byte(event))
       return err
   }
   ```

5. **Heartbeat Mechanism:**
   ```go
   func (c *SSEConnection) startHeartbeat() {
       ticker := time.NewTicker(30 * time.Second)
       for range ticker.C {
           c.writeEvent("heartbeat", []byte("ping"))
       }
   }
   ```

6. **Connection Registry:**
   ```go
   type ConnectionRegistry struct {
       connections sync.Map
       mu          sync.RWMutex
   }
   
   func (r *ConnectionRegistry) Add(conn *SSEConnection)
   func (r *ConnectionRegistry) Remove(id string)
   func (r *ConnectionRegistry) Get(id string) (*SSEConnection, bool)
   ```

### 11.2 Transport Selection Mechanism

**Environment Variable Configuration:**
```bash
# Standard IO mode (default)
MCP_TRANSPORT=stdio

# HTTP SSE mode with custom port
MCP_TRANSPORT=sse
MCP_HTTP_PORT=8080

# HTTP SSE mode with custom socket
MCP_TRANSPORT=sse
MCP_HTTP_SOCKET=/tmp/mcp-server.sock
```

**Configuration Priority:**
1. `MCP_TRANSPORT` environment variable
2. Default to stdio if not specified
3. Port/socket configuration overrides

### 11.3 Streaming Capabilities by Transport

| Capability | stdio | SSE/HTTP |
|------------|-------|----------|
| Request/Response | ✓ | ✓ |
| Notifications | ✓ | ✓ |
| Streaming Responses | ✗ | ✓ |
| Long-running Operations | Polling | SSE events |
| Real-time Updates | ✗ | ✓ |
| Observation Streaming | ✗ | ✓ (required) |

### 11.4 Required Actions for Transport Implementation

1. ADD `transport/http.go` implementing HTTP/SSE transport layer
2. ADD connection registry for active SSE connections
3. ADD heartbeat mechanism (30-second ping interval)
4. ADD CORS headers for web client compatibility
5. ADD `Last-Event-ID` header handling for reconnection
6. ADD configuration parsing for HTTP port/socket
7. ADD graceful shutdown handler for HTTP server
8. ADD transport selection in main server initialization
9. ADD transport-specific logging (OSLog for HTTP server)
10. ADD integration tests for SSE streaming scenarios

---

## 12. Mandatory Implementation Task List

The following tasks are **MANDATORY** for maximum alignment with cutting-edge MCP standards and optimal implementation outcomes. All tasks must be completed to ensure the highest quality, best outcome implementation.

### 12.1 Critical Tool Implementation Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T1 | ADD `capture_window_screenshot` tool | Missing Tool | `internal/server/mcp.go`, `docs/06-mcp-tool-design.md` |
| T2 | ADD `stream_observations` tool | Missing Tool | `internal/server/mcp.go`, `docs/06-mcp-tool-design.md` |
| T3 | ADD `get_clipboard_history` tool | Missing Tool | `internal/server/mcp.go`, `docs/06-mcp-tool-design.md` |
| T4 | ADD `validate_script` tool | Missing Tool | `internal/server/mcp.go`, `docs/06-mcp-tool-design.md` |
| T5 | ADD `get_element_actions` tool | Missing Tool | `internal/server/mcp.go`, `docs/06-mcp-tool-design.md` |

### 12.2 Bug Fix Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T6 | Fix `isError` → `is_error` | Bug | `internal/server/mcp.go` |
| T7 | Align display grounding format | Spec Compliance | `internal/server/mcp.go` |
| T8 | Implement coordinate scaling support | Feature | `internal/server/input.go`, `docs/06-mcp-tool-design.md` |

### 12.3 Schema and Specification Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T9 | Add pagination to `list_windows` | AIP Compliance | `internal/server/mcp.go` |
| T10 | Add `click_count` to required fields in click tool | Schema Precision | `internal/server/mcp.go` |
| T11 | Complete `type_text` schema with `use_ime` documentation | Schema Precision | `internal/server/mcp.go` |
| T12 | Update gesture tool schema (direction clarification) | Schema Precision | `internal/server/mcp.go` |

### 12.4 Transport Mode Implementation Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T13 | ADD `transport/http.go` implementing HTTP/SSE transport | Transport | `transport/http.go` |
| T14 | ADD SSE connection registry management | Transport | `transport/http.go` |
| T15 | ADD heartbeat mechanism (30-second ping interval) | Transport | `transport/http.go` |
| T16 | ADD CORS headers for web client compatibility | Transport | `transport/http.go` |
| T17 | ADD `Last-Event-ID` header handling for reconnection | Transport | `transport/http.go` |
| T18 | ADD configuration parsing for HTTP port/socket | Transport | `internal/config/`, `transport/http.go` |
| T19 | ADD graceful shutdown handler for HTTP server | Transport | `transport/http.go` |
| T20 | ADD transport selection in main server initialization | Transport | `internal/server/mcp.go`, `cmd/mcp-tool/main.go` |
| T21 | ADD transport-specific logging (OSLog) | Transport | `transport/http.go`, `Sources/MacosUseSDK/SDKLogger.swift` |

### 12.5 Test Coverage Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T22 | ADD `TestPaginationTokenOpaque` | Test | `internal/server/mcp_test.go` |
| T23 | ADD `TestErrorResponseFormat` | Test | `internal/server/mcp_test.go` |
| T24 | ADD `TestDisplayGroundingFormat` | Test | `internal/server/mcp_test.go` |
| T25 | ADD SSE streaming integration tests | Test | `integration/transport_test.go` |
| T26 | ADD HTTP transport configuration tests | Test | `internal/config/config_test.go` |

### 12.6 Documentation Tasks

| ID | Description | Category | File(s) |
|----|-------------|----------|---------|
| T27 | Document coordinate scaling limitation | Documentation | `docs/06-mcp-tool-design.md` |
| T28 | Document HTTP/SSE transport configuration | Documentation | `docs/06-mcp-tool-design.md` |
| T29 | Update tool count in design doc (44 total) | Documentation | `docs/06-mcp-tool-design.md` |
| T30 | Document streaming observation usage | Documentation | `docs/06-mcp-tool-design.md` |

---

## 13. Verification Checklist

Before PR approval, verify all mandatory items:

- [ ] **Build Passes:** `make all` completes without errors
- [ ] **Tests Pass:** `make test` or `go test ./internal/server/...` passes
- [ ] **All 44 Tools Implemented:** Count matches updated design doc
- [ ] **Schema Validation:** Tool schemas are valid JSON Schema
- [ ] **Enum Alignment:** All proto enums have corresponding string mappings
- [ ] **Pagination Compliance:** All list tools have page_size/page_token
- [ ] **Error Format:** Response uses `is_error` (not `isError`)
- [ ] **Display Grounding:** Initialize response matches expected format
- [ ] **Documentation Updated:** `docs/06-mcp-tool-design.md` reflects actual implementation
- [ ] **Transport Modes:** Both stdio and SSE/HTTP modes functional
- [ ] **Streaming Support:** `stream_observations` tool operates correctly via SSE
- [ ] **Heartbeat Functionality:** SSE connections maintain heartbeat
- [ ] **Reconnection Support:** `Last-Event-ID` header processed correctly

---

## Appendix A: Tool Count Verification

**Expected Tools After Implementation:** 44

| Category | Current | After Implementation |
|----------|---------|----------------------|
| Screenshot | 2 | 3 |
| Input | 8 | 8 |
| Element | 5 | 6 |
| Window | 8 | 8 |
| Display | 2 | 2 |
| Clipboard | 3 | 4 |
| Application | 4 | 4 |
| Scripting | 3 | 4 |
| Observation | 4 | 5 |
| **TOTAL** | **39** | **44** |

**Note:** The additional tools are:
- `capture_window_screenshot`
- `stream_observations`
- `get_clipboard_history`
- `validate_script`
- `get_element_actions`

---

## Appendix B: Proto vs. Tool Mapping

| Proto RPC | MCP Tool | Status |
|-----------|----------|--------|
| CaptureScreenshot | capture_screenshot | ✓ |
| CaptureWindowScreenshot | capture_window_screenshot | **MISSING** |
| CaptureRegionScreenshot | capture_region_screenshot | ✓ |
| CreateInput (Click) | click | ✓ |
| CreateInput (TypeText) | type_text | ✓ |
| CreateInput (PressKey) | press_key | ✓ |
| CreateInput (MoveMouse) | mouse_move | ✓ |
| CreateInput (Scroll) | scroll | ✓ |
| CreateInput (Drag) | drag | ✓ |
| CreateInput (Hover) | hover | ✓ |
| CreateInput (Gesture) | gesture | ✓ |
| FindElements | find_elements | ✓ |
| GetElement | get_element | ✓ |
| GetElementActions | get_element_actions | **MISSING** |
| ClickElement | click_element | ✓ |
| WriteElementValue | write_element_value | ✓ |
| PerformElementAction | perform_element_action | ✓ |
| ListWindows | list_windows | ✓ |
| GetWindow | get_window | ✓ |
| FocusWindow | focus_window | ✓ |
| MoveWindow | move_window | ✓ |
| ResizeWindow | resize_window | ✓ |
| MinimizeWindow | minimize_window | ✓ |
| RestoreWindow | restore_window | ✓ |
| CloseWindow | close_window | ✓ |
| ListDisplays | list_displays | ✓ |
| GetDisplay | get_display | ✓ |
| GetClipboard | get_clipboard | ✓ |
| WriteClipboard | write_clipboard | ✓ |
| ClearClipboard | clear_clipboard | ✓ |
| GetClipboardHistory | get_clipboard_history | **MISSING** |
| OpenApplication | open_application | ✓ |
| ListApplications | list_applications | ✓ |
| GetApplication | get_application | ✓ |
| DeleteApplication | delete_application | ✓ |
| ExecuteAppleScript | execute_apple_script | ✓ |
| ExecuteJavaScript | execute_javascript | ✓ |
| ExecuteShellCommand | execute_shell_command | ✓ |
| ValidateScript | validate_script | **MISSING** |
| CreateObservation | create_observation | ✓ |
| GetObservation | get_observation | ✓ |
| ListObservations | list_observations | ✓ |
| CancelObservation | cancel_observation | ✓ |
| StreamObservations | stream_observations | **MISSING** |

---

## Appendix C: Transport Mode Configuration Reference

### C.1 Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MCP_TRANSPORT` | No | `stdio` | Transport mode selection (`stdio` or `sse`) |
| `MCP_HTTP_PORT` | No | `8080` | HTTP server port for SSE mode |
| `MCP_HTTP_SOCKET` | No | - | Unix domain socket path for SSE mode |
| `MCP_HEARTBEAT_INTERVAL` | No | `30` | Heartbeat interval in seconds |
| `MCP_CONNECTION_TIMEOUT` | No | `300` | Connection timeout in seconds |

### C.2 Endpoints (SSE Mode)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/message` | POST | JSON-RPC message endpoint |
| `/events` | GET | SSE streaming endpoint |
| `/health` | GET | Health check endpoint |
| `/metrics` | GET | Prometheus metrics endpoint |

### C.3 SSE Event Types

| Event Type | Description |
|------------|-------------|
| `message` | JSON-RPC response or notification |
| `heartbeat` | Keep-alive ping (30s interval) |
| `error` | Connection-level errors |
| `complete` | Streaming response completion |

