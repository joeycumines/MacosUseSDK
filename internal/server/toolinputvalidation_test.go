// Copyright 2026 Joseph Cumines

package server

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// Test tool schemas for validateToolInput tests.
var testValidationTools = map[string]*Tool{
	"test_tool_with_required": {
		Name: "test_tool_with_required",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":    map[string]any{"type": "string"},
				"count":   map[string]any{"type": "integer"},
				"enabled": map[string]any{"type": "boolean"},
				"ratio":   map[string]any{"type": "number"},
				"tags":    map[string]any{"type": "array"},
				"config":  map[string]any{"type": "object"},
				"format": map[string]any{
					"type": "string",
					"enum": []string{"json", "xml", "yaml"},
				},
			},
			"required": []any{"name"},
		},
	},
	"test_tool_no_required": {
		Name: "test_tool_no_required",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer"},
				"mode":  map[string]any{"type": "string", "enum": []any{"fast", "slow"}},
			},
		},
	},
	"test_tool_no_schema": {
		Name: "test_tool_no_schema",
	},
	"test_tool_no_properties": {
		Name: "test_tool_no_properties",
		InputSchema: map[string]any{
			"type": "object",
		},
	},
	"test_tool_required_string_array": {
		Name: "test_tool_required_string_array",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"id": map[string]any{"type": "string"},
			},
			"required": []string{"id"},
		},
	},
	"test_tool_no_additional_props": {
		Name: "test_tool_no_additional_props",
		InputSchema: map[string]any{
			"type":                 "object",
			"additionalProperties": false,
		},
	},
	"test_tool_props_no_additional_props": {
		Name: "test_tool_props_no_additional_props",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name": map[string]any{"type": "string"},
			},
			"required":             []string{"name"},
			"additionalProperties": false,
		},
	},
}

func TestValidateToolInput_MissingRequiredFields(t *testing.T) {
	tests := []struct {
		name    string
		args    map[string]any
		wantErr string
	}{
		{
			name:    "missing required name field",
			args:    map[string]any{"count": 5},
			wantErr: "missing required field: name",
		},
		{
			name:    "empty args missing required",
			args:    map[string]any{},
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
		args      map[string]any
		wantField string
		wantType  string
	}{
		{
			name:      "string field gets number",
			args:      map[string]any{"name": 123},
			wantField: "name",
			wantType:  "string",
		},
		{
			name:      "integer field gets string",
			args:      map[string]any{"name": "test", "count": "five"},
			wantField: "count",
			wantType:  "integer",
		},
		{
			name:      "boolean field gets string",
			args:      map[string]any{"name": "test", "enabled": "true"},
			wantField: "enabled",
			wantType:  "boolean",
		},
		{
			name:      "boolean field gets number",
			args:      map[string]any{"name": "test", "enabled": 1},
			wantField: "enabled",
			wantType:  "boolean",
		},
		{
			name:      "number field gets string",
			args:      map[string]any{"name": "test", "ratio": "3.14"},
			wantField: "ratio",
			wantType:  "number",
		},
		{
			name:      "array field gets object",
			args:      map[string]any{"name": "test", "tags": map[string]any{"key": "value"}},
			wantField: "tags",
			wantType:  "array",
		},
		{
			name:      "array field gets string",
			args:      map[string]any{"name": "test", "tags": "tag1,tag2"},
			wantField: "tags",
			wantType:  "array",
		},
		{
			name:      "object field gets array",
			args:      map[string]any{"name": "test", "config": []any{"a", "b"}},
			wantField: "config",
			wantType:  "object",
		},
		{
			name:      "object field gets string",
			args:      map[string]any{"name": "test", "config": "{}"},
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
		args         map[string]any
		invalidValue string
	}{
		{
			name:         "enum value not in list (string enum)",
			toolName:     "test_tool_with_required",
			args:         map[string]any{"name": "test", "format": "csv"},
			invalidValue: "csv",
		},
		{
			name:         "enum value not in list (interface enum)",
			toolName:     "test_tool_no_required",
			args:         map[string]any{"mode": "medium"},
			invalidValue: "medium",
		},
		{
			name:         "empty string not in enum",
			toolName:     "test_tool_with_required",
			args:         map[string]any{"name": "test", "format": ""},
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
		args     map[string]any
	}{
		{
			name:     "valid enum value json (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]any{"name": "test", "format": "json"},
		},
		{
			name:     "valid enum value xml (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]any{"name": "test", "format": "xml"},
		},
		{
			name:     "valid enum value yaml (string enum)",
			toolName: "test_tool_with_required",
			args:     map[string]any{"name": "test", "format": "yaml"},
		},
		{
			name:     "valid enum value fast (interface enum)",
			toolName: "test_tool_no_required",
			args:     map[string]any{"mode": "fast"},
		},
		{
			name:     "valid enum value slow (interface enum)",
			toolName: "test_tool_no_required",
			args:     map[string]any{"mode": "slow"},
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
		args map[string]any
	}{
		{
			name: "single extra field",
			args: map[string]any{"name": "test", "unknown_field": "value"},
		},
		{
			name: "multiple extra fields",
			args: map[string]any{"name": "test", "extra1": 123, "extra2": true, "extra3": []any{"a"}},
		},
		{
			name: "extra nested object",
			args: map[string]any{"name": "test", "nested": map[string]any{"deep": "value"}},
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

func TestValidateToolInput_AdditionalPropertiesFalse(t *testing.T) {
	tests := []struct {
		name    string
		tool    string
		args    map[string]any
		wantErr string
	}{
		{
			name:    "no args allowed when additionalProperties false",
			tool:    "test_tool_no_additional_props",
			args:    map[string]any{"name": "test"},
			wantErr: "additional property not allowed: name",
		},
		{
			name:    "extra property rejected",
			tool:    "test_tool_props_no_additional_props",
			args:    map[string]any{"name": "test", "extra": "value"},
			wantErr: "additional property not allowed: extra",
		},
		{
			name:    "valid args pass",
			tool:    "test_tool_props_no_additional_props",
			args:    map[string]any{"name": "test"},
			wantErr: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput(tt.tool, tt.args, testValidationTools)
			if tt.wantErr == "" {
				if result != nil {
					t.Errorf("expected nil, got error: %v", result.Error)
				}
				return
			}
			if result == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErr)
			}
			if result.Error == nil {
				t.Fatalf("expected error containing %q, got result", result.Result)
			}
			if !strings.Contains(result.Error.Message, tt.wantErr) {
				t.Errorf("error message = %q, want to contain %q", result.Error.Message, tt.wantErr)
			}
		})
	}
}

func TestValidateToolInput_EmptyArgsObject(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		args     map[string]any
	}{
		{
			name:     "empty args with no required fields",
			toolName: "test_tool_no_required",
			args:     map[string]any{},
		},
		{
			name:     "nil args with no required fields",
			toolName: "test_tool_no_required",
			args:     nil,
		},
		{
			name:     "empty args with no schema",
			toolName: "test_tool_no_schema",
			args:     map[string]any{},
		},
		{
			name:     "empty args with no properties",
			toolName: "test_tool_no_properties",
			args:     map[string]any{},
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
		args    map[string]any
		wantErr bool
	}{
		{
			name:    "nil value for optional field",
			args:    map[string]any{"name": "test", "count": nil},
			wantErr: true,
		},
		{
			name:    "nil value for required field (field exists with null value)",
			args:    map[string]any{"name": nil, "count": 5},
			wantErr: true,
		},
		{
			name:    "multiple nil optional fields",
			args:    map[string]any{"name": "test", "count": nil, "enabled": nil, "ratio": nil},
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
		args    map[string]any
		wantErr bool
	}{
		{
			name:    "whole number float64 is valid integer",
			args:    map[string]any{"name": "test", "count": float64(5)},
			wantErr: false,
		},
		{
			name:    "1.0 is valid integer",
			args:    map[string]any{"name": "test", "count": float64(1.0)},
			wantErr: false,
		},
		{
			name:    "0.0 is valid integer",
			args:    map[string]any{"name": "test", "count": float64(0.0)},
			wantErr: false,
		},
		{
			name:    "-10.0 is valid integer",
			args:    map[string]any{"name": "test", "count": float64(-10.0)},
			wantErr: false,
		},
		{
			name:    "native int is valid integer",
			args:    map[string]any{"name": "test", "count": 42},
			wantErr: false,
		},
		{
			name:    "decimal 1.5 is invalid integer",
			args:    map[string]any{"name": "test", "count": float64(1.5)},
			wantErr: true,
		},
		{
			name:    "decimal 0.1 is invalid integer",
			args:    map[string]any{"name": "test", "count": float64(0.1)},
			wantErr: true,
		},
		{
			name:    "decimal -3.14 is invalid integer",
			args:    map[string]any{"name": "test", "count": float64(-3.14)},
			wantErr: true,
		},
		{
			name:    "very small decimal is invalid integer",
			args:    map[string]any{"name": "test", "count": float64(0.0001)},
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
		args    map[string]any
		wantErr bool
	}{
		{
			name:    "float64 is valid number",
			args:    map[string]any{"name": "test", "ratio": float64(3.14)},
			wantErr: false,
		},
		{
			name:    "integer is valid number",
			args:    map[string]any{"name": "test", "ratio": 42},
			wantErr: false,
		},
		{
			name:    "zero is valid number",
			args:    map[string]any{"name": "test", "ratio": float64(0)},
			wantErr: false,
		},
		{
			name:    "negative float is valid number",
			args:    map[string]any{"name": "test", "ratio": float64(-2.5)},
			wantErr: false,
		},
		{
			name:    "string is invalid number",
			args:    map[string]any{"name": "test", "ratio": "3.14"},
			wantErr: true,
		},
		{
			name:    "boolean is invalid number",
			args:    map[string]any{"name": "test", "ratio": true},
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
	result := validateToolInput("nonexistent_tool", map[string]any{"field": "value"}, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for unknown tool (caller handles this), got error: %v", result.Error)
	}
}

func TestValidateToolInput_NoSchemaNoProperties(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		args     map[string]any
	}{
		{
			name:     "tool with no schema accepts any args",
			toolName: "test_tool_no_schema",
			args:     map[string]any{"anything": "goes", "number": 123},
		},
		{
			name:     "tool with no properties accepts any args",
			toolName: "test_tool_no_properties",
			args:     map[string]any{"anything": "goes"},
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
	result := validateToolInput("test_tool_required_string_array", map[string]any{}, testValidationTools)
	if result == nil {
		t.Fatal("expected error for missing required field, got nil")
	}
	if !strings.Contains(result.Error.Message, "missing required field: id") {
		t.Errorf("expected 'missing required field: id', got %q", result.Error.Message)
	}

	// Valid case
	result = validateToolInput("test_tool_required_string_array", map[string]any{"id": "abc"}, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for valid args, got error: %v", result.Error)
	}
}

func TestValidateToolInput_ValidCompleteArgs(t *testing.T) {
	// Test with all fields validly provided
	args := map[string]any{
		"name":    "test-name",
		"count":   float64(10),
		"enabled": true,
		"ratio":   float64(2.5),
		"tags":    []any{"a", "b", "c"},
		"config":  map[string]any{"key": "value"},
		"format":  "json",
	}

	result := validateToolInput("test_tool_with_required", args, testValidationTools)
	if result != nil {
		t.Errorf("expected nil for valid complete args, got error: %v", result.Error)
	}
}

func TestValidateToolInput_ErrorResponseFormat(t *testing.T) {
	// Verify the error response format matches JSON-RPC 2.0 spec
	result := validateToolInput("test_tool_with_required", map[string]any{}, testValidationTools)
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

func TestValidateToolInput_RecursiveConstraints(t *testing.T) {
	tools := map[string]*Tool{
		"recursive": {
			Name: "recursive",
			InputSchema: map[string]any{
				"type":                 "object",
				"additionalProperties": false,
				"required":             []string{"config", "points"},
				"properties": map[string]any{
					"config": map[string]any{
						"type":                 "object",
						"additionalProperties": false,
						"required":             []string{"label", "limit"},
						"properties": map[string]any{
							"label": map[string]any{"type": "string", "pattern": "^[a-z]{2,4}$", "minLength": 2, "maxLength": 4},
							"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 3},
						},
					},
					"points": map[string]any{
						"type":     "array",
						"minItems": 1,
						"maxItems": 2,
						"items": map[string]any{
							"type":                 "object",
							"additionalProperties": false,
							"required":             []string{"x", "y"},
							"properties": map[string]any{
								"x": map[string]any{"type": "number", "minimum": -10, "maximum": 10},
								"y": map[string]any{"type": "number", "minimum": -10, "maximum": 10},
							},
						},
					},
				},
			},
		},
	}
	valid := map[string]any{
		"config": map[string]any{"label": "axis", "limit": json.Number("3")},
		"points": []any{map[string]any{"x": json.Number("-10"), "y": json.Number("10")}},
	}
	if result := validateToolInput("recursive", valid, tools); result != nil {
		t.Fatalf("valid recursive input rejected: %+v", result.Error)
	}

	tests := []struct {
		name string
		args map[string]any
		path string
	}{
		{name: "null", args: map[string]any{"config": nil, "points": valid["points"]}, path: "config"},
		{name: "nested required", args: map[string]any{"config": map[string]any{"label": "axis"}, "points": valid["points"]}, path: "config.limit"},
		{name: "nested unknown", args: map[string]any{"config": map[string]any{"label": "axis", "limit": 2, "extra": true}, "points": valid["points"]}, path: "config.extra"},
		{name: "pattern", args: map[string]any{"config": map[string]any{"label": "AXIS", "limit": 2}, "points": valid["points"]}, path: "config.label"},
		{name: "minimum", args: map[string]any{"config": map[string]any{"label": "axis", "limit": 0}, "points": valid["points"]}, path: "config.limit"},
		{name: "maximum", args: map[string]any{"config": map[string]any{"label": "axis", "limit": 4}, "points": valid["points"]}, path: "config.limit"},
		{name: "array minimum", args: map[string]any{"config": valid["config"], "points": []any{}}, path: "points"},
		{name: "array maximum", args: map[string]any{"config": valid["config"], "points": []any{valid["points"].([]any)[0], valid["points"].([]any)[0], valid["points"].([]any)[0]}}, path: "points"},
		{name: "item required", args: map[string]any{"config": valid["config"], "points": []any{map[string]any{"x": 1}}}, path: "points[0].y"},
		{name: "item unknown", args: map[string]any{"config": valid["config"], "points": []any{map[string]any{"x": 1, "y": 2, "z": 3}}}, path: "points[0].z"},
		{name: "item range", args: map[string]any{"config": valid["config"], "points": []any{map[string]any{"x": 11, "y": 2}}}, path: "points[0].x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateToolInput("recursive", tt.args, tools)
			if result == nil || result.Error == nil {
				t.Fatalf("expected validation error for %s", tt.path)
			}
			if !strings.Contains(result.Error.Message, tt.path) {
				t.Fatalf("error %q does not identify %s", result.Error.Message, tt.path)
			}
		})
	}
}

func TestProductionToolSchemasAreRecursivelyClosed(t *testing.T) {
	server := &MCPServer{}
	server.registerTools()
	for name, tool := range server.tools {
		assertObjectSchemasClosed(t, name, tool.InputSchema)
	}
}

func TestProductionToolAdmissionRejectsMalformedIntentBeforeHandler(t *testing.T) {
	server := &MCPServer{}
	server.registerTools()
	calls := 0
	for _, name := range []string{"screenshot", "drag"} {
		server.tools[name].Handler = func(*ToolCall) (*ToolResult, error) {
			calls++
			return textResult("unexpected admission"), nil
		}
	}

	tests := []struct {
		name string
		tool string
		args string
	}{
		{name: "root unknown", tool: "screenshot", args: `{"unexpected":true}`},
		{name: "typed null", tool: "screenshot", args: `{"display":null}`},
		{name: "pattern", tool: "screenshot", args: `{"display":"displays/0"}`},
		{name: "minimum", tool: "screenshot", args: `{"quality":-1}`},
		{name: "maximum", tool: "screenshot", args: `{"quality":101}`},
		{name: "nested unknown", tool: "drag", args: `{"path":[{"x":1,"y":2,"unexpected":true}]}`},
	}
	for index, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			params := json.RawMessage(`{"name":"` + tt.tool + `","arguments":` + tt.args + `}`)
			response, err := server.handleHTTPMessage(&transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "tools/call",
				Params:  params,
			})
			if err != nil {
				t.Fatalf("dispatch failed: %v", err)
			}
			if response == nil || response.Error == nil || response.Error.Code != transport.ErrCodeInvalidParams {
				t.Fatalf("response = %+v, want invalid params", response)
			}
			if calls != 0 {
				t.Fatalf("handler calls after case %d = %d, want zero", index, calls)
			}
		})
	}
}

func TestToolCallNumberAdmissionIsLosslessAndOuterParamsAreClosed(t *testing.T) {
	calls := 0
	server := &MCPServer{tools: map[string]*Tool{
		"exact_integer": {
			Name:           "exact_integer",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type":                 "object",
				"additionalProperties": false,
				"required":             []string{"value"},
				"properties": map[string]any{
					"value": map[string]any{
						"type":    "integer",
						"minimum": json.Number("9007199254740993"),
						"maximum": json.Number("9007199254740993"),
					},
				},
			},
			Handler: func(*ToolCall) (*ToolResult, error) {
				calls++
				return textResult("admitted"), nil
			},
		},
	}}

	assertCall := func(params string, wantCode int, wantCalls int) {
		t.Helper()
		response, err := server.handleHTTPMessage(&transport.Message{
			JSONRPC: "2.0",
			ID:      json.RawMessage(`1`),
			Method:  "tools/call",
			Params:  json.RawMessage(params),
		})
		if err != nil {
			t.Fatalf("dispatch failed: %v", err)
		}
		if wantCode == 0 {
			if response == nil || response.Error != nil {
				t.Fatalf("response = %+v, want success", response)
			}
		} else if response == nil || response.Error == nil || response.Error.Code != wantCode {
			t.Fatalf("response = %+v, want code %d", response, wantCode)
		}
		if calls != wantCalls {
			t.Fatalf("handler calls = %d, want %d", calls, wantCalls)
		}
	}

	assertCall(`{"name":"exact_integer","arguments":{"value":9007199254740993}}`, 0, 1)
	assertCall(`{"name":"exact_integer","arguments":{"value":9007199254740992}}`, transport.ErrCodeInvalidParams, 1)
	assertCall(`{"name":"exact_integer","arguments":null}`, transport.ErrCodeInvalidParams, 1)
	assertCall(`{"name":"exact_integer","arguments":{"value":9007199254740993},"unexpected":true}`, transport.ErrCodeInvalidParams, 1)
}

func assertObjectSchemasClosed(t *testing.T, path string, schema map[string]any) {
	t.Helper()
	if schema == nil {
		t.Fatalf("%s has no schema", path)
	}
	if schema["type"] == "object" {
		// An object schema is closed when additionalProperties is explicitly
		// false. An explicit additionalProperties:true is a permitted author
		// opt-out for flexible containers (proto oneof branches whose payload
		// the handler validates via protojson); closeToolObjectSchemas respects
		// the same opt-out, so a bare object with no additionalProperties is the
		// only case that counts as not-closed.
		switch ap := schema["additionalProperties"].(type) {
		case bool:
			if ap {
				// Explicit opt-out: the branch is intentionally open.
			} else {
				// Explicitly closed.
			}
		default:
			t.Errorf("%s object schema is not closed (additionalProperties missing or non-boolean: %v)", path, schema["additionalProperties"])
		}
	}
	if properties, ok := schema["properties"].(map[string]any); ok {
		for name, value := range properties {
			if child, ok := value.(map[string]any); ok {
				assertObjectSchemasClosed(t, path+"."+name, child)
			}
		}
	}
	if items, ok := schema["items"].(map[string]any); ok {
		assertObjectSchemasClosed(t, path+"[]", items)
	}
}
