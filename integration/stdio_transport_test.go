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
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params": map[string]interface{}{
			"protocolVersion": "2025-11-25",
			"capabilities":    map[string]interface{}{},
			"clientInfo": map[string]interface{}{
				"name":    "test-client",
				"version": "1.0.0",
			},
		},
	}

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
			Tools map[string]interface{} `json:"tools"`
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
// tools including capture_screenshot.
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]interface{}{},
	}
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send tools/list request
	toolsReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/list",
		"params":  map[string]interface{}{},
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
			Name        string                 `json:"name"`
			Description string                 `json:"description"`
			InputSchema map[string]interface{} `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(response.Result, &toolsResult); err != nil {
		t.Fatalf("Failed to unmarshal tools result: %v", err)
	}

	if len(toolsResult.Tools) == 0 {
		t.Fatal("tools/list returned empty tools list")
	}

	// Verify capture_screenshot is present
	foundScreenshot := false
	foundClick := false
	foundTypeText := false
	for _, tool := range toolsResult.Tools {
		switch tool.Name {
		case "capture_screenshot":
			foundScreenshot = true
			if tool.Description == "" {
				t.Error("capture_screenshot has empty description")
			}
		case "click":
			foundClick = true
		case "type_text":
			foundTypeText = true
		}
	}

	if !foundScreenshot {
		t.Error("capture_screenshot tool not found in tools/list")
	}
	if !foundClick {
		t.Error("click tool not found in tools/list")
	}
	if !foundTypeText {
		t.Error("type_text tool not found in tools/list")
	}

	t.Logf("tools/list returned %d tools", len(toolsResult.Tools))
}

// TestStdioTransport_CaptureScreenshot verifies that capture_screenshot tool
// can be invoked via stdio transport and returns either image data or a
// structured soft error (is_error=true) when permissions are not available.
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]interface{}{},
	}
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send tools/call for capture_screenshot
	callReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name": "capture_screenshot",
			"arguments": map[string]interface{}{
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
		IsError bool `json:"is_error,omitempty"`
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
		t.Error("No image content in capture_screenshot response")
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params": map[string]interface{}{
			"protocolVersion": "2025-11-25",
			"clientInfo": map[string]interface{}{
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
	notifyReq := map[string]interface{}{
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
	toolsReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/list",
		"params":  map[string]interface{}{},
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

	// Step 4: tools/call - list_displays (lightweight operation)
	t.Log("Step 4: Sending tools/call for list_displays...")
	displayReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name":      "list_displays",
			"arguments": map[string]interface{}{},
		},
	}
	displayResp, err := sendStdioRequest(ctx, stdin, stdout, displayReq)
	if err != nil {
		t.Fatalf("list_displays failed: %v", err)
	}
	if displayResp.Error != nil {
		t.Fatalf("list_displays error: %s", displayResp.Error.Message)
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
		t.Error("list_displays returned empty content")
	} else {
		// The first content item should contain display info as text
		for _, c := range displayResult.Content {
			if c.Type == "text" && c.Text != "" {
				t.Logf("Step 4: Display info received (%d chars)", len(c.Text))
				break
			}
		}
	}

	// Step 5: tools/call - capture_screenshot
	t.Log("Step 5: Sending tools/call for capture_screenshot...")
	screenshotReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      4,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name": "capture_screenshot",
			"arguments": map[string]interface{}{
				"format": "jpeg",
			},
		},
	}
	screenshotResp, err := sendStdioRequest(ctx, stdin, stdout, screenshotReq)
	if err != nil {
		t.Fatalf("capture_screenshot failed: %v", err)
	}
	if screenshotResp.Error != nil {
		t.Fatalf("capture_screenshot JSON-RPC error: %s", screenshotResp.Error.Message)
	}

	var screenshotResult struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text,omitempty"`
			Data     string `json:"data,omitempty"`
			MimeType string `json:"mimeType,omitempty"`
		} `json:"content"`
		IsError bool `json:"is_error,omitempty"`
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]interface{}{},
	}
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Send unknown method
	unknownReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "unknown/method",
		"params":  map[string]interface{}{},
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
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]interface{}{},
	}
	_, err := sendStdioRequest(ctx, stdin, stdout, initReq)
	if err != nil {
		t.Fatalf("Initialize failed: %v", err)
	}

	// Call non-existent tool
	callReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/call",
		"params": map[string]interface{}{
			"name":      "nonexistent_tool",
			"arguments": map[string]interface{}{},
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

// --- Helper types and functions ---

// stdioResponse represents a JSON-RPC 2.0 response
type stdioResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data,omitempty"`
	} `json:"error,omitempty"`
}

// startMCPStdioProcess starts the macos-use-mcp binary in stdio mode.
// Returns the command, stdin writer, stdout reader, and cleanup function.
func startMCPStdioProcess(t *testing.T, ctx context.Context, grpcAddr string) (*exec.Cmd, io.WriteCloser, *bufio.Reader, func()) {
	t.Helper()

	// Build the MCP binary path
	mcpBinaryPath := "../cmd/macos-use-mcp"

	// Check if binary exists, if not try to find built binary
	builtBinary := "../.build/debug/macos-use-mcp"
	if _, err := os.Stat(builtBinary); err == nil {
		mcpBinaryPath = builtBinary
	} else {
		// Try go run approach
		mcpBinaryPath = "go"
	}

	var cmd *exec.Cmd
	if mcpBinaryPath == "go" {
		cmd = exec.CommandContext(ctx, "go", "run", "../cmd/macos-use-mcp")
	} else {
		cmd = exec.CommandContext(ctx, mcpBinaryPath)
	}

	// Configure environment for stdio transport
	cmd.Env = append(os.Environ(),
		"MCP_TRANSPORT=stdio",
		fmt.Sprintf("MACOS_USE_SERVER_ADDR=%s", grpcAddr),
		"MACOS_USE_DEBUG=false",
	)

	// Set up pipes
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("Failed to create stdin pipe: %v", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("Failed to create stdout pipe: %v", err)
	}

	// Capture stderr for debugging
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		t.Fatalf("Failed to create stderr pipe: %v", err)
	}

	// Start the process
	t.Log("Starting MCP process in stdio mode...")
	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start MCP process: %v", err)
	}
	t.Logf("MCP process started (PID: %d)", cmd.Process.Pid)

	// Read stderr in background for debugging
	var stderrMu sync.Mutex
	var stderrBuf strings.Builder
	go func() {
		scanner := bufio.NewScanner(stderrPipe)
		for scanner.Scan() {
			stderrMu.Lock()
			stderrBuf.WriteString(scanner.Text())
			stderrBuf.WriteString("\n")
			stderrMu.Unlock()
		}
	}()

	reader := bufio.NewReader(stdout)

	cleanup := func() {
		t.Log("Cleaning up MCP process...")

		// Close stdin to signal EOF
		stdin.Close()

		// Wait for process to exit with timeout
		done := make(chan error, 1)
		go func() {
			done <- cmd.Wait()
		}()

		select {
		case err := <-done:
			if err != nil {
				// Log stderr if process failed
				stderrMu.Lock()
				stderr := stderrBuf.String()
				stderrMu.Unlock()
				if stderr != "" {
					t.Logf("MCP process stderr:\n%s", stderr)
				}
			}
			t.Logf("MCP process exited: %v", err)
		case <-time.After(5 * time.Second):
			t.Log("MCP process did not exit, killing...")
			cmd.Process.Kill()
			<-done
		}
	}

	// Wait a moment for the process to be ready
	// Use polling rather than time.Sleep
	readyCtx, readyCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readyCancel()

	err = PollUntilContext(readyCtx, 50*time.Millisecond, func() (bool, error) {
		// Just check that the process is still running
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			return false, fmt.Errorf("MCP process exited unexpectedly")
		}
		return true, nil
	})
	if err != nil {
		cleanup()
		t.Fatalf("MCP process failed to become ready: %v", err)
	}

	return cmd, stdin, reader, cleanup
}

// writeStdioMessage writes a JSON-RPC message to stdin
func writeStdioMessage(stdin io.Writer, msg map[string]interface{}) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}

	// Write message followed by newline
	if _, err := stdin.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}

	return nil
}

// readStdioResponse reads a JSON-RPC response from stdout with timeout
func readStdioResponse(ctx context.Context, reader *bufio.Reader) (*stdioResponse, error) {
	// Use a channel to handle the blocking read with context
	type readResult struct {
		line string
		err  error
	}

	resultCh := make(chan readResult, 1)
	go func() {
		line, err := reader.ReadString('\n')
		resultCh <- readResult{line, err}
	}()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case result := <-resultCh:
		if result.err != nil {
			return nil, fmt.Errorf("failed to read response: %w", result.err)
		}

		line := strings.TrimSpace(result.line)
		if line == "" {
			return nil, fmt.Errorf("empty response received")
		}

		var resp stdioResponse
		if err := json.Unmarshal([]byte(line), &resp); err != nil {
			return nil, fmt.Errorf("failed to parse response: %w (line: %s)", err, line)
		}

		return &resp, nil
	}
}

// sendStdioRequest sends a JSON-RPC request and waits for the response
func sendStdioRequest(ctx context.Context, stdin io.Writer, stdout *bufio.Reader, req map[string]interface{}) (*stdioResponse, error) {
	// Create a timeout context for this request
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	// Write the request
	if err := writeStdioMessage(stdin, req); err != nil {
		return nil, err
	}

	// Read the response
	return readStdioResponse(reqCtx, stdout)
}
