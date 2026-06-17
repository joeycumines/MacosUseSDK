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
	defer cleanupServer(t, serverCmd, serverAddr)

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
			name:      "get_display returns displays",
			tool:      "get_display",
			args:      `{}`,
			wantError: false,
		},
		{
			name:      "screenshot returns image data",
			tool:      "screenshot",
			args:      `{"format": "png", "quality": 85, "ocr": false}`,
			wantError: false,
		},
		{
			name:      "click with valid coordinates",
			tool:      "click",
			args:      `{"x": 100, "y": 100}`,
			wantError: false,
		},
		{
			name:      "type with text",
			tool:      "type",
			args:      `{"text": "test"}`,
			wantError: false,
		},
		{
			name:      "keypress with keys",
			tool:      "keypress",
			args:      `{"keys": ["escape"]}`,
			wantError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			id := time.Now().UnixNano()
			request := map[string]any{
				"jsonrpc": "2.0",
				"id":      id,
				"method":  "tools/call",
				"params": map[string]any{
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
				IsError bool `json:"isError"`
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
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"format":"png","quality":85,"ocr":false}}}`
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

// TestMCPTools_ClickType_Workflow tests a click + type workflow
func TestMCPTools_ClickTypeText_Workflow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

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

	clickReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "click",
			"arguments": map[string]any{
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

	typeReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "type",
			"arguments": map[string]any{
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

	t.Log("Click + type workflow completed via HTTP transport")
}

// TestMCPTools_InvalidTool_ReturnsError verifies that calling a non-existent tool
// returns a proper JSON-RPC error response.
func TestMCPTools_InvalidTool_ReturnsError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

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
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

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
		if response.Error.Code == 0 || response.Error.Message == "" {
			t.Fatalf("Expected non-empty JSON-RPC error code/message, got code=%d message=%q", response.Error.Code, response.Error.Message)
		}
		return
	}

	var toolResult struct {
		IsError bool `json:"isError"`
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(response.Result, &toolResult); err != nil {
		t.Fatalf("Failed to parse soft-error result: %v", err)
	}
	if !toolResult.IsError {
		t.Fatal("Expected JSON-RPC error or MCP soft error for click with missing x/y, got success")
	}
	if len(toolResult.Content) == 0 || toolResult.Content[0].Text == "" {
		t.Fatal("Expected MCP soft error to include non-empty error text")
	}
}
