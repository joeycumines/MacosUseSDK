// Copyright 2025 Joseph Cumines
//
// MCP tools integration tests - validates tool invocation via HTTP transport.
// Task: T066

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

	requireMCPInitialize(t, baseURL)

	tests := []struct {
		name      string
		tool      string
		args      string
		wantError bool
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
			args:      `{"format": "png", "ocr": false}`,
			wantError: false,
		},
		{
			name:      "list_apps returns tracked application state",
			tool:      "list_apps",
			args:      `{}`,
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

			resp, err := postProductionMCP(ctx, baseURL, bytes.NewBuffer(reqBytes))
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
				t.Fatalf("Tool returned soft error for a valid read-only call: %s", toolResult.Content[0].Text)
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

	initReq := validMCPInitializePayload(1)
	initResp, _ := postProductionMCP(ctx, baseURL, bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"format":"png","ocr":false}}}`
	resp, err := postProductionMCP(ctx, baseURL, bytes.NewBufferString(request))
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

// TestMCPTools_ClickElement_CalculatorStateDelta proves that the production
// HTTP MCP process resolves an exact owned Calculator element, performs its AX
// action through gRPC/Swift, and reports success only when the display changes.
func TestMCPTools_ClickElement_CalculatorStateDelta(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)
	restoreClipboard := preserveClipboard(t, ctx, client)
	defer restoreClipboard()

	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator window did not become available: %v", err)
	}

	switchCalculatorToBasicMode(t, ctx, client, app)
	requireCalculatorButtonText(t, ctx, client, app, "7")

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()
	requireMCPInitialize(t, baseURL)

	before := requireCalculatorCopiedResult(t, ctx, client, app, "0")

	// Click the "7" button by its exact parent-bound element handle. A bare
	// text:7 selector is too broad here: macOS Calculator exposes more than one
	// AX node whose text is "7" (the digit button plus an accessibility label),
	// so selector rediscovery fails with "Selector matched multiple elements".
	// Resolving the button element first (role contains "button" AND exact text
	// "7") and clicking that handle is deterministic and mode-independent.
	button7 := requireCalculatorButtonHandle(t, ctx, client, app, "7")
	callProductionMCPTool(t, baseURL, 2, "click_element", map[string]any{
		"parent":  app.Name,
		"element": button7,
	})
	after := requireCalculatorCopiedResult(t, ctx, client, app, "7")
	if before == after {
		t.Fatalf("MCP click_element reported success without a Calculator state delta: %q", after)
	}
}

// requireCalculatorButtonHandle resolves the opaque element handle of a
// Calculator button whose role contains "button" and whose trimmed text equals
// label. It returns the bare element_id (the opaque segment after the parent),
// which is the form click_element's element parameter expects: the server
// rebuilds the full resource name as parent + "/elements/" + element.
func requireCalculatorButtonHandle(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	app *pb.Application,
	label string,
) string {
	t.Helper()
	resolveCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var handle string
	err := PollUntilContext(resolveCtx, 100*time.Millisecond, func() (bool, error) {
		response, traverseErr := client.TraverseAccessibility(resolveCtx, &pb.TraverseAccessibilityRequest{Name: app.Name})
		if traverseErr != nil {
			return false, nil
		}
		for _, element := range response.GetElements() {
			if element == nil || !strings.Contains(strings.ToLower(element.GetRole()), "button") {
				continue
			}
			if strings.TrimSpace(element.GetText()) == label && element.GetElementId() != "" {
				handle = element.GetElementId()
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Calculator button %q element handle did not resolve: %v", label, err)
	}
	return handle
}

// TestMCPTools_CloseApp_CalculatorObservedLifecycle proves that the compiled
// MCP process delegates application lifecycle ownership to the generated
// CloseApplication RPC and reports success only after both process and server
// state converge on the same owned Calculator resource.
func TestMCPTools_CloseApp_CalculatorObservedLifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()
	requireMCPInitialize(t, baseURL)

	result := callProductionMCPTool(t, baseURL, 2, "close_app", map[string]any{
		"app":   app.Name,
		"force": true,
	})
	text := result.Content[0].Text
	if !strings.Contains(text, "Application close observed:") ||
		!strings.Contains(text, app.Name) ||
		!strings.Contains(text, fmt.Sprintf("PID: %d", app.Pid)) ||
		(!strings.Contains(text, "Disposition: graceful") && !strings.Contains(text, "Disposition: forced")) {
		t.Fatalf("close_app result does not identify the observed Calculator close: %q", text)
	}

	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		_, getErr := client.GetApplication(ctx, &pb.GetApplicationRequest{Name: app.Name})
		if getErr != nil && status.Code(getErr) != codes.NotFound {
			return false, getErr
		}
		processGone, processErr := exactProcessGone(app.Pid)
		return status.Code(getErr) == codes.NotFound && processGone, processErr
	})
	if err != nil {
		t.Fatalf("close_app returned success before Calculator state converged: %v", err)
	}
}

// TestMCPTools_OpenApp_AllModesObserved proves that list_apps returns an exact
// installed bundle resource, open_app opens that resource, the returned exact
// running resource activates the same process, and force-new produces a
// genuinely distinct process identity.
func TestMCPTools_OpenApp_AllModesObserved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	var ownedApps []*pb.Application
	defer func() {
		for _, app := range ownedApps {
			cleanupApplication(t, ctx, client, app)
		}
	}()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()
	requireMCPInitialize(t, baseURL)

	bundle := DiscoverApplicationBundle(t, ctx, client, "com.apple.calculator")
	discovery := callProductionMCPTool(t, baseURL, 2, "list_apps", map[string]any{
		"kind":   "installed",
		"filter": `bundle_id = "com.apple.calculator"`,
		"full":   true,
	})
	discoveryText := discovery.Content[0].Text
	if !strings.Contains(discoveryText, bundle.Name) ||
		!strings.Contains(discoveryText, "com.apple.calculator") ||
		!strings.Contains(discoveryText, bundle.BundleUrl) {
		t.Fatalf("list_apps did not expose the exact Calculator bundle: %q", discoveryText)
	}

	launch := callProductionMCPTool(t, baseURL, 3, "open_app", map[string]any{
		"app":            bundle.Name,
		"mode":           "launch_or_activate",
		"bring_to_front": true,
	})
	launchText := launch.Content[0].Text
	if !strings.Contains(launchText, "Application open observed: Calculator") ||
		!strings.Contains(launchText, "Mode: launch_or_activate") ||
		!strings.Contains(launchText, "Disposition: launched new") {
		t.Fatalf("launch_or_activate result is not an observed new process: %q", launchText)
	}
	first := trackedApplicationsNamed(t, ctx, client, "Calculator")
	if len(first) != 1 {
		t.Fatalf("launch_or_activate tracked Calculator instances = %d, want 1", len(first))
	}
	ownedApps = append(ownedApps, first[0])

	activate := callProductionMCPTool(t, baseURL, 4, "open_app", map[string]any{
		"app":            first[0].Name,
		"bring_to_front": true,
	})
	activateText := activate.Content[0].Text
	if !strings.Contains(activateText, "Application activation observed: Calculator") ||
		(!strings.Contains(activateText, "Disposition: activated") &&
			!strings.Contains(activateText, "Disposition: already active")) {
		t.Fatalf("exact running-resource activation is not observed: %q", activateText)
	}
	afterActivate := trackedApplicationsNamed(t, ctx, client, "Calculator")
	if len(afterActivate) != 1 || afterActivate[0].Pid != first[0].Pid {
		t.Fatalf("exact activation changed process identity: before=%v after=%v", first, afterActivate)
	}

	force := callProductionMCPTool(t, baseURL, 5, "open_app", map[string]any{
		"app":            bundle.Name,
		"mode":           "force_new_instance",
		"bring_to_front": true,
	})
	forceText := force.Content[0].Text
	if !strings.Contains(forceText, "Mode: force_new_instance") ||
		!strings.Contains(forceText, "Disposition: launched new") {
		t.Fatalf("force_new_instance result is not an observed new process: %q", forceText)
	}
	afterForce := trackedApplicationsNamed(t, ctx, client, "Calculator")
	if len(afterForce) != 2 {
		t.Fatalf("force_new_instance tracked Calculator instances = %d, want 2: %v", len(afterForce), afterForce)
	}
	if afterForce[0].Pid == afterForce[1].Pid {
		t.Fatalf("force_new_instance reused PID %d", afterForce[0].Pid)
	}
	ownedApps = afterForce
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

	initReq := validMCPInitializePayload(1)
	initResp, _ := postProductionMCP(ctx, baseURL, bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nonexistent_tool","arguments":{}}}`
	resp, err := postProductionMCP(ctx, baseURL, bytes.NewBufferString(request))
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

	initReq := validMCPInitializePayload(1)
	initResp, _ := postProductionMCP(ctx, baseURL, bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click","arguments":{}}}`
	resp, err := postProductionMCP(ctx, baseURL, bytes.NewBufferString(request))
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

type productionMCPToolResult struct {
	Content []struct {
		Type     string `json:"type"`
		Text     string `json:"text,omitempty"`
		Data     string `json:"data,omitempty"`
		MimeType string `json:"mimeType,omitempty"`
	} `json:"content"`
	IsError bool `json:"isError"`
}

func requireMCPInitialize(t *testing.T, baseURL string) {
	t.Helper()
	response := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if response.Error != nil {
		t.Fatalf("production MCP initialize returned error: code=%d message=%s", response.Error.Code, response.Error.Message)
	}
	if len(response.Result) == 0 {
		t.Fatal("production MCP initialize returned an empty result")
	}
}

func callProductionMCPTool(t *testing.T, baseURL string, id int, name string, arguments map[string]any) productionMCPToolResult {
	t.Helper()
	request, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      name,
			"arguments": arguments,
		},
	})
	if err != nil {
		t.Fatalf("marshal %s MCP call: %v", name, err)
	}
	response := postMCPRequest(t, baseURL, string(request))
	if response.Error != nil {
		t.Fatalf("%s returned JSON-RPC error: code=%d message=%s", name, response.Error.Code, response.Error.Message)
	}
	var result productionMCPToolResult
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode %s MCP result: %v", name, err)
	}
	if result.IsError {
		message := "(no error text)"
		if len(result.Content) > 0 && result.Content[0].Text != "" {
			message = result.Content[0].Text
		}
		t.Fatalf("%s returned MCP soft error: %s", name, message)
	}
	if len(result.Content) == 0 {
		t.Fatalf("%s returned empty MCP content", name)
	}
	return result
}

func trackedApplicationsNamed(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	displayName string,
) []*pb.Application {
	t.Helper()
	response, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("list tracked applications: %v", err)
	}
	applications := make([]*pb.Application, 0, len(response.Applications))
	for _, app := range response.Applications {
		if app != nil && strings.EqualFold(app.DisplayName, displayName) {
			applications = append(applications, app)
		}
	}
	return applications
}

func requireCalculatorButtonText(t *testing.T, ctx context.Context, client pb.ExactMacClient, app *pb.Application, candidates ...string) string {
	t.Helper()
	buttonCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	wanted := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		wanted[candidate] = struct{}{}
	}
	var matched string
	err := PollUntilContext(buttonCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.TraverseAccessibility(buttonCtx, &pb.TraverseAccessibilityRequest{Name: app.Name})
		if err != nil {
			return false, nil
		}
		for _, element := range response.Elements {
			if element == nil || !strings.Contains(strings.ToLower(element.GetRole()), "button") {
				continue
			}
			if _, ok := wanted[strings.TrimSpace(element.GetText())]; ok {
				matched = strings.TrimSpace(element.GetText())
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Calculator button %v did not become visible: %v", candidates, err)
	}
	return matched
}

func preserveClipboard(t *testing.T, ctx context.Context, client pb.ExactMacClient) func() {
	t.Helper()
	original, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Fatalf("read clipboard before Calculator fixture: %v", err)
	}
	return func() {
		restoreCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if original.GetContent() == nil {
			if _, err := client.ClearClipboard(restoreCtx, &pb.ClearClipboardRequest{}); err != nil {
				t.Errorf("restore empty clipboard after Calculator fixture: %v", err)
			}
			return
		}
		if _, err := client.WriteClipboard(restoreCtx, &pb.WriteClipboardRequest{Content: original.GetContent()}); err != nil {
			t.Errorf("restore clipboard after Calculator fixture: %v", err)
		}
	}
}

func requireCalculatorCopiedResult(t *testing.T, ctx context.Context, client pb.ExactMacClient, app *pb.Application, expected string) string {
	t.Helper()
	sentinel := "EXACTMAC_CALCULATOR_COPY_SENTINEL_" + expected
	write, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content: &pb.ClipboardContent{
			Type:    pb.ContentType_CONTENT_TYPE_TEXT.Enum(),
			Content: &pb.ClipboardContent_Text{Text: sentinel},
		},
	})
	if err != nil {
		t.Fatalf("write Calculator copy sentinel: response=%+v error=%v", write, err)
	}
	observed := write.GetClipboard()
	if observed.GetName() != "clipboard" ||
		observed.GetContent().GetType() != pb.ContentType_CONTENT_TYPE_TEXT ||
		observed.GetContent().GetText() != sentinel {
		t.Fatalf("write Calculator copy sentinel returned non-observed clipboard: %+v", write)
	}
	createCompletedInput(
		t,
		ctx,
		client,
		newIntegrationInputRequest(
			t,
			app.GetName(),
			applicationInputTarget(app.GetName()),
			&pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "c",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		),
		2,
		"copy exact Calculator result",
	)

	copyCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var copied string
	err = PollUntilContext(copyCtx, 100*time.Millisecond, func() (bool, error) {
		clipboard, err := client.GetClipboard(copyCtx, &pb.GetClipboardRequest{Name: "clipboard"})
		if err != nil {
			return false, nil
		}
		copied = strings.TrimSpace(clipboard.GetContent().GetText())
		return copied != "" && copied != sentinel, nil
	})
	if err != nil {
		t.Fatalf("Calculator Cmd+C did not publish its display value: last=%q: %v", copied, err)
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(copied, ",", ""), "−", "-")
	if normalized != expected {
		t.Fatalf("Calculator copied result = %q, want %q", normalized, expected)
	}
	return normalized
}
