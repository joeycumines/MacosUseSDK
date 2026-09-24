// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/transport"
)

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
			input:    `{"name":"get_display","arguments":{}}`,
			wantName: "get_display",
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
			input:    `{"name":"type","arguments":{"text":"hello world"}}`,
			wantName: "type",
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

// TestJSONRPCResponse_Structure tests JSON-RPC response structure
func TestJSONRPCResponse_Structure(t *testing.T) {
	tests := []struct {
		name     string
		response map[string]any
		wantErr  bool
	}{
		{
			name: "success response",
			response: map[string]any{
				"jsonrpc": "2.0",
				"id":      1,
				"result":  map[string]any{"content": []any{}},
			},
			wantErr: false,
		},
		{
			name: "error response",
			response: map[string]any{
				"jsonrpc": "2.0",
				"id":      1,
				"error": map[string]any{
					"code":    transport.ErrCodeInvalidRequest,
					"message": "Invalid Request",
				},
			},
			wantErr: false,
		},
		{
			name: "notification (no id)",
			response: map[string]any{
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
				var parsed map[string]any
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
			var parsed map[string]any
			err := json.Unmarshal([]byte(tt.args), &parsed)
			if (err != nil) != tt.wantErr {
				t.Errorf("Unmarshal error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}
