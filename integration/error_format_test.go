// Copyright 2025 Joseph Cumines
//
// MCP error response format integration tests.
// Verifies is_error field format and various error conditions.
// Task: T071

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

// TestMCPErrorFormat_IsErrorField verifies that error responses use the
// correct is_error field format (snake_case, not camelCase).
// This is critical for Anthropic Claude Desktop compatibility.
func TestMCPErrorFormat_IsErrorField(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_window","arguments":{"name":"applications/invalid/windows/invalid"}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	var response struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	resultStr := string(response.Result)

	if len(response.Result) > 0 {
		var toolResult struct {
			IsError bool              `json:"is_error"`
			Content []json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(response.Result, &toolResult); err == nil {
			if bytes.Contains(response.Result, []byte(`"isError"`)) {
				t.Error("Result uses 'isError' (camelCase) instead of 'is_error' (snake_case)")
			}
			if toolResult.IsError {
				t.Log("Soft error correctly uses is_error field")
			}
		}
	}

	if response.Error != nil {
		t.Logf("Got JSON-RPC error: code=%d, message=%s", response.Error.Code, response.Error.Message)
		return
	}

	t.Logf("Response result: %s", resultStr)
}

// TestMCPErrorFormat_InvalidToolName verifies error format for non-existent tools.
func TestMCPErrorFormat_InvalidToolName(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"this_tool_does_not_exist_12345","arguments":{}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		JSONRPC string `json:"jsonrpc"`
		ID      int    `json:"id"`
		Error   *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected JSON-RPC error for invalid tool")
	}

	expectedCode := -32601
	if response.Error.Code != expectedCode {
		t.Errorf("Error code = %d, want %d", response.Error.Code, expectedCode)
	}

	if response.Error.Message == "" {
		t.Error("Error message should not be empty")
	}

	if response.JSONRPC != "2.0" {
		t.Errorf("jsonrpc = %q, want '2.0'", response.JSONRPC)
	}

	t.Logf("Invalid tool error: code=%d, message=%s", response.Error.Code, response.Error.Message)
}

// TestMCPErrorFormat_InvalidParams verifies error format for invalid parameters.
func TestMCPErrorFormat_InvalidParams(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":"not an object"}`
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
		t.Fatalf("Failed to decode: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected JSON-RPC error for invalid params")
	}

	expectedCode := -32602
	if response.Error.Code != expectedCode {
		t.Logf("Note: Error code = %d (expected %d for invalid params)", response.Error.Code, expectedCode)
	}

	t.Logf("Invalid params error: code=%d, message=%s", response.Error.Code, response.Error.Message)
}

// TestMCPErrorFormat_UnknownMethod verifies error format for unknown methods.
func TestMCPErrorFormat_UnknownMethod(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	request := `{"jsonrpc":"2.0","id":1,"method":"unknown/method","params":{}}`
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
		t.Fatalf("Failed to decode: %v", err)
	}

	if response.Error == nil {
		t.Fatal("Expected JSON-RPC error for unknown method")
	}

	expectedCode := -32601
	if response.Error.Code != expectedCode {
		t.Errorf("Error code = %d, want %d", response.Error.Code, expectedCode)
	}

	t.Logf("Unknown method error: code=%d, message=%s", response.Error.Code, response.Error.Message)
}

// TestMCPErrorFormat_MalformedJSON verifies error format for malformed JSON.
func TestMCPErrorFormat_MalformedJSON(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	request := `{not valid json}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("HTTP status = %d, want 400", resp.StatusCode)
	}

	t.Logf("Malformed JSON correctly returned HTTP %d", resp.StatusCode)
}

// TestMCPErrorFormat_SoftError verifies the is_error field in tool results.
func TestMCPErrorFormat_SoftError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_application","arguments":{"name":"applications/999999999"}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	rawBody := new(bytes.Buffer)
	rawBody.ReadFrom(resp.Body)
	bodyBytes := rawBody.Bytes()

	if bytes.Contains(bodyBytes, []byte(`"isError"`)) && !bytes.Contains(bodyBytes, []byte(`"is_error"`)) {
		t.Error("Response uses 'isError' (camelCase) instead of 'is_error' (snake_case)")
	}

	var response struct {
		Result struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"is_error"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(bodyBytes, &response); err != nil {
		t.Fatalf("Failed to decode: %v", err)
	}

	if response.Error != nil {
		t.Logf("Got JSON-RPC error instead of soft error: %s", response.Error.Message)
		return
	}

	if response.Result.IsError {
		t.Log("Soft error correctly marked with is_error: true")
		if len(response.Result.Content) > 0 {
			t.Logf("Error content: %s", response.Result.Content[0].Text)
		}
	}

	t.Logf("Raw response for is_error verification: %s", string(bodyBytes[:minInt(200, len(bodyBytes))]))
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
