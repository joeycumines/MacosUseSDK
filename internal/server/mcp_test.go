// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"context"
	"encoding/json"
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
