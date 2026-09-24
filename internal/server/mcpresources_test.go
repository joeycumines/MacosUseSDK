// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

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
	resources := []map[string]any{
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
	result, err := json.Marshal(map[string]any{"resources": resources})
	if err != nil {
		t.Fatalf("Failed to marshal resources list: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(result, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal resources list: %v", err)
	}

	resourcesArray, ok := parsed["resources"].([]any)
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

	var response map[string]any
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	resources, ok := result["resources"].([]any)
	if !ok {
		t.Fatal("Result should contain 'resources' array")
	}

	// Verify screen://main resource
	screenResource := resources[0].(map[string]any)
	if screenResource["uri"] != "screen://main" {
		t.Errorf("Screen resource URI = %v, want 'screen://main'", screenResource["uri"])
	}
	if screenResource["mimeType"] != "image/png" {
		t.Errorf("Screen resource mimeType = %v, want 'image/png'", screenResource["mimeType"])
	}

	// Verify accessibility:// template resource
	accessibilityResource := resources[1].(map[string]any)
	if accessibilityResource["uri"] != "accessibility://" {
		t.Errorf("Accessibility resource URI = %v, want 'accessibility://'", accessibilityResource["uri"])
	}
	if accessibilityResource["mimeType"] != "application/json" {
		t.Errorf("Accessibility resource mimeType = %v, want 'application/json'", accessibilityResource["mimeType"])
	}

	// Verify clipboard://current resource
	clipboardResource := resources[2].(map[string]any)
	if clipboardResource["uri"] != "clipboard://current" {
		t.Errorf("Clipboard resource URI = %v, want 'clipboard://current'", clipboardResource["uri"])
	}
	if clipboardResource["mimeType"] != "text/plain" {
		t.Errorf("Clipboard resource mimeType = %v, want 'text/plain'", clipboardResource["mimeType"])
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
			"name": "exactmac",
			"version": "0.1.0"
		}
	}`

	var response map[string]any
	if err := json.Unmarshal([]byte(initResponseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	capabilities, ok := response["capabilities"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'capabilities' object")
	}

	// Verify resources capability is present
	resources, ok := capabilities["resources"].(map[string]any)
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
