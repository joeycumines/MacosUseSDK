// Copyright 2025 Joseph Cumines

package server

import (
	"errors"
	"strings"
	"testing"

	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestErrorResult(t *testing.T) {
	result := errorResult("test error")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Type != "text" {
		t.Errorf("expected type 'text', got %q", result.Content[0].Type)
	}
	if result.Content[0].Text != "test error" {
		t.Errorf("expected text 'test error', got %q", result.Content[0].Text)
	}
}

func TestErrorResultf(t *testing.T) {
	result := errorResultf("error %d: %s", 42, "details")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if result.Content[0].Text != "error 42: details" {
		t.Errorf("expected 'error 42: details', got %q", result.Content[0].Text)
	}
}

func TestTextResult(t *testing.T) {
	result := textResult("success message")
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Text != "success message" {
		t.Errorf("expected 'success message', got %q", result.Content[0].Text)
	}
}

func TestTextResultf(t *testing.T) {
	result := textResultf("count: %d", 99)
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if result.Content[0].Text != "count: 99" {
		t.Errorf("expected 'count: 99', got %q", result.Content[0].Text)
	}
}

func TestBoundsString(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown position and size)",
		},
		{
			name:     "origin bounds",
			bounds:   &pb.Bounds{X: 0, Y: 0, Width: 100, Height: 100},
			expected: "(0, 0) 100x100",
		},
		{
			name:     "positioned bounds",
			bounds:   &pb.Bounds{X: 100.5, Y: 200.7, Width: 800, Height: 600},
			expected: "(100, 201) 800x600",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsString(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsString(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsPosition(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "origin",
			bounds:   &pb.Bounds{X: 0, Y: 0},
			expected: "(0, 0)",
		},
		{
			name:     "positioned",
			bounds:   &pb.Bounds{X: 100, Y: 200},
			expected: "(100, 200)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsPosition(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsPosition(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsSize(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "zero size",
			bounds:   &pb.Bounds{Width: 0, Height: 0},
			expected: "0x0",
		},
		{
			name:     "sized",
			bounds:   &pb.Bounds{Width: 1920, Height: 1080},
			expected: "1920x1080",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsSize(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsSize(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestFrameString(t *testing.T) {
	tests := []struct {
		name     string
		frame    *_type.Region
		expected string
	}{
		{
			name:     "nil frame",
			frame:    nil,
			expected: "(unknown frame)",
		},
		{
			name:     "origin frame",
			frame:    &_type.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (0, 0)",
		},
		{
			name:     "offset frame",
			frame:    &_type.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (-1920, 0)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := frameString(tt.frame)
			if got != tt.expected {
				t.Errorf("frameString(%v) = %q, want %q", tt.frame, got, tt.expected)
			}
		})
	}
}

func TestTruncateText(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "short text unchanged",
			input:    "hello",
			expected: "hello",
		},
		{
			name:     "exactly at limit",
			input:    "12345678901234567890123456789012345678901234567890", // 50 chars
			expected: "12345678901234567890123456789012345678901234567890",
		},
		{
			name:     "over limit truncated",
			input:    "123456789012345678901234567890123456789012345678901", // 51 chars
			expected: "12345678901234567890123456789012345678901234567890...",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "long text truncated",
			input:    "This is a very long text that exceeds the maximum display length and should be truncated with an ellipsis at the end",
			expected: "This is a very long text that exceeds the maximum ...",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateText(tt.input)
			if got != tt.expected {
				t.Errorf("truncateText(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestMaxDisplayTextLen(t *testing.T) {
	// Verify the constant has the expected value
	if maxDisplayTextLen != 50 {
		t.Errorf("maxDisplayTextLen = %d, want 50", maxDisplayTextLen)
	}
}

func TestFormatGRPCError_NilError(t *testing.T) {
	result := formatGRPCError(nil, "test_tool")
	if result != "" {
		t.Errorf("formatGRPCError(nil) = %q, want empty string", result)
	}
}

func TestFormatGRPCError_NonGRPCError(t *testing.T) {
	err := errors.New("standard error message")
	result := formatGRPCError(err, "test_tool")

	expected := "Error in test_tool: standard error message"
	if result != expected {
		t.Errorf("formatGRPCError() = %q, want %q", result, expected)
	}
}

func TestFormatGRPCError_GRPCStatusCodes(t *testing.T) {
	tests := []struct {
		name           string
		code           codes.Code
		message        string
		toolName       string
		wantCode       string
		wantSuggestion string
	}{
		{
			name:           "PermissionDenied",
			code:           codes.PermissionDenied,
			message:        "accessibility access denied",
			toolName:       "click",
			wantCode:       "PermissionDenied",
			wantSuggestion: "Ensure accessibility permissions are granted",
		},
		{
			name:           "NotFound",
			code:           codes.NotFound,
			message:        "window not found",
			toolName:       "get_window",
			wantCode:       "NotFound",
			wantSuggestion: "Verify the resource exists",
		},
		{
			name:           "InvalidArgument",
			code:           codes.InvalidArgument,
			message:        "invalid selector",
			toolName:       "find_elements",
			wantCode:       "InvalidArgument",
			wantSuggestion: "Check the request parameters",
		},
		{
			name:           "Unavailable",
			code:           codes.Unavailable,
			message:        "connection refused",
			toolName:       "capture_screenshot",
			wantCode:       "Unavailable",
			wantSuggestion: "The gRPC server may be down",
		},
		{
			name:           "DeadlineExceeded",
			code:           codes.DeadlineExceeded,
			message:        "operation timed out",
			toolName:       "wait_element",
			wantCode:       "DeadlineExceeded",
			wantSuggestion: "Operation timed out",
		},
		{
			name:           "Internal",
			code:           codes.Internal,
			message:        "internal server error",
			toolName:       "traverse_accessibility",
			wantCode:       "Internal",
			wantSuggestion: "An internal server error occurred",
		},
		{
			name:           "FailedPrecondition",
			code:           codes.FailedPrecondition,
			message:        "app not running",
			toolName:       "open_application",
			wantCode:       "FailedPrecondition",
			wantSuggestion: "precondition not being met",
		},
		{
			name:           "AlreadyExists",
			code:           codes.AlreadyExists,
			message:        "session already exists",
			toolName:       "create_session",
			wantCode:       "AlreadyExists",
			wantSuggestion: "A resource with this identifier already exists",
		},
		{
			name:           "ResourceExhausted",
			code:           codes.ResourceExhausted,
			message:        "rate limit exceeded",
			toolName:       "list_windows",
			wantCode:       "ResourceExhausted",
			wantSuggestion: "Rate limit exceeded",
		},
		{
			name:           "Unimplemented",
			code:           codes.Unimplemented,
			message:        "not implemented",
			toolName:       "drag_files",
			wantCode:       "Unimplemented",
			wantSuggestion: "not implemented or supported",
		},
		{
			name:           "UnknownCode_NoSuggestion",
			code:           codes.Unknown,
			message:        "unknown error",
			toolName:       "test_tool",
			wantCode:       "Unknown",
			wantSuggestion: "", // No suggestion for Unknown code
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := status.Error(tt.code, tt.message)
			result := formatGRPCError(err, tt.toolName)

			// Check tool name is included
			if !strings.Contains(result, tt.toolName) {
				t.Errorf("result should contain tool name %q: %s", tt.toolName, result)
			}

			// Check code is included
			if !strings.Contains(result, tt.wantCode) {
				t.Errorf("result should contain code %q: %s", tt.wantCode, result)
			}

			// Check message is included
			if !strings.Contains(result, tt.message) {
				t.Errorf("result should contain message %q: %s", tt.message, result)
			}

			// Check suggestion is included (if expected)
			if tt.wantSuggestion != "" {
				if !strings.Contains(result, "Suggestion:") {
					t.Errorf("result should contain 'Suggestion:': %s", result)
				}
				if !strings.Contains(result, tt.wantSuggestion) {
					t.Errorf("result should contain suggestion %q: %s", tt.wantSuggestion, result)
				}
			} else {
				// For Unknown code, verify no suggestion line
				if strings.Contains(result, "Suggestion:") {
					t.Errorf("result should NOT contain 'Suggestion:' for code %s: %s", tt.wantCode, result)
				}
			}
		})
	}
}

func TestFormatGRPCError_OutputFormat(t *testing.T) {
	err := status.Error(codes.NotFound, "window not found")
	result := formatGRPCError(err, "get_window")

	// Verify the output format matches expected structure
	expected := "Error in get_window: NotFound - window not found\nSuggestion: Verify the resource exists and the name/ID is correct"
	if result != expected {
		t.Errorf("formatGRPCError() format mismatch:\ngot:  %q\nwant: %q", result, expected)
	}
}

func TestGRPCErrorResult(t *testing.T) {
	err := status.Error(codes.PermissionDenied, "screen capture denied")
	result := grpcErrorResult(err, "capture_screenshot")

	// Verify it returns a ToolResult with IsError=true
	if !result.IsError {
		t.Error("expected IsError to be true")
	}

	// Verify content is set
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}

	// Verify content type
	if result.Content[0].Type != "text" {
		t.Errorf("expected type 'text', got %q", result.Content[0].Type)
	}

	// Verify the text contains expected parts
	text := result.Content[0].Text
	if !strings.Contains(text, "capture_screenshot") {
		t.Errorf("result should contain tool name: %s", text)
	}
	if !strings.Contains(text, "PermissionDenied") {
		t.Errorf("result should contain error code: %s", text)
	}
	if !strings.Contains(text, "screen capture denied") {
		t.Errorf("result should contain error message: %s", text)
	}
	if !strings.Contains(text, "Suggestion:") {
		t.Errorf("result should contain suggestion: %s", text)
	}
}

func TestGRPCErrorResult_NonGRPCError(t *testing.T) {
	err := errors.New("plain error")
	result := grpcErrorResult(err, "test_tool")

	if !result.IsError {
		t.Error("expected IsError to be true")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in test_tool: plain error") {
		t.Errorf("result should contain formatted message: %s", text)
	}
}

// Test tool schemas for validateToolInput tests
var testValidationTools = map[string]*Tool{
	"test_tool_with_required": {
		Name: "test_tool_with_required",
		InputSchema: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"name":    map[string]interface{}{"type": "string"},
				"count":   map[string]interface{}{"type": "integer"},
				"enabled": map[string]interface{}{"type": "boolean"},
				"ratio":   map[string]interface{}{"type": "number"},
				"tags":    map[string]interface{}{"type": "array"},
				"config":  map[string]interface{}{"type": "object"},
				"format": map[string]interface{}{
					"type": "string",
					"enum": []string{"json", "xml", "yaml"},
				},
			},
			"required": []interface{}{"name"},
		},
	},
	"test_tool_no_required": {
		Name: "test_tool_no_required",
		InputSchema: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"limit": map[string]interface{}{"type": "integer"},
				"mode":  map[string]interface{}{"type": "string", "enum": []interface{}{"fast", "slow"}},
			},
		},
	},
	"test_tool_no_schema": {
		Name: "test_tool_no_schema",
	},
	"test_tool_no_properties": {
		Name: "test_tool_no_properties",
		InputSchema: map[string]interface{}{
			"type": "object",
		},
	},
	"test_tool_required_string_array": {
		Name: "test_tool_required_string_array",
		InputSchema: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"id": map[string]interface{}{"type": "string"},
			},
			"required": []string{"id"},
		},
	},
}

func TestValidateToolInput_MissingRequiredFields(t *testing.T) {
	tests := []struct {
		name    string
		args    map[string]interface{}
		wantErr string
	}{
		{
			name:    "missing required name field",
			args:    map[string]interface{}{"count": 5},
			wantErr: "missing required field: name",
		},
		{
			name:    "empty args missing required",
			args:    map[string]interface{}{},
			wantErr: "missing required field: name",
		},
		{
			name:    "nil args missing required",
			args:    nil,
			wantErr: "missing required field: name",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if result == nil {
				t.Fatal("expected error, got nil")
			}
			if result.Error == nil {
				t.Fatal("expected error in result, got nil")
			}
			if result.Error.Code != -32602 {
				t.Errorf("expected error code -32602, got %d", result.Error.Code)
			}
			if !strings.Contains(result.Error.Message, tt.wantErr) {
				t.Errorf("expected message to contain %q, got %q", tt.wantErr, result.Error.Message)
			}
		})
	}
}

func TestValidateToolInput_WrongTypes(t *testing.T) {
	tests := []struct {
		name      string
		args      map[string]interface{}
		wantField string
		wantType  string
	}{
		{
			name:      "string field gets number",
			args:      map[string]interface{}{"name": 123},
			wantField: "name",
			wantType:  "string",
		},
		{
			name:      "integer field gets string",
			args:      map[string]interface{}{"name": "test", "count": "five"},
			wantField: "count",
			wantType:  "integer",
		},
		{
			name:      "boolean field gets string",
			args:      map[string]interface{}{"name": "test", "enabled": "true"},
			wantField: "enabled",
			wantType:  "boolean",
		},
		{
			name:      "boolean field gets number",
			args:      map[string]interface{}{"name": "test", "enabled": 1},
			wantField: "enabled",
			wantType:  "boolean",
		},
		{
			name:      "number field gets string",
			args:      map[string]interface{}{"name": "test", "ratio": "3.14"},
			wantField: "ratio",
			wantType:  "number",
		},
		{
			name:      "array field gets object",
			args:      map[string]interface{}{"name": "test", "tags": map[string]interface{}{"key": "value"}},
			wantField: "tags",
			wantType:  "array",
		},
		{
			name:      "array field gets string",
			args:      map[string]interface{}{"name": "test", "tags": "tag1,tag2"},
			wantField: "tags",
			wantType:  "array",
		},
		{
			name:      "object field gets array",
			args:      map[string]interface{}{"name": "test", "config": []interface{}{"a", "b"}},
			wantField: "config",
			wantType:  "object",
		},
		{
			name:      "object field gets string",
			args:      map[string]interface{}{"name": "test", "config": "{}"},
			wantField: "config",
			wantType:  "object",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if result == nil {
				t.Fatal("expected error, got nil")
			}
			if result.Error == nil {
				t.Fatal("expected error in result, got nil")
			}
			if result.Error.Code != -32602 {
				t.Errorf("expected error code -32602, got %d", result.Error.Code)
			}
			if !strings.Contains(result.Error.Message, tt.wantField) {
				t.Errorf("expected message to contain field %q, got %q", tt.wantField, result.Error.Message)
			}
			if !strings.Contains(result.Error.Message, tt.wantType) {
				t.Errorf("expected message to contain type %q, got %q", tt.wantType, result.Error.Message)
			}
		})
	}
}

func TestValidateToolInput_OutOfRangeEnums(t *testing.T) {
	tests := []struct {
		name         string
		toolName     string
		args         map[string]interface{}
		invalidValue string
	}{
		{
			name:         "enum value not in list (string enum)",
			toolName:     "test_tool_with_required",
			args:         map[string]interface{}{"name": "test", "format": "csv"},
			invalidValue: "csv",
		},
		{
			name:         "enum value not in list (interface enum)",
			toolName:     "test_tool_no_required",
			args:         map[string]interface{}{"mode": "medium"},
			invalidValue: "medium",
		},
		{
			name:         "empty string not in enum",
			toolName:     "test_tool_with_required",
			args:         map[string]interface{}{"name": "test", "format": ""},
			invalidValue: "\"\"",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput(tt.toolName, tt.args, testValidationTools)
			if result == nil {
				t.Fatal("expected error, got nil")
			}
			if result.Error == nil {
				t.Fatal("expected error in result, got nil")
			}
			if result.Error.Code != -32602 {
				t.Errorf("expected error code -32602, got %d", result.Error.Code)
			}
			if !strings.Contains(result.Error.Message, "must be one of") {
				t.Errorf("expected message to contain 'must be one of', got %q", result.Error.Message)
			}
		})
	}
}

func TestValidateToolInput_ValidEnums(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		args     map[string]interface{}
	}{
		{
			name:     "valid enum value json (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]interface{}{"name": "test", "format": "json"},
		},
		{
			name:     "valid enum value xml (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]interface{}{"name": "test", "format": "xml"},
		},
		{
			name:     "valid enum value yaml (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]interface{}{"name": "test", "format": "yaml"},
		},
		{
			name:     "valid enum value fast (interface enum)",
			toolName: "test_tool_no_required",
			args:     map[string]interface{}{"mode": "fast"},
		},
		{
			name:     "valid enum value slow (interface enum)",
			toolName: "test_tool_no_required",
			args:     map[string]interface{}{"mode": "slow"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput(tt.toolName, tt.args, testValidationTools)
			if result != nil {
				t.Errorf("expected nil, got error: %v", result.Error)
			}
		})
	}
}

func TestValidateToolInput_ExtraUnknownFields(t *testing.T) {
	tests := []struct {
		name string
		args map[string]interface{}
	}{
		{
			name: "single extra field",
			args: map[string]interface{}{"name": "test", "unknown_field": "value"},
		},
		{
			name: "multiple extra fields",
			args: map[string]interface{}{"name": "test", "extra1": 123, "extra2": true, "extra3": []interface{}{"a"}},
		},
		{
			name: "extra nested object",
			args: map[string]interface{}{"name": "test", "nested": map[string]interface{}{"deep": "value"}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if result != nil {
				t.Errorf("expected nil (extra fields should be allowed), got error: %v", result.Error)
			}
		})
	}
}

func TestValidateToolInput_EmptyArgsObject(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		args     map[string]interface{}
	}{
		{
			name:     "empty args with no required fields",
			toolName: "test_tool_no_required",
			args:     map[string]interface{}{},
		},
		{
			name:     "nil args with no required fields",
			toolName: "test_tool_no_required",
			args:     nil,
		},
		{
			name:     "empty args with no schema",
			toolName: "test_tool_no_schema",
			args:     map[string]interface{}{},
		},
		{
			name:     "empty args with no properties",
			toolName: "test_tool_no_properties",
			args:     map[string]interface{}{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput(tt.toolName, tt.args, testValidationTools)
			if result != nil {
				t.Errorf("expected nil (empty args should be valid), got error: %v", result.Error)
			}
		})
	}
}

func TestValidateToolInput_NilNullValues(t *testing.T) {
	tests := []struct {
		name    string
		args    map[string]interface{}
		wantErr bool
	}{
		{
			name:    "nil value for optional field",
			args:    map[string]interface{}{"name": "test", "count": nil},
			wantErr: false,
		},
		{
			name:    "nil value for required field (field exists with null value)",
			args:    map[string]interface{}{"name": nil, "count": 5},
			wantErr: false, // Field exists, nil/null values are allowed per JSON Schema
		},
		{
			name:    "multiple nil optional fields",
			args:    map[string]interface{}{"name": "test", "count": nil, "enabled": nil, "ratio": nil},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if tt.wantErr {
				if result == nil {
					t.Fatal("expected error, got nil")
				}
				if result.Error == nil {
					t.Fatal("expected error in result, got nil")
				}
			} else {
				if result != nil {
					t.Errorf("expected nil, got error: %v", result.Error)
				}
			}
		})
	}
}

func TestValidateToolInput_IntegerVsFloat(t *testing.T) {
	tests := []struct {
		name    string
		args    map[string]interface{}
		wantErr bool
	}{
		{
			name:    "whole number float64 is valid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(5)},
			wantErr: false,
		},
		{
			name:    "1.0 is valid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(1.0)},
			wantErr: false,
		},
		{
			name:    "0.0 is valid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(0.0)},
			wantErr: false,
		},
		{
			name:    "-10.0 is valid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(-10.0)},
			wantErr: false,
		},
		{
			name:    "native int is valid integer",
			args:    map[string]interface{}{"name": "test", "count": 42},
			wantErr: false,
		},
		{
			name:    "decimal 1.5 is invalid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(1.5)},
			wantErr: true,
		},
		{
			name:    "decimal 0.1 is invalid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(0.1)},
			wantErr: true,
		},
		{
			name:    "decimal -3.14 is invalid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(-3.14)},
			wantErr: true,
		},
		{
			name:    "very small decimal is invalid integer",
			args:    map[string]interface{}{"name": "test", "count": float64(0.0001)},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if tt.wantErr {
				if result == nil {
					t.Fatal("expected error, got nil")
				}
				if result.Error == nil {
					t.Fatal("expected error in result, got nil")
				}
				if !strings.Contains(result.Error.Message, "integer") {
					t.Errorf("expected message to contain 'integer', got %q", result.Error.Message)
				}
			} else {
				if result != nil {
					t.Errorf("expected nil, got error: %v", result.Error)
				}
			}
		})
	}
}

func TestValidateToolInput_NumberType(t *testing.T) {
	tests := []struct {
		name    string
		args    map[string]interface{}
		wantErr bool
	}{
		{
			name:    "float64 is valid number",
			args:    map[string]interface{}{"name": "test", "ratio": float64(3.14)},
			wantErr: false,
		},
		{
			name:    "integer is valid number",
			args:    map[string]interface{}{"name": "test", "ratio": 42},
			wantErr: false,
		},
		{
			name:    "zero is valid number",
			args:    map[string]interface{}{"name": "test", "ratio": float64(0)},
			wantErr: false,
		},
		{
			name:    "negative float is valid number",
			args:    map[string]interface{}{"name": "test", "ratio": float64(-2.5)},
			wantErr: false,
		},
		{
			name:    "string is invalid number",
			args:    map[string]interface{}{"name": "test", "ratio": "3.14"},
			wantErr: true,
		},
		{
			name:    "boolean is invalid number",
			args:    map[string]interface{}{"name": "test", "ratio": true},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("test_tool_with_required", tt.args, testValidationTools)
			if tt.wantErr {
				if result == nil {
					t.Fatal("expected error, got nil")
				}
				if !strings.Contains(result.Error.Message, "number") {
					t.Errorf("expected message to contain 'number', got %q", result.Error.Message)
				}
			} else {
				if result != nil {
					t.Errorf("expected nil, got error: %v", result.Error)
				}
			}
		})
	}
}

func TestValidateToolInput_UnknownTool(t *testing.T) {
	result := validateToolInput("nonexistent_tool", map[string]interface{}{"field": "value"}, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for unknown tool (caller handles this), got error: %v", result.Error)
	}
}

func TestValidateToolInput_NoSchemaNoProperties(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		args     map[string]interface{}
	}{
		{
			name:     "tool with no schema accepts any args",
			toolName: "test_tool_no_schema",
			args:     map[string]interface{}{"anything": "goes", "number": 123},
		},
		{
			name:     "tool with no properties accepts any args",
			toolName: "test_tool_no_properties",
			args:     map[string]interface{}{"anything": "goes"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput(tt.toolName, tt.args, testValidationTools)
			if result != nil {
				t.Errorf("expected nil, got error: %v", result.Error)
			}
		})
	}
}

func TestValidateToolInput_RequiredFieldsStringArray(t *testing.T) {
	// Test with required field as []string instead of []interface{}
	result := validateToolInput("test_tool_required_string_array", map[string]interface{}{}, testValidationTools)
	if result == nil {
		t.Fatal("expected error for missing required field, got nil")
	}
	if !strings.Contains(result.Error.Message, "missing required field: id") {
		t.Errorf("expected 'missing required field: id', got %q", result.Error.Message)
	}

	// Valid case
	result = validateToolInput("test_tool_required_string_array", map[string]interface{}{"id": "abc"}, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for valid args, got error: %v", result.Error)
	}
}

func TestValidateToolInput_ValidCompleteArgs(t *testing.T) {
	// Test with all fields validly provided
	args := map[string]interface{}{
		"name":    "test-name",
		"count":   float64(10),
		"enabled": true,
		"ratio":   float64(2.5),
		"tags":    []interface{}{"a", "b", "c"},
		"config":  map[string]interface{}{"key": "value"},
		"format":  "json",
	}

	result := validateToolInput("test_tool_with_required", args, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for valid complete args, got error: %v", result.Error)
	}
}

func TestValidateToolInput_ErrorResponseFormat(t *testing.T) {
	// Verify the error response format matches JSON-RPC 2.0 spec
	result := validateToolInput("test_tool_with_required", map[string]interface{}{}, testValidationTools)
	if result == nil {
		t.Fatal("expected error, got nil")
	}

	// Check JSONRPC field
	if result.JSONRPC != "2.0" {
		t.Errorf("expected JSONRPC '2.0', got %q", result.JSONRPC)
	}

	// Check Error field
	if result.Error == nil {
		t.Fatal("expected Error field to be set")
	}

	// Check error code is ErrCodeInvalidParams (-32602)
	if result.Error.Code != -32602 {
		t.Errorf("expected error code -32602, got %d", result.Error.Code)
	}

	// Check that result and method are not set
	if len(result.Result) > 0 {
		t.Errorf("expected Result to be empty, got %s", string(result.Result))
	}
	if result.Method != "" {
		t.Errorf("expected Method to be empty, got %q", result.Method)
	}
}
