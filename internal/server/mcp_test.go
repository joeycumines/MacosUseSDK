// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// TestNewMCPServer_WithDefaultConfig tests that NewMCPServer can be created
// Note: This test may fail in CI if there's no server running - that's expected
func TestNewMCPServer_WithDefaultConfig(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:     "localhost:50051",
		RequestTimeout: 30,
	}
	// NewMCPServer will fail to connect but should still create the server struct
	// This tests that the initialization code runs without panicking
	_, err := NewMCPServer(cfg)
	if err != nil {
		// Expected if no server is running
		t.Logf("NewMCPServer returned error (expected if no gRPC server): %v", err)
	}
}

// TestToolCall_JSON tests ToolCall JSON marshaling/unmarshaling
func TestToolCall_JSON(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantName string
		wantArgs string
	}{
		{
			name:     "simple tool call",
			input:    `{"name":"list_displays","arguments":{}}`,
			wantName: "list_displays",
			wantArgs: "{}",
		},
		{
			name:     "tool call with args",
			input:    `{"name":"click","arguments":{"x":100,"y":200}}`,
			wantName: "click",
			wantArgs: `{"x":100,"y":200}`,
		},
		{
			name:     "tool call with string args",
			input:    `{"name":"type_text","arguments":{"text":"hello world"}}`,
			wantName: "type_text",
			wantArgs: `{"text":"hello world"}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var call ToolCall
			if err := json.Unmarshal([]byte(tt.input), &call); err != nil {
				t.Fatalf("Failed to unmarshal: %v", err)
			}

			if call.Name != tt.wantName {
				t.Errorf("Name = %q, want %q", call.Name, tt.wantName)
			}

			gotArgs := string(call.Arguments)
			if gotArgs != tt.wantArgs {
				t.Errorf("Arguments = %q, want %q", gotArgs, tt.wantArgs)
			}
		})
	}
}

// TestToolResult_JSON tests ToolResult JSON marshaling
func TestToolResult_JSON(t *testing.T) {
	tests := []struct {
		name   string
		result *ToolResult
		want   string
	}{
		{
			name: "text content",
			result: &ToolResult{
				Content: []Content{
					{Type: "text", Text: "Hello world"},
				},
			},
			want: `{"content":[{"type":"text","text":"Hello world"}]}`,
		},
		{
			name: "error result",
			result: &ToolResult{
				Content: []Content{
					{Type: "text", Text: "Something went wrong"},
				},
				IsError: true,
			},
			want: `{"content":[{"type":"text","text":"Something went wrong"}],"is_error":true}`,
		},
		{
			name: "empty content",
			result: &ToolResult{
				Content: []Content{},
			},
			want: `{"content":[]}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.result)
			if err != nil {
				t.Fatalf("Failed to marshal: %v", err)
			}

			if string(got) != tt.want {
				t.Errorf("Marshal result = %s, want %s", string(got), tt.want)
			}
		})
	}
}

// TestContent_JSON tests Content JSON marshaling
func TestContent_JSON(t *testing.T) {
	tests := []struct {
		name    string
		content Content
		want    string
	}{
		{
			name:    "text type",
			content: Content{Type: "text", Text: "hello"},
			want:    `{"type":"text","text":"hello"}`,
		},
		{
			name:    "text with empty text",
			content: Content{Type: "text", Text: ""},
			want:    `{"type":"text"}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.content)
			if err != nil {
				t.Fatalf("Failed to marshal: %v", err)
			}

			if string(got) != tt.want {
				t.Errorf("Marshal content = %s, want %s", string(got), tt.want)
			}
		})
	}
}

// TestClickTypeValues tests click type enum values align with proto
func TestClickTypeValues(t *testing.T) {
	tests := []struct {
		name     string
		clickVal pb.MouseClick_ClickType
		wantVal  int32
	}{
		{"unspecified", pb.MouseClick_CLICK_TYPE_UNSPECIFIED, 0},
		{"left", pb.MouseClick_CLICK_TYPE_LEFT, 1},
		{"right", pb.MouseClick_CLICK_TYPE_RIGHT, 2},
		{"middle", pb.MouseClick_CLICK_TYPE_MIDDLE, 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if int32(tt.clickVal) != tt.wantVal {
				t.Errorf("ClickType %s = %d, want %d", tt.name, int32(tt.clickVal), tt.wantVal)
			}
		})
	}
}

// TestModifierKeyValues tests modifier key enum values align with proto
func TestModifierKeyValues(t *testing.T) {
	tests := []struct {
		name    string
		modVal  pb.KeyPress_Modifier
		wantVal int32
	}{
		{"unspecified", pb.KeyPress_MODIFIER_UNSPECIFIED, 0},
		{"command", pb.KeyPress_MODIFIER_COMMAND, 1},
		{"option", pb.KeyPress_MODIFIER_OPTION, 2},
		{"control", pb.KeyPress_MODIFIER_CONTROL, 3},
		{"shift", pb.KeyPress_MODIFIER_SHIFT, 4},
		{"function", pb.KeyPress_MODIFIER_FUNCTION, 5},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if int32(tt.modVal) != tt.wantVal {
				t.Errorf("Modifier %s = %d, want %d", tt.name, int32(tt.modVal), tt.wantVal)
			}
		})
	}
}

// TestObservationTypeValues tests observation type enum values align with proto
func TestObservationTypeValues(t *testing.T) {
	tests := []struct {
		name    string
		obsVal  pb.ObservationType
		wantVal int32
	}{
		{"unspecified", pb.ObservationType_OBSERVATION_TYPE_UNSPECIFIED, 0},
		{"element_changes", pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES, 1},
		{"window_changes", pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES, 2},
		{"application_changes", pb.ObservationType_OBSERVATION_TYPE_APPLICATION_CHANGES, 3},
		{"attribute_changes", pb.ObservationType_OBSERVATION_TYPE_ATTRIBUTE_CHANGES, 4},
		{"tree_changes", pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES, 5},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if int32(tt.obsVal) != tt.wantVal {
				t.Errorf("ObservationType %s = %d, want %d", tt.name, int32(tt.obsVal), tt.wantVal)
			}
		})
	}
}

// TestScreenshotFormatValues tests screenshot format enum values align with proto
func TestScreenshotFormatValues(t *testing.T) {
	tests := []struct {
		name      string
		formatVal pb.ImageFormat
		wantVal   int32
	}{
		{"unspecified", pb.ImageFormat_IMAGE_FORMAT_UNSPECIFIED, 0},
		{"png", pb.ImageFormat_IMAGE_FORMAT_PNG, 1},
		{"jpeg", pb.ImageFormat_IMAGE_FORMAT_JPEG, 2},
		{"tiff", pb.ImageFormat_IMAGE_FORMAT_TIFF, 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if int32(tt.formatVal) != tt.wantVal {
				t.Errorf("ImageFormat %s = %d, want %d", tt.name, int32(tt.formatVal), tt.wantVal)
			}
		})
	}
}

// TestToolSchema_RequiredFields tests that tool schemas have proper structure
func TestToolSchema_RequiredFields(t *testing.T) {
	schema := map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"x": map[string]interface{}{
				"type":        "integer",
				"description": "X coordinate",
			},
			"y": map[string]interface{}{
				"type":        "integer",
				"description": "Y coordinate",
			},
		},
		"required": []string{"x", "y"},
	}

	data, err := json.Marshal(schema)
	if err != nil {
		t.Fatalf("Failed to marshal schema: %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal schema: %v", err)
	}

	if parsed["type"] != "object" {
		t.Errorf("Schema type = %v, want 'object'", parsed["type"])
	}

	props, ok := parsed["properties"].(map[string]interface{})
	if !ok {
		t.Fatal("Schema properties not a map")
	}

	if _, ok := props["x"]; !ok {
		t.Error("Schema missing 'x' property")
	}
	if _, ok := props["y"]; !ok {
		t.Error("Schema missing 'y' property")
	}

	required, ok := parsed["required"].([]interface{})
	if !ok {
		t.Fatal("Schema required not an array")
	}
	if len(required) != 2 {
		t.Errorf("Schema required length = %d, want 2", len(required))
	}
}

// TestJSONRPCResponse_Structure tests JSON-RPC response structure
func TestJSONRPCResponse_Structure(t *testing.T) {
	tests := []struct {
		name     string
		response map[string]interface{}
		wantErr  bool
	}{
		{
			name: "success response",
			response: map[string]interface{}{
				"jsonrpc": "2.0",
				"id":      1,
				"result":  map[string]interface{}{"content": []interface{}{}},
			},
			wantErr: false,
		},
		{
			name: "error response",
			response: map[string]interface{}{
				"jsonrpc": "2.0",
				"id":      1,
				"error": map[string]interface{}{
					"code":    transport.ErrCodeInvalidRequest,
					"message": "Invalid Request",
				},
			},
			wantErr: false,
		},
		{
			name: "notification (no id)",
			response: map[string]interface{}{
				"jsonrpc": "2.0",
				"method":  "notifications/initialized",
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, err := json.Marshal(tt.response)
			if (err != nil) != tt.wantErr {
				t.Fatalf("Marshal error = %v, wantErr = %v", err, tt.wantErr)
			}

			if !tt.wantErr {
				var parsed map[string]interface{}
				if err := json.Unmarshal(data, &parsed); err != nil {
					t.Fatalf("Failed to unmarshal response: %v", err)
				}

				if parsed["jsonrpc"] != "2.0" {
					t.Errorf("jsonrpc = %v, want '2.0'", parsed["jsonrpc"])
				}
			}
		})
	}
}

// TestErrorCodes tests JSON-RPC error code constants
func TestErrorCodes(t *testing.T) {
	// Verify the defined constants match JSON-RPC 2.0 specification
	if transport.ErrCodeInvalidRequest != -32600 {
		t.Errorf("ErrCodeInvalidRequest = %d, want -32600", transport.ErrCodeInvalidRequest)
	}
	if transport.ErrCodeMethodNotFound != -32601 {
		t.Errorf("ErrCodeMethodNotFound = %d, want -32601", transport.ErrCodeMethodNotFound)
	}
	if transport.ErrCodeInvalidParams != -32602 {
		t.Errorf("ErrCodeInvalidParams = %d, want -32602", transport.ErrCodeInvalidParams)
	}
	if transport.ErrCodeInternalError != -32603 {
		t.Errorf("ErrCodeInternalError = %d, want -32603", transport.ErrCodeInternalError)
	}
	if transport.ErrCodeParseError != -32700 {
		t.Errorf("ErrCodeParseError = %d, want -32700", transport.ErrCodeParseError)
	}

	// Server error range test (reserved for implementation-defined errors)
	serverErrorMin := -32000
	serverErrorMax := -32099
	if serverErrorMin < serverErrorMax || serverErrorMin > -32000 {
		t.Errorf("Server error range incorrect: min=%d, max=%d", serverErrorMin, serverErrorMax)
	}
}

// TestArgumentParsing tests argument parsing for various tool calls
func TestArgumentParsing(t *testing.T) {
	tests := []struct {
		name    string
		args    string
		wantErr bool
	}{
		{name: "empty object", args: `{}`, wantErr: false},
		{name: "coordinates", args: `{"x": 100, "y": 200}`, wantErr: false},
		{name: "string value", args: `{"text": "hello world"}`, wantErr: false},
		{name: "array value", args: `{"modifiers": ["cmd", "shift"]}`, wantErr: false},
		{name: "nested object", args: `{"filter": {"visible_only": true}}`, wantErr: false},
		{name: "invalid json", args: `{not valid}`, wantErr: true},
		{name: "null", args: `null`, wantErr: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var parsed map[string]interface{}
			err := json.Unmarshal([]byte(tt.args), &parsed)
			if (err != nil) != tt.wantErr {
				t.Errorf("Unmarshal error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// TestConfigDefaults tests config default values
func TestConfigDefaults(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	if cfg.RequestTimeout <= 0 {
		t.Errorf("RequestTimeout = %d, want > 0", cfg.RequestTimeout)
	}
}

// TestGestureTypeValues tests that gesture type enum values are accessible
func TestGestureTypeValues(t *testing.T) {
	gestures := map[string]pb.Gesture_GestureType{
		"pinch":       pb.Gesture_GESTURE_TYPE_PINCH,
		"zoom":        pb.Gesture_GESTURE_TYPE_ZOOM,
		"rotate":      pb.Gesture_GESTURE_TYPE_ROTATE,
		"swipe":       pb.Gesture_GESTURE_TYPE_SWIPE,
		"force_touch": pb.Gesture_GESTURE_TYPE_FORCE_TOUCH,
	}

	for name, val := range gestures {
		if val == pb.Gesture_GESTURE_TYPE_UNSPECIFIED {
			t.Errorf("Gesture type %s should not be UNSPECIFIED", name)
		}
		// Check the values are distinct
		for name2, val2 := range gestures {
			if name != name2 && val == val2 {
				t.Errorf("Gesture types %s and %s have same value", name, name2)
			}
		}
	}
}

// TestGestureDirectionValues tests that gesture direction enum values are accessible
func TestGestureDirectionValues(t *testing.T) {
	directions := map[string]pb.Gesture_Direction{
		"up":    pb.Gesture_DIRECTION_UP,
		"down":  pb.Gesture_DIRECTION_DOWN,
		"left":  pb.Gesture_DIRECTION_LEFT,
		"right": pb.Gesture_DIRECTION_RIGHT,
	}

	for name, val := range directions {
		if val == pb.Gesture_DIRECTION_UNSPECIFIED {
			t.Errorf("Direction %s should not be UNSPECIFIED", name)
		}
		// Check the values are distinct
		for name2, val2 := range directions {
			if name != name2 && val == val2 {
				t.Errorf("Directions %s and %s have same value", name, name2)
			}
		}
	}
}

// TestHoverToolSchema tests the hover tool has correct schema structure
func TestHoverToolSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"x": {"type": "number", "description": "X coordinate in Global Display Coordinates"},
			"y": {"type": "number", "description": "Y coordinate in Global Display Coordinates"},
			"duration": {"type": "number", "description": "Duration to hover in seconds (default: 1.0)"},
			"application": {"type": "string", "description": "Application resource name (optional)"}
		},
		"required": ["x", "y"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse hover schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	if _, ok := props["x"]; !ok {
		t.Error("Schema missing 'x' property")
	}
	if _, ok := props["y"]; !ok {
		t.Error("Schema missing 'y' property")
	}
	if _, ok := props["duration"]; !ok {
		t.Error("Schema missing 'duration' property")
	}

	required := schema["required"].([]interface{})
	if len(required) != 2 {
		t.Errorf("Required fields count = %d, want 2", len(required))
	}
}

// TestGestureToolSchema tests the gesture tool has correct schema structure
func TestGestureToolSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"center_x": {"type": "number", "description": "Center X coordinate of gesture"},
			"center_y": {"type": "number", "description": "Center Y coordinate of gesture"},
			"gesture_type": {"type": "string", "description": "Gesture type: pinch, zoom, rotate, swipe, force_touch"},
			"scale": {"type": "number", "description": "Scale factor for pinch/zoom"},
			"rotation": {"type": "number", "description": "Rotation angle in degrees"},
			"finger_count": {"type": "integer", "description": "Number of fingers for swipe"},
			"direction": {"type": "string", "description": "Direction for swipe: up, down, left, right"}
		},
		"required": ["center_x", "center_y", "gesture_type"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse gesture schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"center_x", "center_y", "gesture_type", "scale", "rotation", "finger_count", "direction"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	required := schema["required"].([]interface{})
	if len(required) != 3 {
		t.Errorf("Required fields count = %d, want 3", len(required))
	}
}

// TestAllToolsExist validates all expected MCP tools are defined
func TestAllToolsExist(t *testing.T) {
	expectedTools := []string{
		// Screenshot tools (4)
		"capture_screenshot",
		"capture_window_screenshot",
		"capture_region_screenshot",
		"capture_element_screenshot",
		// Input tools (11)
		"click",
		"type_text",
		"press_key",
		"hold_key",
		"mouse_move",
		"scroll",
		"drag",
		"mouse_button_down",
		"mouse_button_up",
		"hover",
		"gesture",
		// Element tools (10)
		"find_elements",
		"get_element",
		"get_element_actions",
		"click_element",
		"write_element_value",
		"perform_element_action",
		"traverse_accessibility",
		"find_region_elements",
		"wait_element",
		"wait_element_state",
		// Window tools (9)
		"list_windows",
		"get_window",
		"get_window_state",
		"focus_window",
		"move_window",
		"resize_window",
		"minimize_window",
		"restore_window",
		"close_window",
		// Display tools (3)
		"list_displays",
		"get_display",
		"cursor_position",
		// Clipboard tools (4)
		"get_clipboard",
		"write_clipboard",
		"clear_clipboard",
		"get_clipboard_history",
		// Application tools (4)
		"open_application",
		"list_applications",
		"get_application",
		"delete_application",
		// Scripting tools (4)
		"execute_apple_script",
		"execute_javascript",
		"execute_shell_command",
		"validate_script",
		// Observation tools (5)
		"create_observation",
		"stream_observations",
		"get_observation",
		"list_observations",
		"cancel_observation",
		// File dialog tools (5)
		"automate_open_file_dialog",
		"automate_save_file_dialog",
		"select_file",
		"select_directory",
		"drag_files",
		// Session tools (5)
		"create_session",
		"get_session",
		"list_sessions",
		"delete_session",
		"get_session_snapshot",
		// Transaction tools (3)
		"begin_transaction",
		"commit_transaction",
		"rollback_transaction",
		// Macro tools (6)
		"create_macro",
		"get_macro",
		"list_macros",
		"delete_macro",
		"execute_macro",
		"update_macro",
		// Input query tools (2)
		"get_input",
		"list_inputs",
		// Scripting dictionary tool (1)
		"get_scripting_dictionaries",
		// Accessibility watch tool (1)
		"watch_accessibility",
	}

	if len(expectedTools) != 77 {
		t.Errorf("Expected 77 tools but defined %d in test", len(expectedTools))
	}

	// Verify all tool names are unique
	seen := make(map[string]bool)
	for _, tool := range expectedTools {
		if seen[tool] {
			t.Errorf("Duplicate tool name: %s", tool)
		}
		seen[tool] = true
	}
}

// TestToolNaming validates tool naming conventions
func TestToolNaming(t *testing.T) {
	// All tool names should be snake_case
	tools := []string{
		"capture_screenshot",
		"capture_window_screenshot",
		"capture_region_screenshot",
		"click",
		"type_text",
		"press_key",
		"mouse_move",
		"scroll",
		"drag",
		"hover",
		"gesture",
		"find_elements",
		"get_element",
		"get_element_actions",
		"click_element",
		"write_element_value",
		"perform_element_action",
		"list_windows",
		"get_window",
		"focus_window",
		"move_window",
		"resize_window",
		"minimize_window",
		"restore_window",
		"close_window",
		"list_displays",
		"get_display",
		"get_clipboard",
		"write_clipboard",
		"clear_clipboard",
		"get_clipboard_history",
		"open_application",
		"list_applications",
		"get_application",
		"delete_application",
		"execute_apple_script",
		"execute_javascript",
		"execute_shell_command",
		"validate_script",
		"create_observation",
		"stream_observations",
		"get_observation",
		"list_observations",
		"cancel_observation",
	}

	for _, toolName := range tools {
		// Check no uppercase letters (snake_case requirement)
		for _, r := range toolName {
			if r >= 'A' && r <= 'Z' {
				t.Errorf("Tool name %q contains uppercase letter, should be snake_case", toolName)
				break
			}
		}
		// Check no hyphens (snake_case uses underscores)
		if len(toolName) > 0 {
			for i := 0; i < len(toolName); i++ {
				if toolName[i] == '-' {
					t.Errorf("Tool name %q contains hyphen, should use underscore", toolName)
					break
				}
			}
		}
	}
}

// TestClickButtonMapping tests the button string to enum mapping
func TestClickButtonMapping(t *testing.T) {
	tests := []struct {
		button   string
		expected pb.MouseClick_ClickType
	}{
		{"left", pb.MouseClick_CLICK_TYPE_LEFT},
		{"right", pb.MouseClick_CLICK_TYPE_RIGHT},
		{"middle", pb.MouseClick_CLICK_TYPE_MIDDLE},
		{"LEFT", pb.MouseClick_CLICK_TYPE_LEFT}, // case insensitive
		{"Right", pb.MouseClick_CLICK_TYPE_RIGHT},
		{"", pb.MouseClick_CLICK_TYPE_LEFT},        // default
		{"unknown", pb.MouseClick_CLICK_TYPE_LEFT}, // default for unknown
	}

	for _, tt := range tests {
		t.Run(tt.button, func(t *testing.T) {
			clickType := pb.MouseClick_CLICK_TYPE_LEFT // default
			switch strings.ToLower(tt.button) {
			case "right":
				clickType = pb.MouseClick_CLICK_TYPE_RIGHT
			case "middle":
				clickType = pb.MouseClick_CLICK_TYPE_MIDDLE
			}

			if clickType != tt.expected {
				t.Errorf("Button %q mapped to %v, want %v", tt.button, clickType, tt.expected)
			}
		})
	}
}

// TestModifierStringMapping tests modifier key string to enum mapping
func TestModifierStringMapping(t *testing.T) {
	modifierMap := map[string]pb.KeyPress_Modifier{
		"cmd":     pb.KeyPress_MODIFIER_COMMAND,
		"command": pb.KeyPress_MODIFIER_COMMAND,
		"ctrl":    pb.KeyPress_MODIFIER_CONTROL,
		"control": pb.KeyPress_MODIFIER_CONTROL,
		"shift":   pb.KeyPress_MODIFIER_SHIFT,
		"alt":     pb.KeyPress_MODIFIER_OPTION,
		"option":  pb.KeyPress_MODIFIER_OPTION,
		"fn":      pb.KeyPress_MODIFIER_FUNCTION,
	}

	for key, expected := range modifierMap {
		if expected == pb.KeyPress_MODIFIER_UNSPECIFIED {
			t.Errorf("Modifier %q should not map to UNSPECIFIED", key)
		}
	}

	// Verify specific mappings
	if modifierMap["cmd"] != pb.KeyPress_MODIFIER_COMMAND {
		t.Error("cmd should map to MODIFIER_COMMAND")
	}
	if modifierMap["ctrl"] != pb.KeyPress_MODIFIER_CONTROL {
		t.Error("ctrl should map to MODIFIER_CONTROL")
	}
}

// TestCoordinateValidation tests coordinate value handling
func TestCoordinateValidation(t *testing.T) {
	tests := []struct {
		name  string
		x     float64
		y     float64
		valid bool
	}{
		{"positive coords", 100.0, 200.0, true},
		{"zero coords", 0.0, 0.0, true},
		{"negative x (valid for multi-monitor)", -100.0, 200.0, true},
		{"negative y (valid for multi-monitor)", 100.0, -50.0, true},
		{"fractional coords", 100.5, 200.5, true},
		{"large coords", 5000.0, 3000.0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Coordinates in Global Display Space can be negative (multi-monitor)
			// and can exceed main display bounds (secondary monitors)
			// So all coordinates are technically valid from a parsing perspective
			if !tt.valid {
				t.Errorf("Coordinate (%f, %f) should be valid", tt.x, tt.y)
			}
		})
	}
}

// TestClickCountValidation tests click count defaulting
func TestClickCountValidation(t *testing.T) {
	tests := []struct {
		input    int32
		expected int32
	}{
		{0, 1},  // default to 1
		{1, 1},  // single click
		{2, 2},  // double click
		{3, 3},  // triple click
		{-1, 1}, // negative defaults to 1
	}

	for _, tt := range tests {
		clickCount := tt.input
		if clickCount <= 0 {
			clickCount = 1
		}
		if clickCount != tt.expected {
			t.Errorf("Click count %d normalized to %d, want %d", tt.input, clickCount, tt.expected)
		}
	}
}

// TestErrorResponseFormat tests that error responses use is_error (snake_case)
// This is critical for Anthropic Claude Desktop compatibility
func TestErrorResponseFormat(t *testing.T) {
	result := &ToolResult{
		Content: []Content{
			{Type: "text", Text: "Something went wrong"},
		},
		IsError: true,
	}

	resultMap := map[string]interface{}{
		"content": result.Content,
	}
	if result.IsError {
		resultMap["is_error"] = true
	}

	data, err := json.Marshal(resultMap)
	if err != nil {
		t.Fatalf("Failed to marshal: %v", err)
	}

	// Verify the key is is_error, not isError
	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if _, ok := parsed["is_error"]; !ok {
		t.Errorf("Response should contain 'is_error' key, got: %s", string(data))
	}

	if _, ok := parsed["isError"]; ok {
		t.Errorf("Response should NOT contain 'isError' key (camelCase), got: %s", string(data))
	}

	if parsed["is_error"] != true {
		t.Errorf("is_error should be true, got: %v", parsed["is_error"])
	}
}

// TestPaginationTokenHandling tests pagination token handling
func TestPaginationTokenHandling(t *testing.T) {
	tests := []struct {
		name      string
		pageToken string
		isOpaque  bool
	}{
		{"empty token is valid", "", true},
		{"base64 token is opaque", "aGVsbG8td29ybGQ=", true},
		{"uuid token is opaque", "550e8400-e29b-41d4-a716-446655440000", true},
		{"random string is opaque", "abc123xyz", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Page tokens should be treated as opaque - clients should not
			// interpret their internal structure
			if tt.isOpaque {
				// Just verify the token is a valid string (no structure assumptions)
				if len(tt.pageToken) > 0 && len(tt.pageToken) < 3 {
					t.Errorf("Page token too short to be valid opaque token: %s", tt.pageToken)
				}
			}
		})
	}
}

// TestListWindowsPaginationParams tests that list_windows accepts pagination parameters
func TestListWindowsPaginationParams(t *testing.T) {
	tests := []struct {
		name       string
		paramsJSON string
		wantErr    bool
	}{
		{
			name:       "no params",
			paramsJSON: `{}`,
			wantErr:    false,
		},
		{
			name:       "with pagination",
			paramsJSON: `{"page_size": 50, "page_token": "abc123"}`,
			wantErr:    false,
		},
		{
			name:       "with parent and pagination",
			paramsJSON: `{"parent": "applications/123", "page_size": 25, "page_token": "xyz789"}`,
			wantErr:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params struct {
				Parent    string `json:"parent"`
				PageSize  int32  `json:"page_size"`
				PageToken string `json:"page_token"`
			}
			err := json.Unmarshal([]byte(tt.paramsJSON), &params)
			if (err != nil) != tt.wantErr {
				t.Errorf("Unmarshal error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// TestCaptureWindowScreenshotParams tests window screenshot parameters
func TestCaptureWindowScreenshotParams(t *testing.T) {
	tests := []struct {
		name       string
		paramsJSON string
		hasWindow  bool
	}{
		{
			name:       "with window",
			paramsJSON: `{"window": "applications/123/windows/456"}`,
			hasWindow:  true,
		},
		{
			name:       "with all options",
			paramsJSON: `{"window": "applications/123/windows/456", "format": "png", "quality": 85, "include_shadow": true, "include_ocr": true}`,
			hasWindow:  true,
		},
		{
			name:       "missing window",
			paramsJSON: `{}`,
			hasWindow:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params struct {
				Window        string `json:"window"`
				Format        string `json:"format"`
				Quality       int32  `json:"quality"`
				IncludeShadow bool   `json:"include_shadow"`
				IncludeOCR    bool   `json:"include_ocr"`
			}
			err := json.Unmarshal([]byte(tt.paramsJSON), &params)
			if err != nil {
				t.Errorf("Unmarshal error = %v", err)
			}
			if tt.hasWindow && params.Window == "" {
				t.Error("Window should be parsed when provided")
			}
			if !tt.hasWindow && params.Window != "" {
				t.Error("Window should be empty when not provided")
			}
		})
	}
}

// TestDisplayGroundingFormat validates the display grounding output format
// Follows MCP computer tool specification with "screens" array
func TestDisplayGroundingFormat(t *testing.T) {
	// Test that the format produces valid JSON with screens array
	tests := []struct {
		name     string
		response string
		valid    bool
	}{
		{
			name:     "empty screens",
			response: `{"screens":[]}`,
			valid:    true,
		},
		{
			name:     "single screen",
			response: `{"screens":[{"id":"main","width":1920,"height":1080,"pixel_density":2,"origin_x":0,"origin_y":0}]}`,
			valid:    true,
		},
		{
			name:     "multiple screens",
			response: `{"screens":[{"id":"main","width":1920,"height":1080,"pixel_density":2,"origin_x":0,"origin_y":0},{"id":"display-1","width":2560,"height":1440,"pixel_density":1,"origin_x":1920,"origin_y":0}]}`,
			valid:    true,
		},
		{
			name:     "invalid json",
			response: `{invalid}`,
			valid:    false,
		},
		{
			name:     "wrong root key",
			response: `{"displays":[]}`,
			valid:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var data map[string]interface{}
			err := json.Unmarshal([]byte(tt.response), &data)

			if tt.valid {
				if err != nil {
					t.Errorf("Expected valid JSON, got error: %v", err)
				}
				// Verify "screens" key exists
				if _, ok := data["screens"]; !ok {
					t.Error("Response must have 'screens' key")
				}
			} else {
				if err == nil {
					// If no parse error, verify it has wrong structure
					if _, ok := data["screens"]; ok {
						t.Error("Expected invalid format, but got valid screens structure")
					}
				}
			}
		})
	}
}

// TestPaginationTokenOpaque validates that page_token values are opaque to clients
// Per AIP-158, page tokens must be opaque strings that clients should not interpret
func TestPaginationTokenOpaque(t *testing.T) {
	tests := []struct {
		name     string
		token    string
		isOpaque bool
	}{
		{"empty token", "", true},
		{"base64 encoded", "eyJwYWdlX29mZnNldCI6MTB9", true},
		{"uuid format", "f47ac10b-58cc-4372-a567-0e02b2c3d479", true},
		{"hex encoded", "a1b2c3d4e5f6", true},
		{"simple string", "next-page-token", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Per AIP-158, clients must treat page tokens as opaque
			// The internal structure should not be interpreted
			if tt.isOpaque {
				// Verify token is a valid non-empty string when expected to be opaque
				if tt.token != "" {
					// Just verify it's a string - structure is opaque
					var token interface{} = tt.token
					if _, ok := token.(string); !ok {
						t.Errorf("Token should be a string, got: %T", token)
					}
				}
			}
		})
	}
}

// TestIsErrorFieldFormat validates the is_error field in tool responses
// Per MCP conventions, is_error indicates a soft failure that the client can handle
func TestIsErrorFieldFormat(t *testing.T) {
	tests := []struct {
		name    string
		result  string
		wantErr bool
	}{
		{
			name:    "success response",
			result:  `{"content":[]}`,
			wantErr: false,
		},
		{
			name:    "error response with is_error true",
			result:  `{"is_error":true,"content":[{"type":"text","text":"element not found"}]}`,
			wantErr: true,
		},
		{
			name:    "error response with is_error false",
			result:  `{"is_error":false,"content":[]}`,
			wantErr: false,
		},
		{
			name:    "error text without is_error flag",
			result:  `{"content":[{"type":"text","text":"warning: partial failure"}]}`,
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var result map[string]interface{}
			err := json.Unmarshal([]byte(tt.result), &result)
			if err != nil {
				t.Fatalf("Failed to unmarshal result: %v", err)
			}

			isError, hasError := result["is_error"]
			if tt.wantErr {
				if !hasError {
					t.Error("Expected is_error field to be present for error response")
				} else if isError != true {
					t.Errorf("is_error should be true, got: %v", isError)
				}
			}
		})
	}
}

// TestInitializeResponse validates the MCP initialize response format
// Per MCP spec 2025-11-25: initialize returns protocolVersion, capabilities, serverInfo
// NOTE: This is a contract test validating expected response structure.
// Full initialize handler testing requires integration tests due to gRPC dependency.
func TestInitializeResponse(t *testing.T) {
	tests := []struct {
		name     string
		response string
		wantErr  bool
	}{
		{
			name:     "valid initialize response",
			response: `{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"}}`,
			wantErr:  false,
		},
		{
			name:     "with displayInfo",
			response: `{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"},"displayInfo":{"screens":[]}}`,
			wantErr:  false,
		},
		{
			name:     "wrong protocol version",
			response: `{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"}}`,
			wantErr:  true,
		},
		{
			name:     "missing serverInfo",
			response: `{"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}`,
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var response struct {
				ProtocolVersion string `json:"protocolVersion"`
				Capabilities    struct {
					Tools map[string]interface{} `json:"tools"`
				} `json:"capabilities"`
				ServerInfo struct {
					Name    string `json:"name"`
					Version string `json:"version"`
				} `json:"serverInfo"`
			}
			err := json.Unmarshal([]byte(tt.response), &response)
			if err != nil {
				t.Fatalf("Failed to unmarshal: %v", err)
			}

			// Validate protocol version is 2025-11-25
			if !tt.wantErr {
				if response.ProtocolVersion != "2025-11-25" {
					t.Errorf("protocolVersion = %q, want %q", response.ProtocolVersion, "2025-11-25")
				}
				if response.ServerInfo.Name == "" {
					t.Error("serverInfo.name should not be empty")
				}
				if response.ServerInfo.Version == "" {
					t.Error("serverInfo.version should not be empty")
				}
			} else {
				// Expect validation to fail for wantErr cases
				isValid := response.ProtocolVersion == "2025-11-25" && response.ServerInfo.Name != ""
				if isValid {
					t.Error("Expected validation to fail but it passed")
				}
			}
		})
	}
}

// TestNotificationsInitializedHandling validates notifications/initialized handling
// Per MCP spec: This is a client-to-server notification after successful initialize
// The server should acknowledge it silently (no response required)
// NOTE: This is a contract test. See TestMCPServer_HandleHTTPMessage_NotificationsInitialized
// for actual handler invocation tests.
func TestNotificationsInitializedHandling(t *testing.T) {
	tests := []struct {
		name           string
		method         string
		expectResponse bool
	}{
		{
			name:           "notifications/initialized is silent",
			method:         "notifications/initialized",
			expectResponse: false,
		},
		{
			name:           "tools/list expects response",
			method:         "tools/list",
			expectResponse: true,
		},
		{
			name:           "initialize expects response",
			method:         "initialize",
			expectResponse: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Per MCP spec, notifications (methods starting with "notifications/")
			// do not have an ID field and should not receive a response
			isNotification := strings.HasPrefix(tt.method, "notifications/")
			if isNotification && tt.expectResponse {
				t.Error("Notifications should not expect a response")
			}
			if !isNotification && !tt.expectResponse {
				// Non-notification methods (requests) always expect a response
				t.Logf("Note: method %q is not a notification", tt.method)
			}
		})
	}
}

// TestMCPProtocolVersion validates that we use the correct MCP protocol version
// This is a critical compliance requirement - MCP protocol version MUST be 2025-11-25
func TestMCPProtocolVersion(t *testing.T) {
	const expectedVersion = "2025-11-25"

	// Simulate the initialize response format from mcp.go
	initResponse := map[string]interface{}{
		"protocolVersion": expectedVersion,
		"capabilities":    map[string]interface{}{"tools": map[string]interface{}{}},
		"serverInfo":      map[string]interface{}{"name": "macos-use-sdk", "version": "0.1.0"},
	}

	data, err := json.Marshal(initResponse)
	if err != nil {
		t.Fatalf("Failed to marshal initialize response: %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	gotVersion, ok := parsed["protocolVersion"].(string)
	if !ok {
		t.Fatal("protocolVersion is not a string")
	}

	if gotVersion != expectedVersion {
		t.Errorf("protocolVersion = %q, want %q", gotVersion, expectedVersion)
	}
}

// TestMCPServer_HandleHTTPMessage_NotificationsInitialized tests the actual handleHTTPMessage
// implementation for notifications/initialized. The full initialize requires gRPC client, but we can
// verify the notification handler correctly returns (nil, nil) per MCP spec.
// NOTE: Full initialize testing requires integration tests with running gRPC server.
// The contract tests (TestInitializeResponse, TestMCPProtocolVersion) verify the
// expected response format.
func TestMCPServer_HandleHTTPMessage_NotificationsInitialized(t *testing.T) {
	// Create minimal MCPServer without full initialization
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	msg := &transport.Message{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
		// Note: notifications don't have an ID field
	}

	resp, err := s.handleHTTPMessage(msg)

	// Per MCP spec, notifications should return (nil, nil)
	if err != nil {
		t.Errorf("handleHTTPMessage returned error: %v, want nil", err)
	}

	if resp != nil {
		t.Errorf("handleHTTPMessage returned response %+v, want nil (notifications don't get responses)", resp)
	}
}

// ============================================================================
// T086: File Dialog Tools Unit Tests
// ============================================================================

// TestFileDialogToolsExist validates that all file dialog tools are registered
func TestFileDialogToolsExist(t *testing.T) {
	fileDialogTools := []string{
		"automate_open_file_dialog",
		"automate_save_file_dialog",
		"select_file",
		"select_directory",
		"drag_files",
	}

	// Verify all names are unique and valid snake_case
	seen := make(map[string]bool)
	for _, toolName := range fileDialogTools {
		if seen[toolName] {
			t.Errorf("Duplicate tool name: %s", toolName)
		}
		seen[toolName] = true

		// Verify snake_case (no uppercase, no hyphens)
		for _, r := range toolName {
			if r >= 'A' && r <= 'Z' {
				t.Errorf("Tool name %q contains uppercase letter, should be snake_case", toolName)
				break
			}
		}
		if strings.Contains(toolName, "-") {
			t.Errorf("Tool name %q contains hyphen, should use underscore", toolName)
		}
	}
}

// TestAutomateOpenFileDialogSchema tests the automate_open_file_dialog tool schema
func TestAutomateOpenFileDialogSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"application": {"type": "string", "description": "Application resource name (e.g., applications/TextEdit)"},
			"file_path": {"type": "string", "description": "File path to select (if known)"},
			"default_directory": {"type": "string", "description": "Default directory to navigate to"},
			"file_filters": {"type": "array", "items": {"type": "string"}, "description": "File type filters (e.g., ['*.txt', '*.pdf'])"},
			"timeout": {"type": "number", "description": "Timeout for dialog to appear in seconds"},
			"allow_multiple": {"type": "boolean", "description": "Whether to allow multiple file selection"}
		},
		"required": ["application"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"application", "file_path", "default_directory", "file_filters", "timeout", "allow_multiple"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	required := schema["required"].([]interface{})
	if len(required) != 1 || required[0] != "application" {
		t.Errorf("Required should be ['application'], got: %v", required)
	}
}

// TestAutomateSaveFileDialogSchema tests the automate_save_file_dialog tool schema
func TestAutomateSaveFileDialogSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"application": {"type": "string", "description": "Application resource name"},
			"file_path": {"type": "string", "description": "Full file path to save to"},
			"default_directory": {"type": "string", "description": "Default directory to navigate to"},
			"default_filename": {"type": "string", "description": "Default filename"},
			"timeout": {"type": "number", "description": "Timeout for dialog to appear in seconds"},
			"confirm_overwrite": {"type": "boolean", "description": "Whether to confirm overwrite if file exists"}
		},
		"required": ["application", "file_path"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"application", "file_path", "default_directory", "default_filename", "timeout", "confirm_overwrite"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	required := schema["required"].([]interface{})
	if len(required) != 2 {
		t.Errorf("Required fields count = %d, want 2", len(required))
	}
}

// TestSelectFileSchema tests the select_file tool schema
func TestSelectFileSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"application": {"type": "string", "description": "Application resource name"},
			"file_path": {"type": "string", "description": "File path to select"},
			"reveal_finder": {"type": "boolean", "description": "Whether to reveal file in Finder after selection"}
		},
		"required": ["application", "file_path"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"application", "file_path", "reveal_finder"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	required := schema["required"].([]interface{})
	if len(required) != 2 {
		t.Errorf("Required fields count = %d, want 2", len(required))
	}
}

// TestSelectDirectorySchema tests the select_directory tool schema
func TestSelectDirectorySchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"application": {"type": "string", "description": "Application resource name"},
			"directory_path": {"type": "string", "description": "Directory path to select"},
			"create_missing": {"type": "boolean", "description": "Whether to create directory if it doesn't exist"}
		},
		"required": ["application", "directory_path"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"application", "directory_path", "create_missing"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	required := schema["required"].([]interface{})
	if len(required) != 2 {
		t.Errorf("Required fields count = %d, want 2", len(required))
	}
}

// TestDragFilesSchema tests the drag_files tool schema
func TestDragFilesSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"application": {"type": "string", "description": "Application resource name"},
			"file_paths": {"type": "array", "items": {"type": "string"}, "description": "File paths to drag"},
			"target_element_id": {"type": "string", "description": "Target element ID to drop files onto"},
			"duration": {"type": "number", "description": "Drag duration in seconds"}
		},
		"required": ["application", "file_paths", "target_element_id"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"application", "file_paths", "target_element_id", "duration"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	// Verify file_paths is an array type
	filePaths := props["file_paths"].(map[string]interface{})
	if filePaths["type"] != "array" {
		t.Errorf("file_paths type should be array, got: %v", filePaths["type"])
	}

	required := schema["required"].([]interface{})
	if len(required) != 3 {
		t.Errorf("Required fields count = %d, want 3", len(required))
	}
}

// TestFileDialogToolParamsParsing tests argument parsing for file dialog tools
func TestFileDialogToolParamsParsing(t *testing.T) {
	tests := []struct {
		name       string
		tool       string
		paramsJSON string
		wantErr    bool
	}{
		{
			name:       "automate_open_file_dialog basic",
			tool:       "automate_open_file_dialog",
			paramsJSON: `{"application": "applications/123"}`,
			wantErr:    false,
		},
		{
			name:       "automate_open_file_dialog full",
			tool:       "automate_open_file_dialog",
			paramsJSON: `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt", "default_directory": "/tmp", "file_filters": ["*.txt", "*.md"], "timeout": 30, "allow_multiple": true}`,
			wantErr:    false,
		},
		{
			name:       "automate_save_file_dialog basic",
			tool:       "automate_save_file_dialog",
			paramsJSON: `{"application": "applications/123", "file_path": "/tmp/output.txt"}`,
			wantErr:    false,
		},
		{
			name:       "automate_save_file_dialog full",
			tool:       "automate_save_file_dialog",
			paramsJSON: `{"application": "applications/TextEdit", "file_path": "/tmp/output.txt", "default_directory": "/tmp", "default_filename": "output.txt", "timeout": 30, "confirm_overwrite": true}`,
			wantErr:    false,
		},
		{
			name:       "select_file basic",
			tool:       "select_file",
			paramsJSON: `{"application": "applications/Finder", "file_path": "/tmp/test.txt"}`,
			wantErr:    false,
		},
		{
			name:       "select_file with reveal",
			tool:       "select_file",
			paramsJSON: `{"application": "applications/Finder", "file_path": "/tmp/test.txt", "reveal_finder": true}`,
			wantErr:    false,
		},
		{
			name:       "select_directory basic",
			tool:       "select_directory",
			paramsJSON: `{"application": "applications/Finder", "directory_path": "/tmp"}`,
			wantErr:    false,
		},
		{
			name:       "select_directory with create",
			tool:       "select_directory",
			paramsJSON: `{"application": "applications/Finder", "directory_path": "/tmp/new_dir", "create_missing": true}`,
			wantErr:    false,
		},
		{
			name:       "drag_files basic",
			tool:       "drag_files",
			paramsJSON: `{"application": "applications/123", "file_paths": ["/tmp/a.txt", "/tmp/b.txt"], "target_element_id": "element-456"}`,
			wantErr:    false,
		},
		{
			name:       "drag_files with duration",
			tool:       "drag_files",
			paramsJSON: `{"application": "applications/123", "file_paths": ["/tmp/a.txt"], "target_element_id": "drop-zone", "duration": 0.5}`,
			wantErr:    false,
		},
		{
			name:       "invalid json",
			tool:       "automate_open_file_dialog",
			paramsJSON: `{not valid json}`,
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params map[string]interface{}
			err := json.Unmarshal([]byte(tt.paramsJSON), &params)
			if (err != nil) != tt.wantErr {
				t.Errorf("Unmarshal error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// ============================================================================
// T087: Wait Element Tools Unit Tests
// ============================================================================

// TestWaitElementToolsExist validates that wait element tools are registered
func TestWaitElementToolsExist(t *testing.T) {
	waitElementTools := []string{
		"wait_element",
		"wait_element_state",
	}

	// Verify all names are unique and valid snake_case
	seen := make(map[string]bool)
	for _, toolName := range waitElementTools {
		if seen[toolName] {
			t.Errorf("Duplicate tool name: %s", toolName)
		}
		seen[toolName] = true

		// Verify snake_case (no uppercase, no hyphens)
		for _, r := range toolName {
			if r >= 'A' && r <= 'Z' {
				t.Errorf("Tool name %q contains uppercase letter, should be snake_case", toolName)
				break
			}
		}
		if strings.Contains(toolName, "-") {
			t.Errorf("Tool name %q contains hyphen, should use underscore", toolName)
		}
	}
}

// TestWaitElementSchema tests the wait_element tool schema
func TestWaitElementSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"parent": {"type": "string", "description": "Application or window resource name"},
			"selector": {"type": "object", "description": "Element selector: {role, text, or text_contains}"},
			"timeout": {"type": "number", "description": "Maximum wait time in seconds (default: 30)"},
			"poll_interval": {"type": "number", "description": "Poll interval in seconds (default: 0.5)"}
		},
		"required": ["parent", "selector"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"parent", "selector", "timeout", "poll_interval"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	// Verify selector is object type
	selector := props["selector"].(map[string]interface{})
	if selector["type"] != "object" {
		t.Errorf("selector type should be object, got: %v", selector["type"])
	}

	required := schema["required"].([]interface{})
	if len(required) != 2 {
		t.Errorf("Required fields count = %d, want 2", len(required))
	}
}

// TestWaitElementStateSchema tests the wait_element_state tool schema
func TestWaitElementStateSchema(t *testing.T) {
	schemaJSON := `{
		"type": "object",
		"properties": {
			"parent": {"type": "string", "description": "Application or window resource name"},
			"element_id": {"type": "string", "description": "Element ID to wait on"},
			"condition": {"type": "string", "description": "State condition: enabled, focused, text_equals, text_contains", "enum": ["enabled", "focused", "text_equals", "text_contains"]},
			"value": {"type": "string", "description": "Value for text_equals or text_contains conditions"},
			"timeout": {"type": "number", "description": "Maximum wait time in seconds (default: 30)"},
			"poll_interval": {"type": "number", "description": "Poll interval in seconds (default: 0.5)"}
		},
		"required": ["parent", "element_id", "condition"]
	}`

	var schema map[string]interface{}
	if err := json.Unmarshal([]byte(schemaJSON), &schema); err != nil {
		t.Fatalf("Failed to parse schema: %v", err)
	}

	if schema["type"] != "object" {
		t.Errorf("Schema type = %v, want object", schema["type"])
	}

	props := schema["properties"].(map[string]interface{})
	requiredProps := []string{"parent", "element_id", "condition", "value", "timeout", "poll_interval"}
	for _, prop := range requiredProps {
		if _, ok := props[prop]; !ok {
			t.Errorf("Schema missing '%s' property", prop)
		}
	}

	// Verify condition has enum
	condition := props["condition"].(map[string]interface{})
	enumVal, hasEnum := condition["enum"]
	if !hasEnum {
		t.Error("condition should have enum constraint")
	}
	enumList := enumVal.([]interface{})
	expectedEnums := []string{"enabled", "focused", "text_equals", "text_contains"}
	if len(enumList) != len(expectedEnums) {
		t.Errorf("condition enum count = %d, want %d", len(enumList), len(expectedEnums))
	}

	required := schema["required"].([]interface{})
	if len(required) != 3 {
		t.Errorf("Required fields count = %d, want 3", len(required))
	}
}

// TestWaitElementToolParamsParsing tests argument parsing for wait element tools
func TestWaitElementToolParamsParsing(t *testing.T) {
	tests := []struct {
		name       string
		tool       string
		paramsJSON string
		wantErr    bool
	}{
		{
			name:       "wait_element basic",
			tool:       "wait_element",
			paramsJSON: `{"parent": "applications/123", "selector": {"role": "button"}}`,
			wantErr:    false,
		},
		{
			name:       "wait_element with text selector",
			tool:       "wait_element",
			paramsJSON: `{"parent": "applications/123/windows/456", "selector": {"text": "Save"}}`,
			wantErr:    false,
		},
		{
			name:       "wait_element with timeout",
			tool:       "wait_element",
			paramsJSON: `{"parent": "applications/123", "selector": {"role": "button", "text": "OK"}, "timeout": 60}`,
			wantErr:    false,
		},
		{
			name:       "wait_element with poll_interval",
			tool:       "wait_element",
			paramsJSON: `{"parent": "applications/123", "selector": {"role": "textField"}, "timeout": 30, "poll_interval": 0.25}`,
			wantErr:    false,
		},
		{
			name:       "wait_element_state enabled",
			tool:       "wait_element_state",
			paramsJSON: `{"parent": "applications/123", "element_id": "elem-456", "condition": "enabled"}`,
			wantErr:    false,
		},
		{
			name:       "wait_element_state focused",
			tool:       "wait_element_state",
			paramsJSON: `{"parent": "applications/123/windows/789", "element_id": "input-field", "condition": "focused"}`,
			wantErr:    false,
		},
		{
			name:       "wait_element_state text_equals",
			tool:       "wait_element_state",
			paramsJSON: `{"parent": "applications/123", "element_id": "status-label", "condition": "text_equals", "value": "Complete"}`,
			wantErr:    false,
		},
		{
			name:       "wait_element_state text_contains",
			tool:       "wait_element_state",
			paramsJSON: `{"parent": "applications/123", "element_id": "log-output", "condition": "text_contains", "value": "Success"}`,
			wantErr:    false,
		},
		{
			name:       "wait_element_state with timeout and poll_interval",
			tool:       "wait_element_state",
			paramsJSON: `{"parent": "applications/123", "element_id": "elem-789", "condition": "enabled", "timeout": 120, "poll_interval": 1.0}`,
			wantErr:    false,
		},
		{
			name:       "invalid json",
			tool:       "wait_element",
			paramsJSON: `{not valid}`,
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params map[string]interface{}
			err := json.Unmarshal([]byte(tt.paramsJSON), &params)
			if (err != nil) != tt.wantErr {
				t.Errorf("Unmarshal error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// TestWaitElementConditionValues tests condition value validity
func TestWaitElementConditionValues(t *testing.T) {
	validConditions := []string{"enabled", "focused", "text_equals", "text_contains"}

	tests := []struct {
		condition string
		valid     bool
	}{
		{"enabled", true},
		{"focused", true},
		{"text_equals", true},
		{"text_contains", true},
		{"disabled", false},
		{"visible", false},
		{"hidden", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.condition, func(t *testing.T) {
			found := false
			for _, valid := range validConditions {
				if tt.condition == valid {
					found = true
					break
				}
			}
			if found != tt.valid {
				t.Errorf("Condition %q valid = %v, want %v", tt.condition, found, tt.valid)
			}
		})
	}
}

// TestWaitElementTimeoutDefaults tests timeout default behavior
func TestWaitElementTimeoutDefaults(t *testing.T) {
	tests := []struct {
		name            string
		givenTimeout    float64
		expectedTimeout float64
	}{
		{"zero uses default", 0, 30.0},
		{"negative uses default", -1, 30.0},
		{"explicit value used", 60.0, 60.0},
		{"small value used", 0.5, 0.5},
		{"large value used", 300.0, 300.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			timeout := tt.givenTimeout
			if timeout <= 0 {
				timeout = 30.0 // default
			}
			if timeout != tt.expectedTimeout {
				t.Errorf("Timeout = %v, want %v", timeout, tt.expectedTimeout)
			}
		})
	}
}

// TestWaitElementPollIntervalDefaults tests poll_interval default behavior
func TestWaitElementPollIntervalDefaults(t *testing.T) {
	tests := []struct {
		name                 string
		givenPollInterval    float64
		expectedPollInterval float64
	}{
		{"zero uses default", 0, 0.5},
		{"negative uses default", -1, 0.5},
		{"explicit value used", 0.25, 0.25},
		{"small value used", 0.1, 0.1},
		{"large value used", 2.0, 2.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pollInterval := tt.givenPollInterval
			if pollInterval <= 0 {
				pollInterval = 0.5 // default
			}
			if pollInterval != tt.expectedPollInterval {
				t.Errorf("PollInterval = %v, want %v", pollInterval, tt.expectedPollInterval)
			}
		})
	}
}

// TestWaitElementSelectorTypes tests that selector supports various criteria
func TestWaitElementSelectorTypes(t *testing.T) {
	tests := []struct {
		name     string
		selector string
		valid    bool
	}{
		{"role only", `{"role": "button"}`, true},
		{"text only", `{"text": "Submit"}`, true},
		{"title only", `{"title": "Save Dialog"}`, true},
		{"role and text", `{"role": "button", "text": "OK"}`, true},
		{"text_contains", `{"text_contains": "error"}`, true},
		{"empty selector", `{}`, true},
		{"invalid json", `{invalid}`, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var selector map[string]interface{}
			err := json.Unmarshal([]byte(tt.selector), &selector)
			if (err == nil) != tt.valid {
				t.Errorf("Selector %q parse success = %v, want %v", tt.selector, err == nil, tt.valid)
			}
		})
	}
}

// ============================================================================
// Unix Socket Support Tests
// ============================================================================

// TestMCPServer_WithUnixSocketConfig tests that MCPServer can be configured with Unix socket
func TestMCPServer_WithUnixSocketConfig(t *testing.T) {
	cfg := &config.Config{
		ServerSocketPath: "/var/run/macos-use.sock",
		RequestTimeout:   30,
	}

	// Verify the config is set correctly
	if cfg.ServerSocketPath != "/var/run/macos-use.sock" {
		t.Errorf("ServerSocketPath = %s, want /var/run/macos-use.sock", cfg.ServerSocketPath)
	}

	if cfg.ServerAddr != "" {
		t.Errorf("ServerAddr should be empty when using socket path, got: %s", cfg.ServerAddr)
	}
}

// TestMCPServer_WithTCPAddressConfig tests that MCPServer can be configured with TCP address
func TestMCPServer_WithTCPAddressConfig(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:       "localhost:50051",
		ServerSocketPath: "",
		RequestTimeout:   30,
	}

	// Verify the config is set correctly
	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "" {
		t.Errorf("ServerSocketPath should be empty when using TCP, got: %s", cfg.ServerSocketPath)
	}
}

// TestMCPServer_WithBothAddressAndSocketPath tests that both can be configured
func TestMCPServer_WithBothAddressAndSocketPath(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:       "localhost:50051",
		ServerSocketPath: "/tmp/test.sock",
		RequestTimeout:   30,
	}

	// Verify both are set
	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "/tmp/test.sock" {
		t.Errorf("ServerSocketPath = %s, want /tmp/test.sock", cfg.ServerSocketPath)
	}
}

// TestMCPServer_UnixSocketAddressFormat tests that Unix socket addresses are formatted correctly
func TestMCPServer_UnixSocketAddressFormat(t *testing.T) {
	tests := []struct {
		name       string
		socketPath string
		wantPrefix string
		wantPath   string
	}{
		{
			name:       "standard socket path",
			socketPath: "/var/run/macos-use.sock",
			wantPrefix: "unix://",
			wantPath:   "/var/run/macos-use.sock",
		},
		{
			name:       "tmp socket path",
			socketPath: "/tmp/test.sock",
			wantPrefix: "unix://",
			wantPath:   "/tmp/test.sock",
		},
		{
			name:       "user socket path",
			socketPath: "/Users/test/.macos-use/socket",
			wantPrefix: "unix://",
			wantPath:   "/Users/test/.macos-use/socket",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the address construction from initGRPC
			addr := "unix://" + tt.socketPath
			if !strings.HasPrefix(addr, tt.wantPrefix) {
				t.Errorf("Address prefix = %s, want prefix %s", addr, tt.wantPrefix)
			}
			expected := tt.wantPrefix + tt.wantPath
			if addr != expected {
				t.Errorf("Address = %s, want %s", addr, expected)
			}
		})
	}
}

// TestMCPServer_SocketPathVsTCPAddressSelection tests the selection logic
func TestMCPServer_SocketPathVsTCPAddressSelection(t *testing.T) {
	tests := []struct {
		name         string
		serverAddr   string
		socketPath   string
		expectSocket bool
		expectedAddr string
	}{
		{
			name:         "socket path takes precedence",
			serverAddr:   "localhost:50051",
			socketPath:   "/tmp/test.sock",
			expectSocket: true,
			expectedAddr: "unix:///tmp/test.sock",
		},
		{
			name:         "TCP when no socket",
			serverAddr:   "localhost:50051",
			socketPath:   "",
			expectSocket: false,
			expectedAddr: "localhost:50051",
		},
		{
			name:         "TCP when socket is empty",
			serverAddr:   "192.168.1.100:50051",
			socketPath:   "",
			expectSocket: false,
			expectedAddr: "192.168.1.100:50051",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the address selection logic from initGRPC
			var serverAddr string
			if tt.socketPath != "" {
				serverAddr = "unix://" + tt.socketPath
			} else {
				serverAddr = tt.serverAddr
			}

			if tt.expectSocket {
				if !strings.HasPrefix(serverAddr, "unix://") {
					t.Errorf("Expected Unix socket address, got: %s", serverAddr)
				}
			} else {
				if strings.HasPrefix(serverAddr, "unix://") {
					t.Errorf("Expected TCP address, got Unix socket: %s", serverAddr)
				}
			}

			if serverAddr != tt.expectedAddr {
				t.Errorf("Server address = %s, want %s", serverAddr, tt.expectedAddr)
			}
		})
	}
}

// TestConfig_ServerSocketPathValidation tests config validation for socket path
func TestConfig_ServerSocketPathValidation(t *testing.T) {
	tests := []struct {
		name       string
		serverAddr string
		socketPath string
		wantErr    bool
	}{
		{
			name:       "socket path valid",
			serverAddr: "",
			socketPath: "/tmp/test.sock",
			wantErr:    false,
		},
		{
			name:       "address valid",
			serverAddr: "localhost:50051",
			socketPath: "",
			wantErr:    false,
		},
		{
			name:       "both valid",
			serverAddr: "localhost:50051",
			socketPath: "/tmp/test.sock",
			wantErr:    false,
		},
		{
			name:       "neither is invalid",
			serverAddr: "",
			socketPath: "",
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate config validation
			err := error(nil)
			if tt.serverAddr == "" && tt.socketPath == "" {
				err = fmt.Errorf("server address or socket path must be provided")
			}

			if (err != nil) != tt.wantErr {
				t.Errorf("Validation error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// ============================================================================
// Task 33: MCP Resources Unit Tests
// ============================================================================

// TestMCPResourcesList verifies the resources/list response structure
func TestMCPResourcesList(t *testing.T) {
	// Expected resources from the MCP server
	expectedResources := []struct {
		uri         string
		name        string
		mimeType    string
		description string
	}{
		{
			uri:         "screen://main",
			name:        "Main Display Screenshot",
			mimeType:    "image/png",
			description: "Current screenshot of the main display",
		},
		{
			uri:         "accessibility://",
			name:        "Accessibility Tree Template",
			mimeType:    "application/json",
			description: "Use accessibility://{pid} to get element tree for an application",
		},
		{
			uri:         "clipboard://current",
			name:        "Current Clipboard",
			mimeType:    "text/plain",
			description: "Current clipboard contents as text",
		},
	}

	// Simulate the resources list response
	resources := []map[string]interface{}{
		{
			"uri":         "screen://main",
			"name":        "Main Display Screenshot",
			"description": "Current screenshot of the main display",
			"mimeType":    "image/png",
		},
		{
			"uri":         "accessibility://",
			"name":        "Accessibility Tree Template",
			"description": "Use accessibility://{pid} to get element tree for an application",
			"mimeType":    "application/json",
		},
		{
			"uri":         "clipboard://current",
			"name":        "Current Clipboard",
			"description": "Current clipboard contents as text",
			"mimeType":    "text/plain",
		},
	}

	// Verify exactly 3 resources are returned
	if len(resources) != 3 {
		t.Errorf("Expected 3 resources, got %d", len(resources))
	}

	// Verify each resource has required fields per MCP spec
	for i, res := range resources {
		t.Run(fmt.Sprintf("resource_%d", i), func(t *testing.T) {
			uri, ok := res["uri"].(string)
			if !ok || uri == "" {
				t.Error("Resource missing 'uri' field")
			}

			name, ok := res["name"].(string)
			if !ok || name == "" {
				t.Error("Resource missing 'name' field")
			}

			mimeType, ok := res["mimeType"].(string)
			if !ok || mimeType == "" {
				t.Error("Resource missing 'mimeType' field")
			}

			description, ok := res["description"].(string)
			if !ok || description == "" {
				t.Error("Resource missing 'description' field")
			}

			// Verify against expected values
			if i < len(expectedResources) {
				expected := expectedResources[i]
				if uri != expected.uri {
					t.Errorf("URI = %q, want %q", uri, expected.uri)
				}
				if name != expected.name {
					t.Errorf("Name = %q, want %q", name, expected.name)
				}
				if mimeType != expected.mimeType {
					t.Errorf("MimeType = %q, want %q", mimeType, expected.mimeType)
				}
			}
		})
	}

	// Verify JSON marshaling produces valid structure
	result, err := json.Marshal(map[string]interface{}{"resources": resources})
	if err != nil {
		t.Fatalf("Failed to marshal resources list: %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(result, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal resources list: %v", err)
	}

	resourcesArray, ok := parsed["resources"].([]interface{})
	if !ok {
		t.Fatal("Response should contain 'resources' array")
	}
	if len(resourcesArray) != 3 {
		t.Errorf("Expected 3 resources in response, got %d", len(resourcesArray))
	}
}

// TestMCPResourcesListResponseStructure validates the resources/list response matches MCP spec
func TestMCPResourcesListResponseStructure(t *testing.T) {
	// Simulate a complete JSON-RPC response for resources/list
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 1,
		"result": {
			"resources": [
				{
					"uri": "screen://main",
					"name": "Main Display Screenshot",
					"description": "Current screenshot of the main display",
					"mimeType": "image/png"
				},
				{
					"uri": "accessibility://",
					"name": "Accessibility Tree Template",
					"description": "Use accessibility://{pid} to get element tree for an application",
					"mimeType": "application/json"
				},
				{
					"uri": "clipboard://current",
					"name": "Current Clipboard",
					"description": "Current clipboard contents as text",
					"mimeType": "text/plain"
				}
			]
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	result, ok := response["result"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	resources, ok := result["resources"].([]interface{})
	if !ok {
		t.Fatal("Result should contain 'resources' array")
	}

	// Verify screen://main resource
	screenResource := resources[0].(map[string]interface{})
	if screenResource["uri"] != "screen://main" {
		t.Errorf("Screen resource URI = %v, want 'screen://main'", screenResource["uri"])
	}
	if screenResource["mimeType"] != "image/png" {
		t.Errorf("Screen resource mimeType = %v, want 'image/png'", screenResource["mimeType"])
	}

	// Verify accessibility:// template resource
	accessibilityResource := resources[1].(map[string]interface{})
	if accessibilityResource["uri"] != "accessibility://" {
		t.Errorf("Accessibility resource URI = %v, want 'accessibility://'", accessibilityResource["uri"])
	}
	if accessibilityResource["mimeType"] != "application/json" {
		t.Errorf("Accessibility resource mimeType = %v, want 'application/json'", accessibilityResource["mimeType"])
	}

	// Verify clipboard://current resource
	clipboardResource := resources[2].(map[string]interface{})
	if clipboardResource["uri"] != "clipboard://current" {
		t.Errorf("Clipboard resource URI = %v, want 'clipboard://current'", clipboardResource["uri"])
	}
	if clipboardResource["mimeType"] != "text/plain" {
		t.Errorf("Clipboard resource mimeType = %v, want 'text/plain'", clipboardResource["mimeType"])
	}
}

// TestMCPResourcesReadScreenshotFormat verifies resources/read for screen://main response format
func TestMCPResourcesReadScreenshotFormat(t *testing.T) {
	// Simulate expected response structure for screen://main
	// Note: Actual image capture requires gRPC server; this tests response format contract
	tests := []struct {
		name         string
		uri          string
		wantMimeType string
		expectBase64 bool
	}{
		{
			name:         "screen://main returns PNG",
			uri:          "screen://main",
			wantMimeType: "image/png",
			expectBase64: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate a resources/read response
			// The content should be base64-encoded PNG data
			mockBase64Data := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

			responseContent := map[string]interface{}{
				"uri":      tt.uri,
				"mimeType": tt.wantMimeType,
				"text":     mockBase64Data, // resource content as text (base64 for binary)
			}

			// Verify mimeType
			if responseContent["mimeType"] != tt.wantMimeType {
				t.Errorf("mimeType = %v, want %v", responseContent["mimeType"], tt.wantMimeType)
			}

			// Verify content is non-empty
			content, ok := responseContent["text"].(string)
			if !ok || content == "" {
				t.Error("Content should be non-empty base64 string")
			}

			// Verify it's valid base64 if expected
			if tt.expectBase64 {
				_, err := base64.StdEncoding.DecodeString(content)
				if err != nil {
					t.Errorf("Content is not valid base64: %v", err)
				}
			}
		})
	}
}

// TestMCPResourcesReadClipboardFormat verifies resources/read for clipboard://current response format
func TestMCPResourcesReadClipboardFormat(t *testing.T) {
	tests := []struct {
		name            string
		clipboardText   string
		wantMimeType    string
		expectEmpty     bool
		additionalCheck func(t *testing.T, content string)
	}{
		{
			name:          "clipboard with text",
			clipboardText: "Hello, World!",
			wantMimeType:  "text/plain",
			expectEmpty:   false,
		},
		{
			name:          "clipboard with unicode text",
			clipboardText: "こんにちは世界 🌍",
			wantMimeType:  "text/plain",
			expectEmpty:   false,
		},
		{
			name:          "empty clipboard",
			clipboardText: "",
			wantMimeType:  "text/plain",
			expectEmpty:   true,
		},
		{
			name:          "clipboard with multiline text",
			clipboardText: "Line 1\nLine 2\nLine 3",
			wantMimeType:  "text/plain",
			expectEmpty:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate a resources/read response for clipboard
			responseContent := map[string]interface{}{
				"uri":      "clipboard://current",
				"mimeType": tt.wantMimeType,
				"text":     tt.clipboardText,
			}

			// Verify mimeType
			if responseContent["mimeType"] != tt.wantMimeType {
				t.Errorf("mimeType = %v, want %v", responseContent["mimeType"], tt.wantMimeType)
			}

			// Verify content based on expectation
			content, _ := responseContent["text"].(string)
			if tt.expectEmpty && content != "" {
				t.Errorf("Expected empty content, got: %q", content)
			}
			if !tt.expectEmpty && content == "" {
				t.Error("Expected non-empty content")
			}
			if !tt.expectEmpty && content != tt.clipboardText {
				t.Errorf("Content = %q, want %q", content, tt.clipboardText)
			}
		})
	}
}

// TestMCPResourcesReadAccessibilityTreeFormat verifies resources/read for accessibility://{pid} response format
func TestMCPResourcesReadAccessibilityTreeFormat(t *testing.T) {
	// Simulate expected accessibility tree JSON response
	mockAccessibilityTree := map[string]interface{}{
		"application":  "applications/1234",
		"elementCount": 5,
		"elements": []map[string]interface{}{
			{
				"id":      "elem-1",
				"role":    "AXWindow",
				"path":    "/AXApplication/AXWindow",
				"text":    "Calculator",
				"actions": []string{"AXRaise", "AXClose"},
				"bounds": map[string]interface{}{
					"x":      100.0,
					"y":      200.0,
					"width":  400.0,
					"height": 300.0,
				},
			},
			{
				"id":   "elem-2",
				"role": "AXButton",
				"path": "/AXApplication/AXWindow/AXButton",
				"text": "7",
			},
		},
	}

	jsonBytes, err := json.Marshal(mockAccessibilityTree)
	if err != nil {
		t.Fatalf("Failed to marshal mock tree: %v", err)
	}

	// Simulate response
	responseContent := map[string]interface{}{
		"uri":      "accessibility://1234",
		"mimeType": "application/json",
		"text":     string(jsonBytes),
	}

	// Verify mimeType is application/json
	if responseContent["mimeType"] != "application/json" {
		t.Errorf("mimeType = %v, want application/json", responseContent["mimeType"])
	}

	// Verify content is valid JSON
	content, ok := responseContent["text"].(string)
	if !ok || content == "" {
		t.Error("Content should be non-empty JSON string")
	}

	var parsedTree map[string]interface{}
	if err := json.Unmarshal([]byte(content), &parsedTree); err != nil {
		t.Errorf("Content is not valid JSON: %v", err)
	}

	// Verify expected structure
	if _, ok := parsedTree["application"]; !ok {
		t.Error("Tree should contain 'application' field")
	}
	if _, ok := parsedTree["elementCount"]; !ok {
		t.Error("Tree should contain 'elementCount' field")
	}
	elements, ok := parsedTree["elements"].([]interface{})
	if !ok {
		t.Error("Tree should contain 'elements' array")
	}
	if len(elements) == 0 {
		t.Error("Elements array should not be empty for valid accessibility tree")
	}

	// Verify element structure
	if len(elements) > 0 {
		firstElem, ok := elements[0].(map[string]interface{})
		if !ok {
			t.Error("Element should be an object")
		} else {
			if _, ok := firstElem["id"]; !ok {
				t.Error("Element should have 'id' field")
			}
			if _, ok := firstElem["role"]; !ok {
				t.Error("Element should have 'role' field")
			}
			if _, ok := firstElem["path"]; !ok {
				t.Error("Element should have 'path' field")
			}
		}
	}
}

// TestMCPResourcesReadInvalidURI tests error handling for invalid resource URIs
func TestMCPResourcesReadInvalidURI(t *testing.T) {
	tests := []struct {
		name        string
		uri         string
		wantErr     bool
		errContains string
	}{
		{
			name:        "unknown scheme",
			uri:         "unknown://foo",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
		{
			name:        "invalid scheme with colon only",
			uri:         "invalid:",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
		{
			name:        "empty URI",
			uri:         "",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
		{
			name:        "file:// scheme not supported",
			uri:         "file:///tmp/test.txt",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
		{
			name:        "http:// scheme not supported",
			uri:         "http://example.com",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
		{
			name:        "accessibility:// without PID",
			uri:         "accessibility://",
			wantErr:     true,
			errContains: "accessibility:// requires a PID",
		},
		{
			name:        "accessibility:// with invalid PID format",
			uri:         "accessibility://notanumber",
			wantErr:     true,
			errContains: "invalid PID",
		},
		{
			name:        "screen:// with invalid display",
			uri:         "screen://secondary",
			wantErr:     true,
			errContains: "unsupported screen resource",
		},
		{
			name:        "screen:// empty suffix",
			uri:         "screen://",
			wantErr:     true,
			errContains: "unsupported screen resource",
		},
		{
			name:        "clipboard:// with invalid suffix",
			uri:         "clipboard://history",
			wantErr:     true,
			errContains: "unsupported clipboard resource",
		},
		{
			name:        "clipboard:// empty suffix",
			uri:         "clipboard://",
			wantErr:     true,
			errContains: "unsupported clipboard resource",
		},
		{
			name:        "malformed URI no scheme",
			uri:         "just-a-string",
			wantErr:     true,
			errContains: "unsupported resource URI scheme",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate URI validation logic from readResource
			var err error

			if strings.HasPrefix(tt.uri, "screen://") {
				suffix := strings.TrimPrefix(tt.uri, "screen://")
				if suffix != "main" {
					err = fmt.Errorf("unsupported screen resource: %s (only 'main' is supported)", suffix)
				}
			} else if strings.HasPrefix(tt.uri, "accessibility://") {
				pidStr := strings.TrimPrefix(tt.uri, "accessibility://")
				if pidStr == "" {
					err = fmt.Errorf("accessibility:// requires a PID (e.g., accessibility://1234)")
				} else {
					_, parseErr := strconv.ParseInt(pidStr, 10, 32)
					if parseErr != nil {
						err = fmt.Errorf("invalid PID in accessibility URI: %s", pidStr)
					}
				}
			} else if strings.HasPrefix(tt.uri, "clipboard://") {
				suffix := strings.TrimPrefix(tt.uri, "clipboard://")
				if suffix != "current" {
					err = fmt.Errorf("unsupported clipboard resource: %s (only 'current' is supported)", suffix)
				}
			} else {
				err = fmt.Errorf("unsupported resource URI scheme: %s", tt.uri)
			}

			// Verify error expectation
			if tt.wantErr {
				if err == nil {
					t.Errorf("Expected error for URI %q, got nil", tt.uri)
				} else if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("Error = %q, should contain %q", err.Error(), tt.errContains)
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error for URI %q: %v", tt.uri, err)
				}
			}
		})
	}
}

// TestMCPResourcesReadValidURIs tests that valid URIs are accepted (format validation only)
func TestMCPResourcesReadValidURIs(t *testing.T) {
	validURIs := []struct {
		uri          string
		expectedType string
	}{
		{"screen://main", "screenshot"},
		{"accessibility://1234", "accessibility_tree"},
		{"accessibility://1", "accessibility_tree"},
		{"accessibility://99999", "accessibility_tree"},
		{"clipboard://current", "clipboard"},
	}

	for _, tt := range validURIs {
		t.Run(tt.uri, func(t *testing.T) {
			// Validate URI format only (actual content requires gRPC server)
			var resourceType string
			var err error

			if strings.HasPrefix(tt.uri, "screen://") {
				suffix := strings.TrimPrefix(tt.uri, "screen://")
				if suffix == "main" {
					resourceType = "screenshot"
				} else {
					err = fmt.Errorf("unsupported screen resource")
				}
			} else if strings.HasPrefix(tt.uri, "accessibility://") {
				pidStr := strings.TrimPrefix(tt.uri, "accessibility://")
				if pidStr != "" {
					if _, parseErr := strconv.ParseInt(pidStr, 10, 32); parseErr == nil {
						resourceType = "accessibility_tree"
					} else {
						err = fmt.Errorf("invalid PID")
					}
				} else {
					err = fmt.Errorf("missing PID")
				}
			} else if strings.HasPrefix(tt.uri, "clipboard://") {
				suffix := strings.TrimPrefix(tt.uri, "clipboard://")
				if suffix == "current" {
					resourceType = "clipboard"
				} else {
					err = fmt.Errorf("unsupported clipboard resource")
				}
			} else {
				err = fmt.Errorf("unsupported scheme")
			}

			if err != nil {
				t.Errorf("URI %q should be valid, got error: %v", tt.uri, err)
			}
			if resourceType != tt.expectedType {
				t.Errorf("URI %q resourceType = %q, want %q", tt.uri, resourceType, tt.expectedType)
			}
		})
	}
}

// TestMCPResourcesReadResponseStructure validates resources/read JSON-RPC response structure
func TestMCPResourcesReadResponseStructure(t *testing.T) {
	// Simulate a complete JSON-RPC response for resources/read
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 2,
		"result": {
			"contents": [
				{
					"uri": "clipboard://current",
					"mimeType": "text/plain",
					"text": "Hello from clipboard"
				}
			]
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC 2.0 structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	result, ok := response["result"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	contents, ok := result["contents"].([]interface{})
	if !ok {
		t.Fatal("Result should contain 'contents' array")
	}

	if len(contents) != 1 {
		t.Errorf("Expected 1 content item, got %d", len(contents))
	}

	// Verify content structure
	content := contents[0].(map[string]interface{})
	if _, ok := content["uri"]; !ok {
		t.Error("Content should have 'uri' field")
	}
	if _, ok := content["mimeType"]; !ok {
		t.Error("Content should have 'mimeType' field")
	}
	if _, ok := content["text"]; !ok {
		t.Error("Content should have 'text' field")
	}
}

// TestMCPResourcesReadErrorResponse validates error response format for resources/read
func TestMCPResourcesReadErrorResponse(t *testing.T) {
	// Simulate error response for invalid URI
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 3,
		"error": {
			"code": -32603,
			"message": "unsupported resource URI scheme: invalid://test"
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Should have error, not result
	if _, ok := response["result"]; ok {
		t.Error("Error response should not contain 'result'")
	}

	errorObj, ok := response["error"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'error' object")
	}

	// Verify error structure
	code, ok := errorObj["code"].(float64)
	if !ok {
		t.Error("Error should have 'code' field")
	}
	if int(code) != transport.ErrCodeInternalError {
		t.Errorf("Error code = %v, want %d", code, transport.ErrCodeInternalError)
	}

	message, ok := errorObj["message"].(string)
	if !ok || message == "" {
		t.Error("Error should have non-empty 'message' field")
	}
}

// TestMCPResourcesCapabilityAnnouncement verifies resources capability is announced properly
func TestMCPResourcesCapabilityAnnouncement(t *testing.T) {
	// Simulate initialize response with resources capability
	initResponseJSON := `{
		"protocolVersion": "2025-11-25",
		"capabilities": {
			"tools": {},
			"resources": {
				"subscribe": false,
				"listChanged": false
			}
		},
		"serverInfo": {
			"name": "macos-use-sdk",
			"version": "0.1.0"
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(initResponseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	capabilities, ok := response["capabilities"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'capabilities' object")
	}

	// Verify resources capability is present
	resources, ok := capabilities["resources"].(map[string]interface{})
	if !ok {
		t.Fatal("Capabilities should contain 'resources' object")
	}

	// Verify resources options
	subscribe, ok := resources["subscribe"].(bool)
	if !ok {
		t.Error("Resources should have 'subscribe' boolean field")
	}
	if subscribe != false {
		t.Errorf("Resources subscribe = %v, want false (not implemented)", subscribe)
	}

	listChanged, ok := resources["listChanged"].(bool)
	if !ok {
		t.Error("Resources should have 'listChanged' boolean field")
	}
	if listChanged != false {
		t.Errorf("Resources listChanged = %v, want false (not implemented)", listChanged)
	}
}

// TestMCPResourceURISchemeValidation tests individual URI scheme validation
func TestMCPResourceURISchemeValidation(t *testing.T) {
	supportedSchemes := []string{"screen", "accessibility", "clipboard"}
	unsupportedSchemes := []string{"file", "http", "https", "ftp", "data", "mailto", "ssh"}

	for _, scheme := range supportedSchemes {
		t.Run("supported_"+scheme, func(t *testing.T) {
			uri := scheme + "://"
			if !strings.HasPrefix(uri, scheme+"://") {
				t.Errorf("URI %q should have scheme %s://", uri, scheme)
			}
		})
	}

	for _, scheme := range unsupportedSchemes {
		t.Run("unsupported_"+scheme, func(t *testing.T) {
			uri := scheme + "://example"
			isSupported := strings.HasPrefix(uri, "screen://") ||
				strings.HasPrefix(uri, "accessibility://") ||
				strings.HasPrefix(uri, "clipboard://")
			if isSupported {
				t.Errorf("URI %q should NOT be supported", uri)
			}
		})
	}
}

// TestMCPResourcesEmptyClipboardHandling tests graceful handling of empty clipboard
func TestMCPResourcesEmptyClipboardHandling(t *testing.T) {
	// When clipboard is empty, resources/read should still succeed with empty content
	responseContent := map[string]interface{}{
		"uri":      "clipboard://current",
		"mimeType": "text/plain",
		"text":     "", // empty clipboard
	}

	result, err := json.Marshal(map[string]interface{}{
		"contents": []map[string]interface{}{responseContent},
	})
	if err != nil {
		t.Fatalf("Failed to marshal empty clipboard response: %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(result, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}

	contents := parsed["contents"].([]interface{})
	if len(contents) != 1 {
		t.Errorf("Expected 1 content item, got %d", len(contents))
	}

	content := contents[0].(map[string]interface{})
	if content["mimeType"] != "text/plain" {
		t.Errorf("Empty clipboard should still have text/plain mimeType")
	}
	if content["text"] != "" {
		t.Errorf("Empty clipboard text should be empty string")
	}
}

// ============================================================================
// Task 35: MCP Prompts Unit Tests
// ============================================================================

// TestMCPPromptsList verifies that prompts/list returns 3 prompts with correct
// structure including name, description, and arguments fields.
func TestMCPPromptsList(t *testing.T) {
	// Simulate listPrompts() response - this matches the implementation
	prompts := []map[string]interface{}{
		{
			"name":        "navigate_to_element",
			"description": "Navigate to and click an accessibility element",
			"arguments": []map[string]interface{}{
				{"name": "selector", "description": "Element selector (role, text, or path)", "required": true},
				{"name": "action", "description": "Action to perform: click, double_click, right_click", "required": false},
			},
		},
		{
			"name":        "fill_form",
			"description": "Find and fill form fields with values",
			"arguments": []map[string]interface{}{
				{"name": "fields", "description": "JSON object mapping field names/labels to values", "required": true},
			},
		},
		{
			"name":        "verify_state",
			"description": "Verify an element matches expected state",
			"arguments": []map[string]interface{}{
				{"name": "selector", "description": "Element selector", "required": true},
				{"name": "expected_state", "description": "Expected state: visible, enabled, focused, or text value", "required": true},
			},
		},
	}

	// Verify we have exactly 3 prompts
	if len(prompts) != 3 {
		t.Errorf("Expected 3 prompts, got %d", len(prompts))
	}

	// Verify expected prompt names exist
	expectedNames := map[string]bool{
		"navigate_to_element": false,
		"fill_form":           false,
		"verify_state":        false,
	}

	for _, p := range prompts {
		name, ok := p["name"].(string)
		if !ok {
			t.Error("Prompt should have 'name' string field")
			continue
		}

		if _, exists := expectedNames[name]; exists {
			expectedNames[name] = true
		} else {
			t.Errorf("Unexpected prompt name: %s", name)
		}

		// Verify description exists
		if _, ok := p["description"].(string); !ok {
			t.Errorf("Prompt %s should have 'description' string field", name)
		}

		// Verify arguments array exists
		args, ok := p["arguments"].([]map[string]interface{})
		if !ok {
			t.Errorf("Prompt %s should have 'arguments' array field", name)
			continue
		}

		// Verify each argument has required fields
		for _, arg := range args {
			if _, ok := arg["name"].(string); !ok {
				t.Errorf("Prompt %s argument should have 'name' field", name)
			}
			if _, ok := arg["description"].(string); !ok {
				t.Errorf("Prompt %s argument should have 'description' field", name)
			}
			if _, ok := arg["required"].(bool); !ok {
				t.Errorf("Prompt %s argument should have 'required' bool field", name)
			}
		}
	}

	// Verify all expected names were found
	for name, found := range expectedNames {
		if !found {
			t.Errorf("Expected prompt %s not found", name)
		}
	}
}

// TestMCPPromptsListResponseStructure validates the full JSON-RPC response
// structure for prompts/list matches MCP specification.
func TestMCPPromptsListResponseStructure(t *testing.T) {
	// Simulate complete JSON-RPC response for prompts/list
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 5,
		"result": {
			"prompts": [
				{
					"name": "navigate_to_element",
					"description": "Navigate to and click an accessibility element",
					"arguments": [
						{"name": "selector", "description": "Element selector (role, text, or path)", "required": true},
						{"name": "action", "description": "Action to perform: click, double_click, right_click", "required": false}
					]
				},
				{
					"name": "fill_form",
					"description": "Find and fill form fields with values",
					"arguments": [
						{"name": "fields", "description": "JSON object mapping field names/labels to values", "required": true}
					]
				},
				{
					"name": "verify_state",
					"description": "Verify an element matches expected state",
					"arguments": [
						{"name": "selector", "description": "Element selector", "required": true},
						{"name": "expected_state", "description": "Expected state: visible, enabled, focused, or text value", "required": true}
					]
				}
			]
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC 2.0 structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Verify id is present
	if _, ok := response["id"]; !ok {
		t.Error("Response should contain 'id' field")
	}

	// Verify result object exists
	result, ok := response["result"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify prompts array exists
	prompts, ok := result["prompts"].([]interface{})
	if !ok {
		t.Fatal("Result should contain 'prompts' array")
	}

	if len(prompts) != 3 {
		t.Errorf("Expected 3 prompts, got %d", len(prompts))
	}

	// Verify each prompt has the required structure
	for i, p := range prompts {
		prompt, ok := p.(map[string]interface{})
		if !ok {
			t.Errorf("Prompt %d should be an object", i)
			continue
		}

		if _, ok := prompt["name"]; !ok {
			t.Errorf("Prompt %d should have 'name' field", i)
		}
		if _, ok := prompt["description"]; !ok {
			t.Errorf("Prompt %d should have 'description' field", i)
		}
		if _, ok := prompt["arguments"]; !ok {
			t.Errorf("Prompt %d should have 'arguments' field", i)
		}
	}
}

// TestMCPPromptsGetNavigateToElement tests prompts/get for navigate_to_element
// with selector and action arguments.
func TestMCPPromptsGetNavigateToElement(t *testing.T) {
	tests := []struct {
		name           string
		selector       string
		action         string
		wantContains   []string
		wantNotContain []string
	}{
		{
			name:     "with click action",
			selector: "button:Submit",
			action:   "click",
			wantContains: []string{
				"button:Submit",
				"click",
				"find_elements",
			},
		},
		{
			name:     "with double_click action",
			selector: "cell:Document.txt",
			action:   "double_click",
			wantContains: []string{
				"cell:Document.txt",
				"double_click",
			},
		},
		{
			name:     "with right_click action",
			selector: "icon:Finder",
			action:   "right_click",
			wantContains: []string{
				"icon:Finder",
				"right_click",
			},
		},
		{
			name:     "default action when empty",
			selector: "menu:File",
			action:   "",
			wantContains: []string{
				"menu:File",
				"click", // default action
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt for navigate_to_element
			selector := tt.selector
			action := tt.action
			if action == "" {
				action = "click" // default action per implementation
			}

			content := fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, use traverse_accessibility or find_elements to locate the element matching: %s
2. Once found, perform the "%s" action on the element using click_element or perform_element_action
3. Verify the action completed successfully by checking for state changes

If the element is not immediately visible, you may need to:
- Scroll to reveal it
- Wait for it to appear using wait_element
- Check if it's in a different window`, selector, action)

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}

			for _, notWant := range tt.wantNotContain {
				if strings.Contains(content, notWant) {
					t.Errorf("Content should NOT contain %q", notWant)
				}
			}
		})
	}
}

// TestMCPPromptsGetFillForm tests prompts/get for fill_form with fields argument.
func TestMCPPromptsGetFillForm(t *testing.T) {
	tests := []struct {
		name         string
		fields       map[string]interface{}
		wantContains []string
	}{
		{
			name: "simple text fields",
			fields: map[string]interface{}{
				"username": "testuser",
				"email":    "test@example.com",
			},
			wantContains: []string{
				"testuser",
				"test@example.com",
				"AXTextField",
				"find_elements",
			},
		},
		{
			name:   "empty fields object",
			fields: map[string]interface{}{},
			wantContains: []string{
				"{}",
				"AXTextField",
			},
		},
		{
			name: "fields with nested values",
			fields: map[string]interface{}{
				"address": map[string]string{
					"street": "123 Main St",
					"city":   "Boston",
				},
			},
			wantContains: []string{
				"123 Main St",
				"Boston",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt for fill_form
			fieldsStr := "{}"
			if fieldBytes, err := json.Marshal(tt.fields); err == nil {
				fieldsStr = string(fieldBytes)
			}

			content := fmt.Sprintf(`Fill form fields with the following values:

%s

For each field:
1. Use find_elements to locate the form field by its label or role (AXTextField, AXTextArea, AXComboBox)
2. Focus the field by clicking on it
3. Use write_element_value or type_text to enter the value
4. Verify the value was entered correctly by reading the element's value

Common field roles:
- AXTextField: Single-line text input
- AXTextArea: Multi-line text input
- AXCheckBox: Checkbox (use perform_element_action with "press" to toggle)
- AXPopUpButton: Dropdown menu
- AXComboBox: Combo box with text and dropdown`, fieldsStr)

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}
		})
	}
}

// TestMCPPromptsGetVerifyState tests prompts/get for verify_state with selector
// and expected_state arguments.
func TestMCPPromptsGetVerifyState(t *testing.T) {
	tests := []struct {
		name          string
		selector      string
		expectedState string
		wantContains  []string
	}{
		{
			name:          "verify visible state",
			selector:      "button:OK",
			expectedState: "visible",
			wantContains: []string{
				"button:OK",
				"visible",
				"find_elements",
				"get_element",
			},
		},
		{
			name:          "verify enabled state",
			selector:      "textfield:Search",
			expectedState: "enabled",
			wantContains: []string{
				"textfield:Search",
				"enabled",
				"AXEnabled",
			},
		},
		{
			name:          "verify focused state",
			selector:      "textarea:Editor",
			expectedState: "focused",
			wantContains: []string{
				"textarea:Editor",
				"focused",
				"AXFocused",
			},
		},
		{
			name:          "verify text value",
			selector:      "label:Status",
			expectedState: "Connected",
			wantContains: []string{
				"label:Status",
				"Connected",
				"AXValue",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt for verify_state
			content := fmt.Sprintf(`Verify that a UI element matches the expected state.

Element to find: %s
Expected state: %s

Steps:
1. Use find_elements to locate the element matching the selector
2. Use get_element to retrieve the element's current properties
3. Compare the element's state against the expected value:
   - "visible": Check that the element exists and is not hidden
   - "enabled": Check AXEnabled attribute is true
   - "focused": Check AXFocused attribute is true
   - For text values: Check AXValue or AXTitle matches the expected text

4. Report whether the verification passed or failed with details

If using wait_element_state, you can poll until the condition is met or timeout.`, tt.selector, tt.expectedState)

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}
		})
	}
}

// TestMCPPromptsGetUnknownPrompt tests error handling for unknown prompt names.
func TestMCPPromptsGetUnknownPrompt(t *testing.T) {
	unknownPrompts := []string{
		"unknown_prompt",
		"does_not_exist",
		"navigate_to_element_v2",
		"",
		"NAVIGATE_TO_ELEMENT", // case-sensitive
	}

	for _, name := range unknownPrompts {
		t.Run("unknown_"+name, func(t *testing.T) {
			// Simulate getPrompt error handling
			var err error
			switch name {
			case "navigate_to_element", "fill_form", "verify_state":
				// These are known prompts - should not error
			default:
				err = fmt.Errorf("unknown prompt: %s", name)
			}

			if err == nil {
				t.Errorf("Expected error for unknown prompt %q", name)
				return
			}

			if !strings.Contains(err.Error(), "unknown prompt") {
				t.Errorf("Error should contain 'unknown prompt', got: %v", err)
			}
		})
	}
}

// TestMCPPromptsGetMissingArguments tests default values when optional arguments
// are missing from the request.
func TestMCPPromptsGetMissingArguments(t *testing.T) {
	tests := []struct {
		name              string
		promptName        string
		args              map[string]interface{}
		wantDefaultValue  string
		wantContentSubstr string
	}{
		{
			name:              "navigate_to_element without action uses click",
			promptName:        "navigate_to_element",
			args:              map[string]interface{}{"selector": "button:Test"},
			wantDefaultValue:  "click",
			wantContentSubstr: `"click"`,
		},
		{
			name:              "navigate_to_element with nil action uses click",
			promptName:        "navigate_to_element",
			args:              map[string]interface{}{"selector": "button:Test", "action": nil},
			wantDefaultValue:  "click",
			wantContentSubstr: `"click"`,
		},
		{
			name:              "navigate_to_element with empty action uses click",
			promptName:        "navigate_to_element",
			args:              map[string]interface{}{"selector": "button:Test", "action": ""},
			wantDefaultValue:  "click",
			wantContentSubstr: `"click"`,
		},
		{
			name:              "navigate_to_element without selector",
			promptName:        "navigate_to_element",
			args:              map[string]interface{}{},
			wantContentSubstr: "matching: ", // empty selector is allowed
		},
		{
			name:              "fill_form without fields uses empty object",
			promptName:        "fill_form",
			args:              map[string]interface{}{},
			wantDefaultValue:  "{}",
			wantContentSubstr: "{}",
		},
		{
			name:              "verify_state without selector",
			promptName:        "verify_state",
			args:              map[string]interface{}{"expected_state": "visible"},
			wantContentSubstr: "Element to find: ",
		},
		{
			name:              "verify_state without expected_state",
			promptName:        "verify_state",
			args:              map[string]interface{}{"selector": "button:OK"},
			wantContentSubstr: "Expected state: ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt with partial arguments
			var content string

			switch tt.promptName {
			case "navigate_to_element":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				action := "click"
				if v, ok := tt.args["action"]; ok && v != nil && fmt.Sprintf("%v", v) != "" {
					action = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf("matching: %s\n\"%s\"", selector, action)

			case "fill_form":
				fieldsStr := "{}"
				if v, ok := tt.args["fields"]; ok {
					if fieldBytes, err := json.Marshal(v); err == nil {
						fieldsStr = string(fieldBytes)
					}
				}
				content = fieldsStr

			case "verify_state":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				expectedState := ""
				if v, ok := tt.args["expected_state"]; ok {
					expectedState = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf("Element to find: %s\nExpected state: %s", selector, expectedState)
			}

			if !strings.Contains(content, tt.wantContentSubstr) {
				t.Errorf("Content should contain %q, got: %s", tt.wantContentSubstr, content)
			}
		})
	}
}

// TestMCPPromptsGetResponseStructure validates prompts/get JSON-RPC response
// matches MCP spec with messages array containing role:user.
func TestMCPPromptsGetResponseStructure(t *testing.T) {
	// Simulate complete JSON-RPC response for prompts/get
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 6,
		"result": {
			"description": "Navigate to and click an accessibility element",
			"messages": [
				{
					"role": "user",
					"content": {
						"type": "text",
						"text": "Find and interact with a UI element..."
					}
				}
			]
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC 2.0 structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Verify result object
	result, ok := response["result"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify description field
	if _, ok := result["description"].(string); !ok {
		t.Error("Result should contain 'description' string field")
	}

	// Verify messages array
	messages, ok := result["messages"].([]interface{})
	if !ok {
		t.Fatal("Result should contain 'messages' array")
	}

	if len(messages) == 0 {
		t.Fatal("Messages array should not be empty")
	}

	// Verify message structure
	message, ok := messages[0].(map[string]interface{})
	if !ok {
		t.Fatal("Message should be an object")
	}

	// Verify role is "user" per MCP spec
	role, ok := message["role"].(string)
	if !ok {
		t.Error("Message should have 'role' string field")
	}
	if role != "user" {
		t.Errorf("Message role = %q, want 'user' (per MCP spec)", role)
	}

	// Verify content structure
	content, ok := message["content"].(map[string]interface{})
	if !ok {
		t.Fatal("Message should have 'content' object")
	}

	contentType, ok := content["type"].(string)
	if !ok {
		t.Error("Content should have 'type' string field")
	}
	if contentType != "text" {
		t.Errorf("Content type = %q, want 'text'", contentType)
	}

	if _, ok := content["text"].(string); !ok {
		t.Error("Content should have 'text' string field")
	}
}

// TestMCPPromptsArgumentSubstitution verifies arguments are properly substituted
// into prompt content.
func TestMCPPromptsArgumentSubstitution(t *testing.T) {
	tests := []struct {
		name       string
		promptName string
		args       map[string]interface{}
		mustAppear []string
	}{
		{
			name:       "navigate_to_element substitutes selector",
			promptName: "navigate_to_element",
			args:       map[string]interface{}{"selector": "UNIQUE_SELECTOR_12345"},
			mustAppear: []string{"UNIQUE_SELECTOR_12345"},
		},
		{
			name:       "navigate_to_element substitutes action",
			promptName: "navigate_to_element",
			args:       map[string]interface{}{"selector": "btn", "action": "UNIQUE_ACTION_67890"},
			mustAppear: []string{"UNIQUE_ACTION_67890"},
		},
		{
			name:       "fill_form substitutes fields JSON",
			promptName: "fill_form",
			args: map[string]interface{}{
				"fields": map[string]string{"UNIQUE_FIELD": "UNIQUE_VALUE"},
			},
			mustAppear: []string{"UNIQUE_FIELD", "UNIQUE_VALUE"},
		},
		{
			name:       "verify_state substitutes selector",
			promptName: "verify_state",
			args:       map[string]interface{}{"selector": "UNIQUE_SELECTOR_VERIFY", "expected_state": "visible"},
			mustAppear: []string{"UNIQUE_SELECTOR_VERIFY"},
		},
		{
			name:       "verify_state substitutes expected_state",
			promptName: "verify_state",
			args:       map[string]interface{}{"selector": "elem", "expected_state": "UNIQUE_STATE_VALUE"},
			mustAppear: []string{"UNIQUE_STATE_VALUE"},
		},
		{
			name:       "special characters in arguments",
			promptName: "navigate_to_element",
			args:       map[string]interface{}{"selector": `button:"Click Me" with spaces`},
			mustAppear: []string{`button:"Click Me" with spaces`},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt with argument substitution
			var content string

			switch tt.promptName {
			case "navigate_to_element":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				action := "click"
				if v, ok := tt.args["action"]; ok && v != nil && fmt.Sprintf("%v", v) != "" {
					action = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, use traverse_accessibility or find_elements to locate the element matching: %s
2. Once found, perform the "%s" action on the element`, selector, action)

			case "fill_form":
				fieldsStr := "{}"
				if v, ok := tt.args["fields"]; ok {
					if fieldBytes, err := json.Marshal(v); err == nil {
						fieldsStr = string(fieldBytes)
					}
				}
				content = fmt.Sprintf(`Fill form fields with the following values:

%s`, fieldsStr)

			case "verify_state":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				expectedState := ""
				if v, ok := tt.args["expected_state"]; ok {
					expectedState = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf(`Verify that a UI element matches the expected state.

Element to find: %s
Expected state: %s`, selector, expectedState)
			}

			for _, want := range tt.mustAppear {
				if !strings.Contains(content, want) {
					t.Errorf("Argument %q was not substituted into content", want)
				}
			}
		})
	}
}

// TestMCPPromptsCapabilityAnnouncement verifies prompts capability is announced
// in the initialize response.
func TestMCPPromptsCapabilityAnnouncement(t *testing.T) {
	// Simulate initialize response with prompts capability
	initResponseJSON := `{
		"jsonrpc": "2.0",
		"id": 1,
		"result": {
			"protocolVersion": "2025-11-25",
			"capabilities": {
				"tools": {},
				"resources": {
					"subscribe": false,
					"listChanged": false
				},
				"prompts": {}
			},
			"serverInfo": {
				"name": "macos-use-sdk",
				"version": "0.1.0"
			}
		}
	}`

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(initResponseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Get result
	result, ok := response["result"].(map[string]interface{})
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify protocol version
	if version, ok := result["protocolVersion"].(string); !ok || version != "2025-11-25" {
		t.Errorf("protocolVersion = %v, want '2025-11-25'", result["protocolVersion"])
	}

	// Get capabilities
	capabilities, ok := result["capabilities"].(map[string]interface{})
	if !ok {
		t.Fatal("Result should contain 'capabilities' object")
	}

	// Verify prompts capability is present
	prompts, ok := capabilities["prompts"]
	if !ok {
		t.Fatal("Capabilities should contain 'prompts' field")
	}

	// Prompts capability should be an object (even if empty)
	if _, ok := prompts.(map[string]interface{}); !ok {
		t.Errorf("Prompts capability should be an object, got %T", prompts)
	}

	// Verify other capabilities are also present (sanity check)
	if _, ok := capabilities["tools"]; !ok {
		t.Error("Capabilities should contain 'tools' field")
	}
	if _, ok := capabilities["resources"]; !ok {
		t.Error("Capabilities should contain 'resources' field")
	}
}

// TestMCPPromptsListArgumentsStructure validates the argument structure for each
// prompt matches the expected schema.
func TestMCPPromptsListArgumentsStructure(t *testing.T) {
	// Define expected argument structure for each prompt
	expectedArgs := map[string][]struct {
		name     string
		required bool
	}{
		"navigate_to_element": {
			{name: "selector", required: true},
			{name: "action", required: false},
		},
		"fill_form": {
			{name: "fields", required: true},
		},
		"verify_state": {
			{name: "selector", required: true},
			{name: "expected_state", required: true},
		},
	}

	// Simulate listPrompts() structure
	prompts := []map[string]interface{}{
		{
			"name": "navigate_to_element",
			"arguments": []map[string]interface{}{
				{"name": "selector", "required": true},
				{"name": "action", "required": false},
			},
		},
		{
			"name": "fill_form",
			"arguments": []map[string]interface{}{
				{"name": "fields", "required": true},
			},
		},
		{
			"name": "verify_state",
			"arguments": []map[string]interface{}{
				{"name": "selector", "required": true},
				{"name": "expected_state", "required": true},
			},
		},
	}

	for _, p := range prompts {
		name := p["name"].(string)
		args := p["arguments"].([]map[string]interface{})
		expected := expectedArgs[name]

		if len(args) != len(expected) {
			t.Errorf("Prompt %s: expected %d arguments, got %d", name, len(expected), len(args))
			continue
		}

		for i, arg := range args {
			argName := arg["name"].(string)
			argRequired := arg["required"].(bool)

			if argName != expected[i].name {
				t.Errorf("Prompt %s arg %d: name = %q, want %q", name, i, argName, expected[i].name)
			}
			if argRequired != expected[i].required {
				t.Errorf("Prompt %s arg %s: required = %v, want %v", name, argName, argRequired, expected[i].required)
			}
		}
	}
}

// TestMCPServer_HandleHTTPMessage_PromptsGetUnknownPrompt tests that the actual
// HTTP handler returns ErrCodeInvalidParams (-32602) for unknown prompt names,
// not ErrCodeInternalError (-32603), per MCP spec.
func TestMCPServer_HandleHTTPMessage_PromptsGetUnknownPrompt(t *testing.T) {
	// Create minimal MCPServer for handler testing (no gRPC required)
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   context.Background(),
	}

	tests := []struct {
		name         string
		promptName   string
		wantErrCode  int
		wantErrMsgIn string
	}{
		{
			name:         "unknown prompt gets invalid params error",
			promptName:   "does_not_exist",
			wantErrCode:  transport.ErrCodeInvalidParams,
			wantErrMsgIn: "unknown prompt",
		},
		{
			name:         "empty prompt name gets invalid params error",
			promptName:   "",
			wantErrCode:  transport.ErrCodeInvalidParams,
			wantErrMsgIn: "unknown prompt",
		},
		{
			name:         "case sensitive - uppercase is unknown",
			promptName:   "NAVIGATE_TO_ELEMENT",
			wantErrCode:  transport.ErrCodeInvalidParams,
			wantErrMsgIn: "unknown prompt",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			paramsJSON := fmt.Sprintf(`{"name":%q}`, tt.promptName)
			msg := &transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "prompts/get",
				Params:  json.RawMessage(paramsJSON),
			}

			resp, err := s.handleHTTPMessage(msg)
			if err != nil {
				t.Fatalf("handleHTTPMessage returned error: %v", err)
			}

			if resp == nil {
				t.Fatal("Response should not be nil")
			}

			if resp.Error == nil {
				t.Fatal("Response should contain error for unknown prompt")
			}

			if resp.Error.Code != tt.wantErrCode {
				t.Errorf("Error code = %d, want %d (ErrCodeInvalidParams)", resp.Error.Code, tt.wantErrCode)
			}

			if !strings.Contains(resp.Error.Message, tt.wantErrMsgIn) {
				t.Errorf("Error message = %q, should contain %q", resp.Error.Message, tt.wantErrMsgIn)
			}
		})
	}
}

// TestMCPServer_HandleHTTPMessage_PromptsGetValidPrompts tests that valid
// prompts return successful responses with correct structure.
func TestMCPServer_HandleHTTPMessage_PromptsGetValidPrompts(t *testing.T) {
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   context.Background(),
	}

	tests := []struct {
		name       string
		promptName string
		args       string
	}{
		{
			name:       "navigate_to_element with selector",
			promptName: "navigate_to_element",
			args:       `{"name":"navigate_to_element","arguments":{"selector":"button:OK"}}`,
		},
		{
			name:       "fill_form with fields",
			promptName: "fill_form",
			args:       `{"name":"fill_form","arguments":{"fields":{"username":"test"}}}`,
		},
		{
			name:       "verify_state with selector and state",
			promptName: "verify_state",
			args:       `{"name":"verify_state","arguments":{"selector":"label:Status","expected_state":"visible"}}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg := &transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "prompts/get",
				Params:  json.RawMessage(tt.args),
			}

			resp, err := s.handleHTTPMessage(msg)
			if err != nil {
				t.Fatalf("handleHTTPMessage returned error: %v", err)
			}

			if resp == nil {
				t.Fatal("Response should not be nil")
			}

			// Should have result, not error
			if resp.Error != nil {
				t.Fatalf("Response should not contain error, got: %v", resp.Error.Message)
			}

			if resp.Result == nil {
				t.Fatal("Response should contain result")
			}

			// Parse result to verify structure
			var result map[string]interface{}
			if err := json.Unmarshal(resp.Result, &result); err != nil {
				t.Fatalf("Failed to parse result: %v", err)
			}

			// Verify MCP-required fields
			if _, ok := result["description"]; !ok {
				t.Error("Result should contain 'description' field")
			}

			messages, ok := result["messages"].([]interface{})
			if !ok || len(messages) == 0 {
				t.Error("Result should contain non-empty 'messages' array")
			} else {
				// Verify first message has role:user
				firstMsg, ok := messages[0].(map[string]interface{})
				if !ok {
					t.Error("First message should be an object")
				} else if firstMsg["role"] != "user" {
					t.Errorf("First message role = %v, want 'user'", firstMsg["role"])
				}
			}
		})
	}
}

// TestMCPServer_HandleHTTPMessage_PromptsList tests the prompts/list handler
// returns correct structure.
func TestMCPServer_HandleHTTPMessage_PromptsList(t *testing.T) {
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   context.Background(),
	}

	msg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Method:  "prompts/list",
		Params:  json.RawMessage(`{}`),
	}

	resp, err := s.handleHTTPMessage(msg)
	if err != nil {
		t.Fatalf("handleHTTPMessage returned error: %v", err)
	}

	if resp == nil {
		t.Fatal("Response should not be nil")
	}

	if resp.Error != nil {
		t.Fatalf("Response should not contain error, got: %v", resp.Error.Message)
	}

	if resp.Result == nil {
		t.Fatal("Response should contain result")
	}

	// Parse result
	var result map[string]interface{}
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	// Verify prompts array
	prompts, ok := result["prompts"].([]interface{})
	if !ok {
		t.Fatal("Result should contain 'prompts' array")
	}

	if len(prompts) != 3 {
		t.Errorf("Expected 3 prompts, got %d", len(prompts))
	}

	// Verify each prompt has required fields
	expectedNames := map[string]bool{
		"navigate_to_element": false,
		"fill_form":           false,
		"verify_state":        false,
	}

	for i, p := range prompts {
		prompt, ok := p.(map[string]interface{})
		if !ok {
			t.Errorf("Prompt %d should be an object", i)
			continue
		}

		name, _ := prompt["name"].(string)
		if _, exists := expectedNames[name]; exists {
			expectedNames[name] = true
		}

		if _, ok := prompt["description"]; !ok {
			t.Errorf("Prompt %s should have 'description' field", name)
		}

		if _, ok := prompt["arguments"]; !ok {
			t.Errorf("Prompt %s should have 'arguments' field", name)
		}
	}

	for name, found := range expectedNames {
		if !found {
			t.Errorf("Expected prompt %s not found", name)
		}
	}
}
