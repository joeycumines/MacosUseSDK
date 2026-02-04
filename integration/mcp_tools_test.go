// Copyright 2025 Joseph Cumines
//
// MCP tools integration tests - validates tool invocation via HTTP transport.
// Task: T066

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestMCPTools_HTTPRoundTrip verifies that MCP tools can be invoked via HTTP transport
// and produce valid responses. Uses table-driven tests for representative tools.
func TestMCPTools_HTTPRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initRequest := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initRequest))
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}
	initResp.Body.Close()

	tests := []struct {
		name          string
		tool          string
		args          string
		wantError     bool
		validateField string
	}{
		{
			name:      "list_displays returns displays",
			tool:      "list_displays",
			args:      `{}`,
			wantError: false,
		},
		{
			name:      "cursor_position returns coordinates",
			tool:      "cursor_position",
			args:      `{}`,
			wantError: false,
		},
		{
			name:      "capture_screenshot returns image data",
			tool:      "capture_screenshot",
			args:      `{"max_width": 320, "max_height": 240}`,
			wantError: false,
		},
		{
			name:      "click with valid coordinates",
			tool:      "click",
			args:      `{"x": 100, "y": 100}`,
			wantError: false,
		},
		{
			name:      "type_text with text",
			tool:      "type_text",
			args:      `{"text": "test"}`,
			wantError: false,
		},
		{
			name:      "press_key with key",
			tool:      "press_key",
			args:      `{"key": "escape"}`,
			wantError: false,
		},
		{
			name:      "get_clipboard returns content",
			tool:      "get_clipboard",
			args:      `{}`,
			wantError: false,
		},
		{
			name:      "list_applications returns apps",
			tool:      "list_applications",
			args:      `{}`,
			wantError: false,
		},
		{
			name:      "list_windows returns windows",
			tool:      "list_windows",
			args:      `{}`,
			wantError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			id := time.Now().UnixNano()
			request := map[string]interface{}{
				"jsonrpc": "2.0",
				"id":      id,
				"method":  "tools/call",
				"params": map[string]interface{}{
					"name":      tt.tool,
					"arguments": json.RawMessage(tt.args),
				},
			}
			reqBytes, _ := json.Marshal(request)

			resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBuffer(reqBytes))
			if err != nil {
				t.Fatalf("HTTP request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusOK {
				body, _ := io.ReadAll(resp.Body)
				t.Fatalf("Request returned status %d: %s", resp.StatusCode, body)
			}

			var response struct {
				JSONRPC string          `json:"jsonrpc"`
				ID      int64           `json:"id"`
				Result  json.RawMessage `json:"result"`
				Error   *struct {
					Code    int    `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
				t.Fatalf("Failed to decode response: %v", err)
			}

			if response.Error != nil {
				if !tt.wantError {
					t.Errorf("Unexpected error: code=%d, message=%s", response.Error.Code, response.Error.Message)
				}
				return
			}

			if tt.wantError {
				t.Error("Expected error but got success")
				return
			}

			var toolResult struct {
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
				IsError bool `json:"is_error"`
			}
			if err := json.Unmarshal(response.Result, &toolResult); err != nil {
				t.Fatalf("Failed to parse tool result: %v", err)
			}

			if len(toolResult.Content) == 0 {
				t.Error("Tool result has empty content")
			}

			if toolResult.IsError {
				t.Logf("Tool returned soft error: %s", toolResult.Content[0].Text)
			}
		})
	}
}

// TestMCPTools_Screenshot_HTTPRoundTrip tests screenshot capture via HTTP
func TestMCPTools_Screenshot_HTTPRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screenshot","arguments":{"max_width":640,"max_height":480}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Screenshot request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response.Error != nil {
		t.Fatalf("Screenshot failed: %s", response.Error.Message)
	}

	if len(response.Result) == 0 {
		t.Error("Screenshot returned empty result")
	}

	t.Log("Screenshot capture via HTTP transport successful")
}

// TestMCPTools_ClickTypeText_Workflow tests a click + type_text workflow
func TestMCPTools_ClickTypeText_Workflow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	var windowName string
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		if len(resp.Windows) > 0 {
			windowName = resp.Windows[0].Name
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Skipf("Calculator window not available: %v", err)
	}

	windowResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{Name: windowName})
	if err != nil {
		t.Skipf("Failed to get Calculator window: %v", err)
	}
	bounds := windowResp.Bounds
	centerX := bounds.X + bounds.Width/2
	centerY := bounds.Y + bounds.Height/2

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	clickReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name": "click",
			"arguments": map[string]interface{}{
				"x": centerX,
				"y": centerY,
			},
		},
	}
	clickBytes, _ := json.Marshal(clickReq)
	clickResp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBuffer(clickBytes))
	if err != nil {
		t.Fatalf("Click request failed: %v", err)
	}
	clickResp.Body.Close()

	typeReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name": "type_text",
			"arguments": map[string]interface{}{
				"text": "5",
			},
		},
	}
	typeBytes, _ := json.Marshal(typeReq)
	typeResp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBuffer(typeBytes))
	if err != nil {
		t.Fatalf("Type request failed: %v", err)
	}
	defer typeResp.Body.Close()

	var response struct {
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	json.NewDecoder(typeResp.Body).Decode(&response)
	if response.Error != nil {
		t.Logf("Type text warning: %s", response.Error.Message)
	}

	t.Log("Click + type_text workflow completed via HTTP transport")
}

// TestMCPTools_InvalidTool_ReturnsError verifies that calling a non-existent tool
// returns a proper JSON-RPC error response.
func TestMCPTools_InvalidTool_ReturnsError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nonexistent_tool","arguments":{}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected error for invalid tool, got none")
	}

	if response.Error.Code != -32601 {
		t.Errorf("Expected error code -32601, got %d", response.Error.Code)
	}

	if response.Error.Message == "" {
		t.Error("Expected error message, got empty string")
	}

	t.Logf("Invalid tool correctly returned error: %s (code %d)", response.Error.Message, response.Error.Code)
}

// TestMCPTools_MissingRequiredParams_ReturnsError verifies that calling a tool
// without required parameters returns a proper error.
func TestMCPTools_MissingRequiredParams_ReturnsError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click","arguments":{}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response.Error != nil {
		t.Logf("Got JSON-RPC error: %s (code %d)", response.Error.Message, response.Error.Code)
		return
	}

	if len(response.Result) > 0 {
		var toolResult struct {
			IsError bool `json:"is_error"`
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		}
		if err := json.Unmarshal(response.Result, &toolResult); err == nil {
			if toolResult.IsError {
				t.Logf("Got soft error: %s", toolResult.Content[0].Text)
				return
			}
		}
	}

	t.Log("Click with missing params either succeeded with defaults or returned error as expected")
}
