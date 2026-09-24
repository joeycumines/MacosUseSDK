// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/joeycumines/ExactMac/internal/config"
	"github.com/joeycumines/ExactMac/internal/transport"
)

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

// TestMCPServer_HandleHTTPMessage_Ping verifies the HTTP handler responds to
// ping with an empty result per MCP 2025-11-25.
func TestMCPServer_HandleHTTPMessage_Ping(t *testing.T) {
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	msg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`42`),
		Method:  "ping",
	}

	resp, err := s.handleHTTPMessage(msg)
	if err != nil {
		t.Fatalf("handleHTTPMessage returned error: %v", err)
	}
	if resp == nil {
		t.Fatal("handleHTTPMessage returned nil response")
	}
	if string(resp.ID) != "42" {
		t.Errorf("response id = %q, want %q", string(resp.ID), "42")
	}
	if string(resp.Result) != "{}" {
		t.Errorf("response result = %q, want %q", string(resp.Result), "{}")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error response: %+v", resp.Error)
	}
}

// TestHandleHTTPMessage_Initialize_Integration tests that handleHTTPMessage correctly calls
// validateAndProcessInitialize for initialize requests.
func TestHandleHTTPMessage_Initialize_Integration(t *testing.T) {
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}

	// Test with valid params
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

	resp, err := s.handleHTTPMessage(msg)
	if err != nil {
		t.Fatalf("handleHTTPMessage returned error: %v", err)
	}

	if resp == nil {
		t.Fatal("expected response, got nil")
	}

	if resp.Error != nil {
		t.Fatalf("unexpected error: %s", resp.Error.Message)
	}

	var result map[string]any
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}

	if result["protocolVersion"] != "2025-11-25" {
		t.Errorf("protocolVersion = %q, want %q", result["protocolVersion"], "2025-11-25")
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
			var result map[string]any
			if err := json.Unmarshal(resp.Result, &result); err != nil {
				t.Fatalf("Failed to parse result: %v", err)
			}

			// Verify MCP-required fields
			if _, ok := result["description"]; !ok {
				t.Error("Result should contain 'description' field")
			}

			messages, ok := result["messages"].([]any)
			if !ok || len(messages) == 0 {
				t.Error("Result should contain non-empty 'messages' array")
			} else {
				// Verify first message has role:user
				firstMsg, ok := messages[0].(map[string]any)
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
	var result map[string]any
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	// Verify prompts array
	prompts, ok := result["prompts"].([]any)
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
		prompt, ok := p.(map[string]any)
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
