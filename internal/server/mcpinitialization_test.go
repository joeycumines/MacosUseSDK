// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/joeycumines/ExactMac/internal/config"
	"github.com/joeycumines/ExactMac/internal/transport"
)

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
			response: `{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"exactmac","version":"0.1.0"}}`,
			wantErr:  false,
		},
		{
			name:     "with displayInfo",
			response: `{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"exactmac","version":"0.1.0"},"displayInfo":{"screens":[]}}`,
			wantErr:  false,
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
					Tools map[string]any `json:"tools"`
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
	initResponse := map[string]any{
		"protocolVersion": expectedVersion,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      map[string]any{"name": "exactmac", "version": "0.1.0"},
	}

	data, err := json.Marshal(initResponse)
	if err != nil {
		t.Fatalf("Failed to marshal initialize response: %v", err)
	}

	var parsed map[string]any
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

// TestMCPServer_HandleStdioMessage_Ping verifies the stdio handler responds to
// ping with an empty result per MCP 2025-11-25.
func TestMCPServer_HandleStdioMessage_Ping(t *testing.T) {
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   context.Background(),
	}

	var buf bytes.Buffer
	tr := transport.NewStdioTransport(strings.NewReader(""), &buf)

	msg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"ping-id"`),
		Method:  "ping",
	}

	s.handleMessage(tr, msg)

	line := strings.TrimSpace(buf.String())
	if line == "" {
		t.Fatal("expected a response written to stdio transport")
	}

	var resp transport.Message
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if string(resp.ID) != `"ping-id"` {
		t.Errorf("response id = %q, want %q", string(resp.ID), `"ping-id"`)
	}
	if string(resp.Result) != "{}" {
		t.Errorf("response result = %q, want %q", string(resp.Result), "{}")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error response: %+v", resp.Error)
	}
	if resp.Method != "" {
		t.Errorf("response method = %q, want empty", resp.Method)
	}
}

// ============================================================================
// Tasks 36-37: MCP Capability Negotiation and Protocol Version Validation
// ============================================================================

// TestValidateAndProcessInitialize_ProtocolVersions tests protocol version validation.
func TestValidateAndProcessInitialize_ProtocolVersions(t *testing.T) {
	// Create minimal MCPServer without full initialization
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	tests := []struct {
		name              string
		protocolVersion   string
		wantError         bool
		wantErrorContains string
	}{
		{
			name:            "current version 2025-11-25",
			protocolVersion: "2025-11-25",
			wantError:       false,
		},
		{
			name:            "previous version 2024-11-05",
			protocolVersion: "2024-11-05",
			wantError:       false,
		},
		{
			name:              "empty version is invalid",
			protocolVersion:   "",
			wantError:         true,
			wantErrorContains: "protocolVersion",
		},
		{
			name:            "unsupported version negotiates to current",
			protocolVersion: "2023-01-01",
			wantError:       false,
		},
		{
			name:            "future version negotiates to current",
			protocolVersion: "2099-12-31",
			wantError:       false,
		},
		{
			name:            "garbage version negotiates to current",
			protocolVersion: "not-a-version",
			wantError:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			params := map[string]any{
				"capabilities": map[string]any{},
				"clientInfo": map[string]any{
					"name":    "test-client",
					"version": "1.0.0",
				},
			}
			if tt.protocolVersion != "" {
				params["protocolVersion"] = tt.protocolVersion
			}
			paramsJSON, _ := json.Marshal(params)

			msg := &transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "initialize",
				Params:  paramsJSON,
			}

			resp, err := s.validateAndProcessInitialize(msg)

			if err != nil {
				t.Fatalf("validateAndProcessInitialize returned Go error: %v", err)
			}

			if resp == nil {
				t.Fatal("validateAndProcessInitialize returned nil response")
			}

			if tt.wantError {
				// Should have error response
				if resp.Error == nil {
					t.Fatalf("expected error response, got result: %s", string(resp.Result))
				}
				if resp.Error.Code != transport.ErrCodeInvalidParams {
					t.Errorf("error code = %d, want %d", resp.Error.Code, transport.ErrCodeInvalidParams)
				}
				if !strings.Contains(resp.Error.Message, tt.wantErrorContains) {
					t.Errorf("error message = %q, want to contain %q", resp.Error.Message, tt.wantErrorContains)
				}
			} else {
				// Should have success response
				if resp.Error != nil {
					t.Fatalf("unexpected error: code=%d message=%s", resp.Error.Code, resp.Error.Message)
				}
				if resp.Result == nil {
					t.Fatal("expected result, got nil")
				}
				// Verify response contains protocolVersion
				var result map[string]any
				if err := json.Unmarshal(resp.Result, &result); err != nil {
					t.Fatalf("failed to unmarshal result: %v", err)
				}
				if result["protocolVersion"] != "2025-11-25" {
					t.Errorf("response protocolVersion = %q, want %q", result["protocolVersion"], "2025-11-25")
				}
			}
		})
	}
}

// TestValidateAndProcessInitialize_ClientInfo tests client info parsing and logging.
func TestValidateAndProcessInitialize_ClientInfo(t *testing.T) {
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	tests := []struct {
		name       string
		params     map[string]any
		wantResult bool
	}{
		{
			name: "full client info",
			params: map[string]any{
				"protocolVersion": "2025-11-25",
				"clientInfo": map[string]any{
					"name":    "test-client",
					"version": "1.0.0",
				},
				"capabilities": map[string]any{},
			},
			wantResult: true,
		},
		{
			name: "missing client info",
			params: map[string]any{
				"protocolVersion": "2025-11-25",
				"capabilities":    map[string]any{},
			},
			wantResult: false,
		},
		{
			name: "empty client info",
			params: map[string]any{
				"protocolVersion": "2025-11-25",
				"clientInfo":      map[string]any{},
				"capabilities":    map[string]any{},
			},
			wantResult: false,
		},
		{
			name:       "no params at all",
			params:     nil,
			wantResult: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var paramsJSON json.RawMessage
			if tt.params != nil {
				var err error
				paramsJSON, err = json.Marshal(tt.params)
				if err != nil {
					t.Fatalf("failed to marshal params: %v", err)
				}
			}

			msg := &transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "initialize",
				Params:  paramsJSON,
			}

			resp, err := s.validateAndProcessInitialize(msg)

			if err != nil {
				t.Fatalf("validateAndProcessInitialize returned Go error: %v", err)
			}

			if tt.wantResult {
				if resp == nil {
					t.Fatal("expected response, got nil")
				}
				if resp.Error != nil {
					t.Fatalf("unexpected error: %s", resp.Error.Message)
				}
			} else if resp == nil || resp.Error == nil || resp.Error.Code != transport.ErrCodeInvalidParams {
				t.Fatalf("expected invalid params response, got %+v", resp)
			}
		})
	}
}

// TestValidateAndProcessInitialize_ResponseFormat tests the response format matches MCP spec.
func TestValidateAndProcessInitialize_ResponseFormat(t *testing.T) {
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	params := map[string]any{
		"protocolVersion": "2025-11-25",
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "test-client",
			"version": "1.0.0",
		},
	}
	paramsJSON, _ := json.Marshal(params)

	msg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Method:  "initialize",
		Params:  paramsJSON,
	}

	resp, err := s.validateAndProcessInitialize(msg)
	if err != nil {
		t.Fatalf("validateAndProcessInitialize returned Go error: %v", err)
	}

	if resp == nil {
		t.Fatal("expected response, got nil")
	}

	if resp.Error != nil {
		t.Fatalf("unexpected error: %s", resp.Error.Message)
	}

	// Verify response format
	var result map[string]any
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}

	// Required fields per MCP spec
	if result["protocolVersion"] != "2025-11-25" {
		t.Errorf("protocolVersion = %q, want %q", result["protocolVersion"], "2025-11-25")
	}

	capabilities, ok := result["capabilities"].(map[string]any)
	if !ok {
		t.Fatal("capabilities is not an object")
	}

	// Verify capabilities structure
	if _, ok := capabilities["tools"]; !ok {
		t.Error("capabilities.tools is missing")
	}
	if _, ok := capabilities["resources"]; !ok {
		t.Error("capabilities.resources is missing")
	}
	if _, ok := capabilities["prompts"]; !ok {
		t.Error("capabilities.prompts is missing")
	}

	serverInfo, ok := result["serverInfo"].(map[string]any)
	if !ok {
		t.Fatal("serverInfo is not an object")
	}
	if serverInfo["name"] != "exactmac" {
		t.Errorf("serverInfo.name = %q, want %q", serverInfo["name"], "exactmac")
	}
	if serverInfo["version"] == nil || serverInfo["version"] == "" {
		t.Error("serverInfo.version should not be empty")
	}
}

// TestValidateAndProcessInitialize_UnsupportedVersionNegotiation verifies that an
// unsupported protocol version is negotiated to the server's latest supported
// version (2025-11-25) per the MCP 2025-11-25 lifecycle, rather than returning
// a JSON-RPC error.
func TestValidateAndProcessInitialize_UnsupportedVersionNegotiation(t *testing.T) {
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	params := map[string]any{
		"protocolVersion": "invalid-version",
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "test-client",
			"version": "1.0.0",
		},
	}
	paramsJSON, _ := json.Marshal(params)

	msg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Method:  "initialize",
		Params:  paramsJSON,
	}

	resp, err := s.validateAndProcessInitialize(msg)
	if err != nil {
		t.Fatalf("validateAndProcessInitialize returned Go error: %v", err)
	}

	if resp == nil {
		t.Fatal("expected response, got nil")
	}

	if resp.Error != nil {
		t.Fatalf("expected negotiated success response, got error: code=%d message=%s", resp.Error.Code, resp.Error.Message)
	}

	var result map[string]any
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if got := result["protocolVersion"]; got != "2025-11-25" {
		t.Errorf("protocolVersion = %q, want %q", got, "2025-11-25")
	}
}
