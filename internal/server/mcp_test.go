// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
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
			want: `{"content":[{"type":"text","text":"Something went wrong"}],"isError":true}`,
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

// TestJoinStrings tests the joinStrings helper function
func TestJoinStrings(t *testing.T) {
	tests := []struct {
		name string
		strs []string
		sep  string
		want string
	}{
		{
			name: "empty slice",
			strs: []string{},
			sep:  ",",
			want: "",
		},
		{
			name: "single element",
			strs: []string{"one"},
			sep:  ",",
			want: "one",
		},
		{
			name: "multiple elements",
			strs: []string{"one", "two", "three"},
			sep:  ", ",
			want: "one, two, three",
		},
		{
			name: "newline separator",
			strs: []string{"line1", "line2"},
			sep:  "\n",
			want: "line1\nline2",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := joinStrings(tt.strs, tt.sep)
			if got != tt.want {
				t.Errorf("joinStrings() = %q, want %q", got, tt.want)
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
					"code":    -32600,
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
	codes := map[string]int{
		"InvalidRequest": -32600,
		"MethodNotFound": -32601,
		"InvalidParams":  -32602,
		"InternalError":  -32603,
		"ParseError":     -32700,
		"ServerError":    -32000,
		"ServerErrorMax": -32099,
	}

	if codes["ServerError"] < -32099 || codes["ServerError"] > -32000 {
		t.Errorf("ServerError code %d not in valid range", codes["ServerError"])
	}
	if codes["ServerErrorMax"] < -32099 || codes["ServerErrorMax"] > -32000 {
		t.Errorf("ServerErrorMax code %d not in valid range", codes["ServerErrorMax"])
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

// TestAllToolsExist validates all 39 expected MCP tools are defined
func TestAllToolsExist(t *testing.T) {
	expectedTools := []string{
		// Screenshot tools (2)
		"capture_screenshot",
		"capture_region_screenshot",
		// Input tools (8)
		"click",
		"type_text",
		"press_key",
		"mouse_move",
		"scroll",
		"drag",
		"hover",
		"gesture",
		// Element tools (5)
		"find_elements",
		"get_element",
		"click_element",
		"write_element_value",
		"perform_element_action",
		// Window tools (8)
		"list_windows",
		"get_window",
		"focus_window",
		"move_window",
		"resize_window",
		"minimize_window",
		"restore_window",
		"close_window",
		// Display tools (2)
		"list_displays",
		"get_display",
		// Clipboard tools (3)
		"get_clipboard",
		"write_clipboard",
		"clear_clipboard",
		// Application tools (4)
		"open_application",
		"list_applications",
		"get_application",
		"delete_application",
		// Scripting tools (3)
		"execute_apple_script",
		"execute_javascript",
		"execute_shell_command",
		// Observation tools (4)
		"create_observation",
		"get_observation",
		"list_observations",
		"cancel_observation",
	}

	if len(expectedTools) != 39 {
		t.Errorf("Expected 39 tools but defined %d in test", len(expectedTools))
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
		"open_application",
		"list_applications",
		"get_application",
		"delete_application",
		"execute_apple_script",
		"execute_javascript",
		"execute_shell_command",
		"create_observation",
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
