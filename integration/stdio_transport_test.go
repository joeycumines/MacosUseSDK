// Copyright 2025 Joseph Cumines
//
// MCP stdio transport integration tests - validates JSON-RPC communication
// over stdin/stdout with the macos-use-mcp binary.
// Task: T018

package integration

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"testing"
	"time"
)

// TestStdioTransport_Initialize verifies the MCP stdio transport correctly
// handles the initialize handshake and returns the expected protocol version.
func TestStdioTransport_Initialize(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	mcpCmd, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Send initialize request
	initReq := validMCPInitializeRequest(1)

	response, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		// Check if process died
		if mcpCmd.ProcessState != nil {
			t.Fatalf("MCP process exited unexpectedly: %v", mcpCmd.ProcessState)
		}
		t.Fatalf("Failed to send initialize request: %v", err)
	}

	// Verify response structure
	if response.JSONRPC != "2.0" {
		t.Errorf("response.jsonrpc = %q, want %q", response.JSONRPC, "2.0")
	}

	if response.Error != nil {
		t.Fatalf("Initialize returned error: code=%d, message=%s", response.Error.Code, response.Error.Message)
	}

	if response.Result == nil {
		t.Fatal("Initialize returned nil result")
	}

	// Parse result
	var initResult struct {
		ProtocolVersion string `json:"protocolVersion"`
		Capabilities    struct {
			Tools map[string]any `json:"tools"`
		} `json:"capabilities"`
		ServerInfo struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
		DisplayInfo json.RawMessage `json:"displayInfo,omitempty"`
	}
	if err := json.Unmarshal(response.Result, &initResult); err != nil {
		t.Fatalf("Failed to unmarshal init result: %v", err)
	}

	const expectedVersion = "2025-11-25"
	if initResult.ProtocolVersion != expectedVersion {
		t.Errorf("protocolVersion = %q, want %q", initResult.ProtocolVersion, expectedVersion)
	}

	if initResult.ServerInfo.Name != "macos-use-sdk" {
		t.Errorf("serverInfo.name = %q, want %q", initResult.ServerInfo.Name, "macos-use-sdk")
	}

	t.Logf("Initialize succeeded: protocol=%s, server=%s", initResult.ProtocolVersion, initResult.ServerInfo.Name)
}

// TestStdioTransport_ToolsList verifies that tools/list returns the expected
// redesigned MCP tools including screenshot.
func TestStdioTransport_ToolsList(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Initialize first
	initReq := validMCPInitializeRequest(1)
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send tools/list request
	toolsReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/list",
		"params":  map[string]any{},
	}

	response, err := sendStdioRequest(ctx, stdin, stdout, toolsReq)
	if err != nil {
		t.Fatalf("Failed to send tools/list request: %v", err)
	}

	if response.Error != nil {
		t.Fatalf("tools/list returned error: code=%d, message=%s", response.Error.Code, response.Error.Message)
	}

	// Parse result
	var toolsResult struct {
		Tools []struct {
			Name        string         `json:"name"`
			Description string         `json:"description"`
			InputSchema map[string]any `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(response.Result, &toolsResult); err != nil {
		t.Fatalf("Failed to unmarshal tools result: %v", err)
	}

	if len(toolsResult.Tools) == 0 {
		t.Fatal("tools/list returned empty tools list")
	}

	// Verify screenshot is present
	foundScreenshot := false
	foundClick := false
	foundType := false
	for _, tool := range toolsResult.Tools {
		switch tool.Name {
		case "screenshot":
			foundScreenshot = true
			if tool.Description == "" {
				t.Error("screenshot has empty description")
			}
		case "click":
			foundClick = true
		case "type":
			foundType = true
		}
	}

	if !foundScreenshot {
		t.Error("screenshot tool not found in tools/list")
	}
	if !foundClick {
		t.Error("click tool not found in tools/list")
	}
	if !foundType {
		t.Error("type tool not found in tools/list")
	}

	t.Logf("tools/list returned %d tools", len(toolsResult.Tools))
}

// TestStdioTransport_CaptureScreenshot verifies that screenshot tool
// can be invoked via stdio transport and returns either image data or a
// structured soft error (isError=true) when permissions are not available.
func TestStdioTransport_CaptureScreenshot(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Initialize first
	initReq := validMCPInitializeRequest(1)
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send tools/call for screenshot
	callReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "screenshot",
			"arguments": map[string]any{
				"format": "png",
			},
		},
	}

	response, err := sendStdioRequest(ctx, stdin, stdout, callReq)
	if err != nil {
		t.Fatalf("Failed to send tools/call request: %v", err)
	}

	// The response should NOT be a JSON-RPC error - tool errors are soft errors
	if response.Error != nil {
		t.Fatalf("tools/call returned JSON-RPC error: code=%d, message=%s", response.Error.Code, response.Error.Message)
	}

	// Result must be present
	if response.Result == nil {
		t.Fatal("tools/call returned nil result")
	}

	// Parse tool result - should have the expected structure
	var toolResult struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text,omitempty"`
			Data     string `json:"data,omitempty"`
			MimeType string `json:"mimeType,omitempty"`
		} `json:"content"`
		IsError bool `json:"isError,omitempty"`
	}
	if err := json.Unmarshal(response.Result, &toolResult); err != nil {
		t.Fatalf("Failed to unmarshal tool result: %v", err)
	}

	// Content array must exist
	if len(toolResult.Content) == 0 {
		t.Fatal("Tool result has empty content array")
	}

	// If we got a soft error, verify the error has useful content
	if toolResult.IsError {
		foundErrorText := false
		for _, c := range toolResult.Content {
			if c.Type == "text" && c.Text != "" {
				foundErrorText = true
				t.Logf("Screenshot returned soft error (expected if permissions unavailable): %s", c.Text)
			}
		}
		if !foundErrorText {
			t.Error("Soft error has no text content")
		}
		// This is acceptable - screenshot may fail due to permissions
		return
	}

	// If not an error, verify we have image content
	foundImage := false
	for _, c := range toolResult.Content {
		if c.Type == "image" {
			foundImage = true
			if c.Data == "" {
				t.Error("Image content has empty data")
			}
			if c.MimeType != "image/png" {
				t.Errorf("Image mimeType = %q, want %q", c.MimeType, "image/png")
			}
			t.Logf("Screenshot captured: %d bytes (base64)", len(c.Data))
		}
	}

	if !foundImage {
		t.Error("No image content in screenshot response")
		t.Logf("Content: %+v", toolResult.Content)
	}
}

// TestStdioTransport_FullWorkflow exercises the complete stdio workflow:
// initialize -> tools/list -> tools/call sequence.
func TestStdioTransport_FullWorkflow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Step 1: Initialize
	t.Log("Step 1: Sending initialize...")
	initReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params": map[string]any{
			"protocolVersion": "2025-11-25",
			"capabilities":    map[string]any{},
			"clientInfo": map[string]any{
				"name":    "workflow-test",
				"version": "1.0.0",
			},
		},
	}
	initResp, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}
	if initResp.Error != nil {
		t.Fatalf("Initialize error: %s", initResp.Error.Message)
	}
	t.Log("Step 1: Initialize succeeded")

	// Step 2: notifications/initialized (no response expected, but server should accept)
	// Note: For stdio, we can still send this - server may or may not respond
	t.Log("Step 2: Sending notifications/initialized...")
	notifyReq := map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}
	// Send notification (no ID, so no response expected)
	if err := writeStdioMessage(stdin, notifyReq); err != nil {
		t.Fatalf("Failed to send notification: %v", err)
	}
	t.Log("Step 2: notifications/initialized sent")

	// Step 3: tools/list
	t.Log("Step 3: Sending tools/list...")
	toolsReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/list",
		"params":  map[string]any{},
	}
	toolsResp, err := sendStdioRequest(ctx, stdin, stdout, toolsReq)
	if err != nil {
		t.Fatalf("tools/list failed: %v", err)
	}
	if toolsResp.Error != nil {
		t.Fatalf("tools/list error: %s", toolsResp.Error.Message)
	}

	var toolsResult struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(toolsResp.Result, &toolsResult); err != nil {
		t.Fatalf("Failed to parse tools: %v", err)
	}
	t.Logf("Step 3: Got %d tools", len(toolsResult.Tools))

	// Step 4: tools/call - get_display (lightweight operation)
	t.Log("Step 4: Sending tools/call for get_display...")
	displayReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "get_display",
			"arguments": map[string]any{},
		},
	}
	displayResp, err := sendStdioRequest(ctx, stdin, stdout, displayReq)
	if err != nil {
		t.Fatalf("get_display failed: %v", err)
	}
	if displayResp.Error != nil {
		t.Fatalf("get_display error: %s", displayResp.Error.Message)
	}

	var displayResult struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text,omitempty"`
		} `json:"content"`
	}
	if err := json.Unmarshal(displayResp.Result, &displayResult); err != nil {
		t.Fatalf("Failed to parse display result: %v", err)
	}

	if len(displayResult.Content) == 0 {
		t.Error("get_display returned empty content")
	} else {
		// The first content item should contain display info as text
		for _, c := range displayResult.Content {
			if c.Type == "text" && c.Text != "" {
				t.Logf("Step 4: Display info received (%d chars)", len(c.Text))
				break
			}
		}
	}

	// Step 5: tools/call - screenshot
	t.Log("Step 5: Sending tools/call for screenshot...")
	screenshotReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      4,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "screenshot",
			"arguments": map[string]any{
				"format": "jpeg",
			},
		},
	}
	screenshotResp, err := sendStdioRequest(ctx, stdin, stdout, screenshotReq)
	if err != nil {
		t.Fatalf("screenshot failed: %v", err)
	}
	if screenshotResp.Error != nil {
		t.Fatalf("screenshot JSON-RPC error: %s", screenshotResp.Error.Message)
	}

	var screenshotResult struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text,omitempty"`
			Data     string `json:"data,omitempty"`
			MimeType string `json:"mimeType,omitempty"`
		} `json:"content"`
		IsError bool `json:"isError,omitempty"`
	}
	if err := json.Unmarshal(screenshotResp.Result, &screenshotResult); err != nil {
		t.Fatalf("Failed to parse screenshot result: %v", err)
	}

	// Content must be present
	if len(screenshotResult.Content) == 0 {
		t.Error("Screenshot content array is empty")
	}

	if screenshotResult.IsError {
		// Soft error is acceptable (permissions issue)
		t.Log("Step 5: Screenshot returned soft error (permissions not available)")
	} else {
		foundImage := false
		for _, c := range screenshotResult.Content {
			if c.Type == "image" && c.Data != "" {
				foundImage = true
				t.Logf("Step 5: Screenshot captured (%d bytes base64, mime=%s)", len(c.Data), c.MimeType)
			}
		}
		if !foundImage {
			t.Error("Step 5: No image in screenshot response (not a soft error)")
		}
	}

	t.Log("Full workflow completed successfully")
}

// TestStdioTransport_InvalidMethod verifies that unknown methods return
// a proper JSON-RPC error.
func TestStdioTransport_InvalidMethod(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Initialize first
	initReq := validMCPInitializeRequest(1)
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send unknown method
	unknownReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "unknown/method",
		"params":  map[string]any{},
	}

	response, err := sendStdioRequest(ctx, stdin, stdout, unknownReq)
	if err != nil {
		t.Fatalf("Failed to send request: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected error for unknown method, got success")
	}

	// Method not found error code is -32601
	if response.Error.Code != -32601 {
		t.Errorf("Error code = %d, want -32601 (Method not found)", response.Error.Code)
	}

	t.Logf("Unknown method correctly returned error: code=%d, message=%s", response.Error.Code, response.Error.Message)
}

func TestStdioTransport_KnownNotificationDoesNotReturnResponse(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	initialize := validMCPInitializeRequest(1)
	if _, err := sendStdioRequest(ctx, stdin, stdout, initialize); err != nil {
		t.Fatalf("initialize failed: %v", err)
	}

	notification := map[string]any{
		"jsonrpc": "2.0",
		"method":  "tools/list",
		"params":  map[string]any{},
	}
	if err := writeStdioMessage(stdin, notification); err != nil {
		t.Fatalf("send known notification: %v", err)
	}

	readCtx, cancelRead := context.WithTimeout(ctx, 3*time.Second)
	defer cancelRead()
	response, err := readStdioResponse(readCtx, stdout)
	if err == nil {
		t.Fatalf("known notification returned a response: %+v", response)
	}
	if readCtx.Err() != context.DeadlineExceeded {
		t.Fatalf("known notification read failed before silence deadline: %v", err)
	}
}

func TestStdioTransport_MalformedFrameRecovers(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	initialize := validMCPInitializeRequest(1)
	if _, err := sendStdioRequest(ctx, stdin, stdout, initialize); err != nil {
		t.Fatalf("initialize failed: %v", err)
	}

	if _, err := io.WriteString(stdin, "{malformed-json\n"); err != nil {
		t.Fatalf("write malformed stdio frame: %v", err)
	}
	parseCtx, cancelParse := context.WithTimeout(ctx, 5*time.Second)
	defer cancelParse()
	parseResponse, err := readStdioResponse(parseCtx, stdout)
	if err != nil {
		t.Fatalf("malformed frame returned no JSON-RPC parse error: %v", err)
	}
	if parseResponse.Error == nil || parseResponse.Error.Code != -32700 {
		t.Fatalf("malformed frame response=%+v, want parse error -32700", parseResponse)
	}
	if string(parseResponse.ID) != "null" {
		t.Fatalf("malformed frame response id=%q, want null", parseResponse.ID)
	}

	ping := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "ping",
	}
	pingResponse, err := sendStdioRequest(ctx, stdin, stdout, ping)
	if err != nil {
		t.Fatalf("valid request after malformed frame failed: %v", err)
	}
	if pingResponse.Error != nil || string(pingResponse.ID) != "2" || string(pingResponse.Result) != "{}" {
		t.Fatalf("valid request after malformed frame returned %+v", pingResponse)
	}
}

func TestStdioTransport_InvalidRequestsAndNullIDRecover(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	initialize := validMCPInitializeRequest(1)
	if _, err := sendStdioRequest(ctx, stdin, stdout, initialize); err != nil {
		t.Fatalf("initialize failed: %v", err)
	}

	invalidRequests := []struct {
		name    string
		payload string
	}{
		{name: "wrong JSON-RPC version", payload: `{"jsonrpc":"1.0","id":2,"method":"ping"}`},
		{name: "non-string method", payload: `{"jsonrpc":"2.0","id":2,"method":1}`},
		{name: "scalar params", payload: `{"jsonrpc":"2.0","id":2,"method":"ping","params":"bad"}`},
		{name: "boolean ID", payload: `{"jsonrpc":"2.0","id":true,"method":"ping"}`},
		{name: "empty object", payload: `{}`},
	}
	for _, test := range invalidRequests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := io.WriteString(stdin, test.payload+"\n"); err != nil {
				t.Fatalf("write invalid stdio request: %v", err)
			}
			readCtx, cancelRead := context.WithTimeout(ctx, 5*time.Second)
			defer cancelRead()
			response, err := readStdioResponse(readCtx, stdout)
			if err != nil {
				t.Fatalf("invalid stdio request returned no response: %v", err)
			}
			if response.JSONRPC != "2.0" || response.Error == nil || response.Error.Code != -32600 {
				t.Fatalf("invalid stdio response=%+v, want -32600", response)
			}
			if string(response.ID) != "null" {
				t.Fatalf("invalid stdio response id=%q, want null", response.ID)
			}
		})
	}

	if _, err := io.WriteString(stdin, `{"jsonrpc":"2.0","id":null,"method":"ping"}`+"\n"); err != nil {
		t.Fatalf("write null-ID stdio request: %v", err)
	}
	nullIDResponse, err := readStdioResponse(ctx, stdout)
	if err != nil {
		t.Fatalf("explicit null-ID stdio request returned no response: %v", err)
	}
	if nullIDResponse.Error == nil || nullIDResponse.Error.Code != -32600 || string(nullIDResponse.ID) != "null" {
		t.Fatalf("explicit null-ID stdio request returned %+v, want invalid request", nullIDResponse)
	}

	if _, err := io.WriteString(stdin, `{"jsonrpc":"2.0","id":null,"method":"unknown/method"}`+"\n"); err != nil {
		t.Fatalf("write unknown null-ID stdio request: %v", err)
	}
	unknownCtx, cancelUnknown := context.WithTimeout(ctx, time.Second)
	defer cancelUnknown()
	unknownResponse, err := readStdioResponse(unknownCtx, stdout)
	if err != nil {
		t.Fatalf("unknown null-ID stdio request returned no response: %v", err)
	}
	if unknownResponse.Error == nil || unknownResponse.Error.Code != -32600 || string(unknownResponse.ID) != "null" {
		t.Fatalf("unknown null-ID stdio request returned %+v, want invalid request before dispatch", unknownResponse)
	}

	ping := map[string]any{"jsonrpc": "2.0", "id": 9, "method": "ping"}
	pingResponse, err := sendStdioRequest(ctx, stdin, stdout, ping)
	if err != nil {
		t.Fatalf("valid request after invalid requests failed: %v", err)
	}
	if pingResponse.Error != nil || string(pingResponse.ID) != "9" || string(pingResponse.Result) != "{}" {
		t.Fatalf("valid request after invalid requests returned %+v", pingResponse)
	}
}

func TestStdioTransport_ConcurrentAndLongSession(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	initialize := validMCPInitializeRequest(1)
	if _, err := sendStdioRequest(ctx, stdin, stdout, initialize); err != nil {
		t.Fatalf("initialize failed: %v", err)
	}

	// Pipeline enough requests to force concurrent dispatcher goroutines. Stdio
	// responses may arrive in any order, so correlate every unique request ID.
	const pipelinedRequests = 256
	wantIDs := make(map[string]struct{}, pipelinedRequests)
	for index := range pipelinedRequests {
		id := 1000 + index
		wantIDs[fmt.Sprint(id)] = struct{}{}
		if err := writeStdioMessage(stdin, map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"method":  "ping",
		}); err != nil {
			t.Fatalf("write pipelined request %d: %v", id, err)
		}
	}
	readCtx, cancelRead := context.WithTimeout(ctx, 15*time.Second)
	defer cancelRead()
	for range pipelinedRequests {
		response, err := readStdioResponse(readCtx, stdout)
		if err != nil {
			t.Fatalf("read pipelined response: %v", err)
		}
		id := string(response.ID)
		if _, ok := wantIDs[id]; !ok {
			t.Fatalf("unexpected or duplicate pipelined response ID %q", id)
		}
		delete(wantIDs, id)
		if response.JSONRPC != "2.0" || response.Error != nil || string(response.Result) != "{}" {
			t.Fatalf("pipelined response for %s = %+v", id, response)
		}
	}
	if len(wantIDs) != 0 {
		t.Fatalf("missing %d pipelined responses", len(wantIDs))
	}

	toolsResponse, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      9999,
		"method":  "tools/list",
		"params":  map[string]any{},
	})
	if err != nil {
		t.Fatalf("tools/list after pipelined session failed: %v", err)
	}
	if toolsResponse.Error != nil || string(toolsResponse.ID) != "9999" || len(toolsResponse.Result) == 0 {
		t.Fatalf("tools/list after pipelined session returned %+v", toolsResponse)
	}
}

func TestStdioResponsePumpTimeoutKeepsOneOwnedReaderAndJoinsAtEOF(t *testing.T) {
	t.Parallel()

	reader, writer := io.Pipe()
	pump := newStdioResponsePump(bufio.NewReader(reader))

	timeoutCtx, cancelTimeout := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancelTimeout()
	if response, err := pump.read(timeoutCtx); !errors.Is(err, context.DeadlineExceeded) || response != nil {
		t.Fatalf("timed read response=%+v error=%v, want deadline exceeded", response, err)
	}
	select {
	case <-pump.done:
		t.Fatal("response reader exited on caller timeout instead of remaining singly owned")
	default:
	}

	writeDone := make(chan error, 1)
	go func() {
		_, writeErr := io.WriteString(
			writer,
			`{"jsonrpc":"2.0","id":73,"result":{}}`+"\n",
		)
		if writeErr == nil {
			writeErr = writer.Close()
		}
		writeDone <- writeErr
	}()

	readCtx, cancelRead := context.WithTimeout(context.Background(), time.Second)
	defer cancelRead()
	response, err := pump.read(readCtx)
	if err != nil || response == nil || string(response.ID) != "73" ||
		response.Error != nil || string(response.Result) != "{}" {
		t.Fatalf("post-timeout response=%+v error=%v", response, err)
	}
	if err := <-writeDone; err != nil {
		t.Fatalf("write response and EOF: %v", err)
	}
	select {
	case <-pump.done:
	case <-readCtx.Done():
		t.Fatalf("response reader did not join after EOF: %v", readCtx.Err())
	}
}

// TestStdioTransport_InvalidTool verifies that calling a non-existent tool
// returns a proper error.
func TestStdioTransport_InvalidTool(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start the gRPC server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Start MCP binary in stdio mode
	_, stdin, stdout, cleanup := startMCPStdioProcess(t, ctx, serverAddr)
	defer cleanup()

	// Initialize first
	initReq := validMCPInitializeRequest(1)
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Call non-existent tool
	callReq := map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "nonexistent_tool",
			"arguments": map[string]any{},
		},
	}

	response, err := sendStdioRequest(ctx, stdin, stdout, callReq)
	if err != nil {
		t.Fatalf("Failed to send request: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected error for nonexistent tool, got success")
	}

	// Method not found error code is -32601
	if response.Error.Code != -32601 {
		t.Errorf("Error code = %d, want -32601 (Method not found)", response.Error.Code)
	}

	t.Logf("Invalid tool correctly returned error: code=%d, message=%s", response.Error.Code, response.Error.Message)
}
