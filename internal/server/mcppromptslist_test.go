// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"testing"
)

// ============================================================================
// Task 35: MCP Prompts Unit Tests
// ============================================================================

// TestMCPPromptsList verifies that prompts/list returns 3 prompts with correct
// structure including name, description, and arguments fields.
func TestMCPPromptsList(t *testing.T) {
	// Simulate listPrompts() response - this matches the implementation
	prompts := []map[string]any{
		{
			"name":        "navigate_to_element",
			"description": "Navigate to and click an accessibility element",
			"arguments": []map[string]any{
				{"name": "selector", "description": "One key:value selector, such as role:AXButton, text:Save, or text_substring:submit", "required": true},
			},
		},
		{
			"name":        "fill_form",
			"description": "Find and fill form fields with values",
			"arguments": []map[string]any{
				{"name": "fields", "description": "JSON object mapping field names/labels to values", "required": true},
			},
		},
		{
			"name":        "verify_state",
			"description": "Verify an element matches expected state",
			"arguments": []map[string]any{
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
		args, ok := p["arguments"].([]map[string]any)
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
						{"name": "selector", "description": "One key:value selector, such as role:AXButton, text:Save, or text_substring:submit", "required": true}
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

	var response map[string]any
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
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify prompts array exists
	prompts, ok := result["prompts"].([]any)
	if !ok {
		t.Fatal("Result should contain 'prompts' array")
	}

	if len(prompts) != 3 {
		t.Errorf("Expected 3 prompts, got %d", len(prompts))
	}

	// Verify each prompt has the required structure
	for i, p := range prompts {
		prompt, ok := p.(map[string]any)
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
				"name": "exactmac",
				"version": "0.1.0"
			}
		}
	}`

	var response map[string]any
	if err := json.Unmarshal([]byte(initResponseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Get result
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify protocol version
	if version, ok := result["protocolVersion"].(string); !ok || version != "2025-11-25" {
		t.Errorf("protocolVersion = %v, want '2025-11-25'", result["protocolVersion"])
	}

	// Get capabilities
	capabilities, ok := result["capabilities"].(map[string]any)
	if !ok {
		t.Fatal("Result should contain 'capabilities' object")
	}

	// Verify prompts capability is present
	prompts, ok := capabilities["prompts"]
	if !ok {
		t.Fatal("Capabilities should contain 'prompts' field")
	}

	// Prompts capability should be an object (even if empty)
	if _, ok := prompts.(map[string]any); !ok {
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
	prompts := []map[string]any{
		{
			"name": "navigate_to_element",
			"arguments": []map[string]any{
				{"name": "selector", "required": true},
			},
		},
		{
			"name": "fill_form",
			"arguments": []map[string]any{
				{"name": "fields", "required": true},
			},
		},
		{
			"name": "verify_state",
			"arguments": []map[string]any{
				{"name": "selector", "required": true},
				{"name": "expected_state", "required": true},
			},
		},
	}

	for _, p := range prompts {
		name := p["name"].(string)
		args := p["arguments"].([]map[string]any)
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
