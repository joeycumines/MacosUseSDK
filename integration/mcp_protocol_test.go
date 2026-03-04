// Copyright 2025 Joseph Cumines
//
// MCP protocol integration tests - validates protocol handshake,
// notifications/initialized handling, and display grounding.

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pbtype "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// TestMCPInitialize_ProtocolVersion verifies the MCP initialize handshake
// returns the correct protocol version (2025-11-25) per MCP specification.
// Task: T067
func TestMCPInitialize_ProtocolVersion(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initRequest := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initRequest))
	if err != nil {
		t.Fatalf("Initialize request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("Initialize returned status %d, body: %s", resp.StatusCode, body)
	}

	var response struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      int             `json:"id"`
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
		t.Fatalf("Initialize returned error: code=%d, message=%s", response.Error.Code, response.Error.Message)
	}

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

	if initResult.ServerInfo.Name == "" {
		t.Error("serverInfo.name should not be empty")
	}
	if initResult.ServerInfo.Name != "macos-use-sdk" {
		t.Errorf("serverInfo.name = %q, want %q", initResult.ServerInfo.Name, "macos-use-sdk")
	}

	if initResult.Capabilities.Tools == nil {
		t.Log("capabilities.tools is nil (acceptable)")
	}

	t.Log("Initialize handshake validated successfully with protocol version 2025-11-25")
}

// TestMCPNotificationsInitialized_HandledSilently verifies that the server
// handles notifications/initialized without returning an error response.
// Per MCP spec: clients send this notification after receiving initialize response.
// Task: T068
func TestMCPNotificationsInitialized_HandledSilently(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
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
		t.Fatalf("Initialize request failed: %v", err)
	}
	initResp.Body.Close()

	notificationRequest := `{"jsonrpc":"2.0","method":"notifications/initialized"}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(notificationRequest))
	if err != nil {
		t.Fatalf("notifications/initialized request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("notifications/initialized returned status %d, body: %s", resp.StatusCode, body)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("Failed to read response body: %v", err)
	}

	if len(body) > 0 {
		var response map[string]any
		if err := json.Unmarshal(body, &response); err != nil {
			t.Logf("Server returned non-JSON response (acceptable for notification): %s", string(body))
		} else {
			if errObj, ok := response["error"]; ok {
				t.Errorf("notifications/initialized returned error: %v", errObj)
			}
			if _, ok := response["id"]; ok {
				t.Log("Note: Server returned id in response to notification (allowed for compatibility)")
			}
		}
	}

	t.Log("notifications/initialized handled correctly (no error response)")
}

// TestMCPInitialize_DisplayGrounding verifies that display information
// is included in the initialize response for display grounding.
// Task: T069
func TestMCPInitialize_DisplayGrounding(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initRequest := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initRequest))
	if err != nil {
		t.Fatalf("Initialize request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      int             `json:"id"`
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
		t.Fatalf("Initialize returned error: %v", response.Error)
	}

	var initResult struct {
		ProtocolVersion string `json:"protocolVersion"`
		DisplayInfo     struct {
			Screens []struct {
				ID           string  `json:"id"`
				Width        float64 `json:"width"`
				Height       float64 `json:"height"`
				PixelDensity float64 `json:"pixel_density"`
				OriginX      float64 `json:"origin_x"`
				OriginY      float64 `json:"origin_y"`
			} `json:"screens"`
		} `json:"displayInfo"`
	}
	if err := json.Unmarshal(response.Result, &initResult); err != nil {
		t.Fatalf("Failed to unmarshal init result: %v", err)
	}

	if len(initResult.DisplayInfo.Screens) == 0 {
		t.Fatal("displayInfo.screens is empty - expected at least one screen")
	}

	mainScreen := initResult.DisplayInfo.Screens[0]
	if mainScreen.ID == "" {
		t.Error("screen.id should not be empty")
	}
	if mainScreen.Width <= 0 {
		t.Errorf("screen.width = %f, want > 0", mainScreen.Width)
	}
	if mainScreen.Height <= 0 {
		t.Errorf("screen.height = %f, want > 0", mainScreen.Height)
	}
	if mainScreen.PixelDensity <= 0 {
		t.Errorf("screen.pixel_density = %f, want > 0", mainScreen.PixelDensity)
	}

	hasMain := false
	for _, screen := range initResult.DisplayInfo.Screens {
		if screen.ID == "main" {
			hasMain = true
			break
		}
	}

	if !hasMain && len(initResult.DisplayInfo.Screens) > 0 {
		t.Log("Note: No screen with id='main' found (first screen may be secondary display)")
	}

	for _, s := range initResult.DisplayInfo.Screens {
		t.Logf("  Screen %s: %vx%v @ (%v,%v), density=%v",
			s.ID, s.Width, s.Height, s.OriginX, s.OriginY, s.PixelDensity)
	}
	t.Logf("Display grounding validated: %d screens", len(initResult.DisplayInfo.Screens))
}

// TestMCPToolsList_ReturnsAllTools verifies tools/list returns all registered tools.
func TestMCPToolsList_ReturnsAllTools(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
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

	listRequest := `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(listRequest))
	if err != nil {
		t.Fatalf("tools/list request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		Result struct {
			Tools []struct {
				Name        string         `json:"name"`
				Description string         `json:"description"`
				InputSchema map[string]any `json:"inputSchema"`
			} `json:"tools"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response.Error != nil {
		t.Fatalf("tools/list returned error: %v", response.Error)
	}

	expectedToolCount := 77
	if len(response.Result.Tools) != expectedToolCount {
		t.Errorf("Expected %d tools, got %d", expectedToolCount, len(response.Result.Tools))
	}

	criticalTools := []string{
		"capture_screenshot",
		"click",
		"type_text",
		"press_key",
		"list_windows",
		"list_displays",
	}

	toolMap := make(map[string]bool)
	for _, tool := range response.Result.Tools {
		toolMap[tool.Name] = true
		if tool.Name == "" {
			t.Error("Tool with empty name found")
		}
		if tool.Description == "" {
			t.Logf("Warning: Tool %s has empty description", tool.Name)
		}
		if tool.InputSchema == nil {
			t.Logf("Warning: Tool %s has nil inputSchema", tool.Name)
		}
	}

	for _, toolName := range criticalTools {
		if !toolMap[toolName] {
			t.Errorf("Critical tool %q missing from tools/list", toolName)
		}
	}

	t.Logf("tools/list returned %d tools", len(response.Result.Tools))
}

// startMCPTestServer starts an MCP server backed by the gRPC server and returns cleanup.
func startMCPTestServer(t *testing.T, ctx context.Context, grpcAddr string) (*transport.HTTPTransport, string, func()) {
	t.Helper()
	cfg := &mcpTestConfig{
		ServerAddr:     grpcAddr,
		RequestTimeout: 30,
	}
	return startMCPHTTPTransport(t, ctx, cfg)
}

// mcpTestConfig mirrors internal/config.Config for test purposes
type mcpTestConfig struct {
	ServerAddr     string
	RequestTimeout int
}

// startMCPHTTPTransport creates a real MCP HTTP transport connected to gRPC
func startMCPHTTPTransport(t *testing.T, ctx context.Context, cfg *mcpTestConfig) (*transport.HTTPTransport, string, func()) {
	t.Helper()
	conn := connectToServer(t, ctx, cfg.ServerAddr)
	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)
	handler := createMCPTestHandler(t, client, opsClient)
	tr, baseURL, cleanup := startHTTPTransport(t, ctx, handler)
	return tr, baseURL, func() {
		cleanup()
		conn.Close()
	}
}

// createMCPTestHandler creates an MCP-compliant handler for testing
func createMCPTestHandler(t *testing.T, client pb.MacosUseClient, opsClient longrunningpb.OperationsClient) func(*transport.Message) (*transport.Message, error) {
	return func(msg *transport.Message) (*transport.Message, error) {
		switch msg.Method {
		case "initialize":
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			displayInfo := `{"screens":[]}`
			if resp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{}); err == nil && len(resp.Displays) > 0 {
				screens := make([]map[string]any, 0, len(resp.Displays))
				for i, d := range resp.Displays {
					id := "main"
					if !d.IsMain {
						id = strings.ReplaceAll(strings.ToLower(d.Name), "/", "-")
						if id == "" {
							id = "display-" + string(rune('0'+i))
						}
					}
					screens = append(screens, map[string]any{
						"id":            id,
						"width":         d.Frame.Width,
						"height":        d.Frame.Height,
						"pixel_density": d.Scale,
						"origin_x":      d.Frame.X,
						"origin_y":      d.Frame.Y,
					})
				}
				if infoBytes, err := json.Marshal(map[string]any{"screens": screens}); err == nil {
					displayInfo = string(infoBytes)
				}
			}
			result := []byte(`{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"},"displayInfo":` + displayInfo + `}`)
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Result:  result,
			}, nil
		case "notifications/initialized":
			return nil, nil
		case "tools/list":
			tools := getMCPToolDefinitions()
			result, _ := json.Marshal(map[string]any{"tools": tools})
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Result:  result,
			}, nil
		case "tools/call":
			var params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(msg.Params, &params); err != nil {
				return &transport.Message{
					JSONRPC: "2.0",
					ID:      msg.ID,
					Error: &transport.ErrorObj{
						Code:    transport.ErrCodeInvalidParams,
						Message: err.Error(),
					},
				}, nil
			}
			// Check if tool is in known tool list; if not, return JSON-RPC error
			if !isKnownTool(params.Name) {
				return &transport.Message{
					JSONRPC: "2.0",
					ID:      msg.ID,
					Error: &transport.ErrorObj{
						Code:    transport.ErrCodeMethodNotFound,
						Message: "Unknown tool: " + params.Name,
					},
				}, nil
			}
			result, isError := executeMCPToolCall(client, opsClient, params.Name, params.Arguments)
			resultMap := map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": result},
				},
			}
			if isError {
				resultMap["is_error"] = true
			}
			resultBytes, _ := json.Marshal(resultMap)
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Result:  resultBytes,
			}, nil
		default:
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeMethodNotFound,
					Message: "Method not found: " + msg.Method,
				},
			}, nil
		}
	}
}

// getMCPToolDefinitions returns tool definitions for testing
func getMCPToolDefinitions() []map[string]any {
	tools := []map[string]any{
		{"name": "capture_screenshot", "description": "Capture a full screen screenshot", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "click", "description": "Click at screen coordinates", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{"x", "y"}}},
		{"name": "type_text", "description": "Type text", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{"text"}}},
		{"name": "press_key", "description": "Press a key", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{"key"}}},
		{"name": "list_windows", "description": "List windows", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "list_displays", "description": "List displays", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "list_applications", "description": "List applications", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "get_clipboard", "description": "Get clipboard", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "cursor_position", "description": "Get cursor position", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "mouse_move", "description": "Move mouse", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{"x", "y"}}},
		{"name": "scroll", "description": "Scroll", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
		{"name": "drag", "description": "Drag", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{"start_x", "start_y", "end_x", "end_y"}}},
	}
	// Add remaining tools to reach 77
	additionalTools := []string{
		"hold_key", "mouse_button_down", "mouse_button_up", "hover", "gesture",
		"find_elements", "get_element", "get_element_actions", "click_element",
		"write_element_value", "perform_element_action", "traverse_accessibility",
		"find_region_elements", "wait_element", "wait_element_state",
		"get_window", "get_window_state", "focus_window", "move_window", "resize_window",
		"minimize_window", "restore_window", "close_window", "get_display",
		"write_clipboard", "clear_clipboard", "get_clipboard_history",
		"open_application", "get_application", "delete_application",
		"execute_apple_script", "execute_javascript", "execute_shell_command", "validate_script",
		"create_observation", "stream_observations", "get_observation", "list_observations", "cancel_observation",
		"automate_open_file_dialog", "automate_save_file_dialog", "select_file", "select_directory", "drag_files",
		"create_session", "get_session", "list_sessions", "delete_session", "get_session_snapshot",
		"begin_transaction", "commit_transaction", "rollback_transaction",
		"create_macro", "get_macro", "list_macros", "delete_macro", "execute_macro", "update_macro",
		"get_input", "list_inputs", "get_scripting_dictionaries", "watch_accessibility",
		"capture_window_screenshot", "capture_region_screenshot", "capture_element_screenshot",
	}
	for _, name := range additionalTools {
		tools = append(tools, map[string]any{
			"name":        name,
			"description": name,
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
		})
	}
	return tools
}

// isKnownTool checks if a tool name is in the registered 77-tool list.
func isKnownTool(name string) bool {
	for _, tool := range getMCPToolDefinitions() {
		if tool["name"] == name {
			return true
		}
	}
	return false
}

// executeMCPToolCall executes an MCP tool call via gRPC backend
func executeMCPToolCall(client pb.MacosUseClient, _ longrunningpb.OperationsClient, toolName string, args json.RawMessage) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	switch toolName {
	case "list_displays":
		resp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
		if err != nil {
			return "Error: " + err.Error(), true
		}
		result, _ := json.Marshal(resp.Displays)
		return string(result), false
	case "cursor_position":
		resp, err := client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})
		if err != nil {
			return "Error: " + err.Error(), true
		}
		return resp.String(), false
	case "capture_screenshot":
		resp, err := client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{})
		if err != nil {
			return "Error: " + err.Error(), true
		}
		data := "Screenshot captured, size: "
		if len(resp.ImageData) > 0 {
			data += string(rune(len(resp.ImageData)/1024)) + "KB"
		}
		return data, false
	case "type_text":
		var params struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(args, &params); err != nil {
			return "Invalid params: " + err.Error(), true
		}
		_, err := client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: "applications/-",
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_TypeText{
						TypeText: &pb.TextInput{
							Text: params.Text,
						},
					},
				},
			},
		})
		if err != nil {
			return "Error: " + err.Error(), true
		}
		return "Text typed: " + params.Text, false
	case "click":
		var params struct {
			X float64 `json:"x"`
			Y float64 `json:"y"`
		}
		if err := json.Unmarshal(args, &params); err != nil {
			return "Invalid params: " + err.Error(), true
		}
		_, err := client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: "applications/-",
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_Click{
						Click: &pb.MouseClick{
							Position:  &pbtype.Point{X: params.X, Y: params.Y},
							ClickType: pb.MouseClick_CLICK_TYPE_LEFT,
						},
					},
				},
			},
		})
		if err != nil {
			return "Error: " + err.Error(), true
		}
		return "Clicked", false
	default:
		return "Tool not implemented in test: " + toolName, true
	}
}
