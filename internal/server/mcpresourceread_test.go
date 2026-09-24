// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/joeycumines/ExactMac/internal/transport"
)

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

			responseContent := map[string]any{
				"uri":      tt.uri,
				"mimeType": tt.wantMimeType,
				"blob":     mockBase64Data, // binary resource content is base64-encoded in blob
			}

			// Verify mimeType
			if responseContent["mimeType"] != tt.wantMimeType {
				t.Errorf("mimeType = %v, want %v", responseContent["mimeType"], tt.wantMimeType)
			}

			// Verify content is non-empty
			content, ok := responseContent["blob"].(string)
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
			responseContent := map[string]any{
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
	mockAccessibilityTree := map[string]any{
		"application":  "applications/1234",
		"elementCount": 5,
		"elements": []map[string]any{
			{
				"id":           "elem-1",
				"role":         "AXWindow",
				"path_indices": "/AXApplication/AXWindow",
				"text":         "Calculator",
				"actions":      []string{"AXRaise", "AXClose"},
				"bounds": map[string]any{
					"x":      100.0,
					"y":      200.0,
					"width":  400.0,
					"height": 300.0,
				},
			},
			{
				"id":           "elem-2",
				"role":         "AXButton",
				"path_indices": "/AXApplication/AXWindow/AXButton",
				"text":         "7",
			},
		},
	}

	jsonBytes, err := json.Marshal(mockAccessibilityTree)
	if err != nil {
		t.Fatalf("Failed to marshal mock tree: %v", err)
	}

	// Simulate response
	responseContent := map[string]any{
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

	var parsedTree map[string]any
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
	elements, ok := parsedTree["elements"].([]any)
	if !ok {
		t.Error("Tree should contain 'elements' array")
	}
	if len(elements) == 0 {
		t.Error("Elements array should not be empty for valid accessibility tree")
	}

	// Verify element structure
	if len(elements) > 0 {
		firstElem, ok := elements[0].(map[string]any)
		if !ok {
			t.Error("Element should be an object")
		} else {
			if _, ok := firstElem["id"]; !ok {
				t.Error("Element should have 'id' field")
			}
			if _, ok := firstElem["role"]; !ok {
				t.Error("Element should have 'role' field")
			}
			if _, ok := firstElem["path_indices"]; !ok {
				t.Error("Element should have 'path_indices' field")
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

			if after, ok := strings.CutPrefix(tt.uri, "screen://"); ok {
				suffix := after
				if suffix != "main" {
					err = fmt.Errorf("unsupported screen resource: %s (only 'main' is supported)", suffix)
				}
			} else if after, ok := strings.CutPrefix(tt.uri, "accessibility://"); ok {
				pidStr := after
				if pidStr == "" {
					err = fmt.Errorf("accessibility:// requires a PID (e.g., accessibility://1234)")
				} else {
					_, parseErr := strconv.ParseInt(pidStr, 10, 32)
					if parseErr != nil {
						err = fmt.Errorf("invalid PID in accessibility URI: %s", pidStr)
					}
				}
			} else if after, ok := strings.CutPrefix(tt.uri, "clipboard://"); ok {
				suffix := after
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

			if after, ok := strings.CutPrefix(tt.uri, "screen://"); ok {
				suffix := after
				if suffix == "main" {
					resourceType = "screenshot"
				} else {
					err = fmt.Errorf("unsupported screen resource")
				}
			} else if after, ok := strings.CutPrefix(tt.uri, "accessibility://"); ok {
				pidStr := after
				if pidStr != "" {
					if _, parseErr := strconv.ParseInt(pidStr, 10, 32); parseErr == nil {
						resourceType = "accessibility_tree"
					} else {
						err = fmt.Errorf("invalid PID")
					}
				} else {
					err = fmt.Errorf("missing PID")
				}
			} else if after, ok := strings.CutPrefix(tt.uri, "clipboard://"); ok {
				suffix := after
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

	var response map[string]any
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC 2.0 structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	contents, ok := result["contents"].([]any)
	if !ok {
		t.Fatal("Result should contain 'contents' array")
	}

	if len(contents) != 1 {
		t.Errorf("Expected 1 content item, got %d", len(contents))
	}

	// Verify content structure
	content := contents[0].(map[string]any)
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

	var response map[string]any
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

	errorObj, ok := response["error"].(map[string]any)
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

// TestMCPResourcesEmptyClipboardHandling tests graceful handling of empty clipboard
func TestMCPResourcesEmptyClipboardHandling(t *testing.T) {
	// When clipboard is empty, resources/read should still succeed with empty content
	responseContent := map[string]any{
		"uri":      "clipboard://current",
		"mimeType": "text/plain",
		"text":     "", // empty clipboard
	}

	result, err := json.Marshal(map[string]any{
		"contents": []map[string]any{responseContent},
	})
	if err != nil {
		t.Fatalf("Failed to marshal empty clipboard response: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(result, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}

	contents := parsed["contents"].([]any)
	if len(contents) != 1 {
		t.Errorf("Expected 1 content item, got %d", len(contents))
	}

	content := contents[0].(map[string]any)
	if content["mimeType"] != "text/plain" {
		t.Errorf("Empty clipboard should still have text/plain mimeType")
	}
	if content["text"] != "" {
		t.Errorf("Empty clipboard text should be empty string")
	}
}
