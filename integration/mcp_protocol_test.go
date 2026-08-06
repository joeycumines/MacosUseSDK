// Copyright 2025 Joseph Cumines

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
)

func TestMCPInitialize_ProtocolVersion(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	response := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if response.Error != nil {
		t.Fatalf("initialize returned error: code=%d message=%s", response.Error.Code, response.Error.Message)
	}

	var result struct {
		ProtocolVersion string `json:"protocolVersion"`
		Capabilities    struct {
			Tools map[string]any `json:"tools"`
		} `json:"capabilities"`
		ServerInfo struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
		DisplayInfo json.RawMessage `json:"displayInfo"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode initialize result: %v", err)
	}
	if result.ProtocolVersion != "2025-11-25" {
		t.Fatalf("protocolVersion = %q, want 2025-11-25", result.ProtocolVersion)
	}
	if result.ServerInfo.Name != "macos-use-sdk" || result.ServerInfo.Version == "" {
		t.Fatalf("unexpected serverInfo: name=%q version=%q", result.ServerInfo.Name, result.ServerInfo.Version)
	}
	if result.Capabilities.Tools == nil {
		t.Fatal("initialize omitted tools capability")
	}
	if len(result.DisplayInfo) == 0 || string(result.DisplayInfo) == "null" {
		t.Fatal("initialize omitted production display grounding")
	}
}

func TestMCPInitialize_InvalidParams(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	for index, payload := range []string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":[]}`,
		`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":42,"capabilities":{},"clientInfo":{"name":"test","version":"1"}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}`,
	} {
		response := postMCPRequest(t, baseURL, payload)
		if response.Error == nil || response.Error.Code != -32602 {
			t.Fatalf("invalid initialize case %d response=%+v, want -32602", index, response)
		}
		if string(response.ID) != fmt.Sprint(index+1) || len(response.Result) != 0 {
			t.Fatalf("invalid initialize case %d response=%+v, want correlated error only", index, response)
		}
	}

	recovered := postMCPRequest(t, baseURL, validMCPInitializePayload(4))
	if recovered.Error != nil || len(recovered.Result) == 0 || string(recovered.ID) != "4" {
		t.Fatalf("valid initialize after invalid inputs returned %+v", recovered)
	}
}

func TestMCPNotificationsInitialized_HandledSilently(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}

	request, err := newProductionMCPRequest(
		ctx,
		http.MethodPost,
		baseURL,
		bytes.NewBufferString(`{"jsonrpc":"2.0","method":"notifications/initialized"}`),
	)
	if err != nil {
		t.Fatalf("create initialized notification: %v", err)
	}
	applyDefaultMCPSession(request, baseURL)
	resp, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("send initialized notification: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("initialized notification status=%d body=%q, want 202", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read initialized notification response: %v", err)
	}
	if len(body) != 0 {
		t.Fatalf("initialized notification returned a body: %q", body)
	}
}

func TestMCPKnownNotification_HandledSilently(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}

	request, err := newProductionMCPRequest(
		ctx,
		http.MethodPost,
		baseURL,
		bytes.NewBufferString(`{"jsonrpc":"2.0","method":"tools/list","params":{}}`),
	)
	if err != nil {
		t.Fatalf("create known notification: %v", err)
	}
	applyDefaultMCPSession(request, baseURL)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("send known notification: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read known notification response: %v", err)
	}
	if response.StatusCode != http.StatusAccepted || len(body) != 0 {
		t.Fatalf("known notification status=%d body=%q, want 202 with no body", response.StatusCode, body)
	}
}

func TestMCPMalformedRequestsAndNullID_HTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}

	tests := []struct {
		name     string
		payload  string
		wantCode int
	}{
		{name: "invalid JSON", payload: `{malformed-json`, wantCode: -32700},
		{name: "trailing JSON", payload: `{"jsonrpc":"2.0","id":2,"method":"ping"} trailing`, wantCode: -32700},
		{name: "empty object", payload: `{}`, wantCode: -32600},
		{name: "wrong JSON-RPC version", payload: `{"jsonrpc":"1.0","id":2,"method":"ping"}`, wantCode: -32600},
		{name: "non-string method", payload: `{"jsonrpc":"2.0","id":2,"method":1}`, wantCode: -32600},
		{name: "scalar params", payload: `{"jsonrpc":"2.0","id":2,"method":"ping","params":"bad"}`, wantCode: -32600},
		{name: "boolean ID", payload: `{"jsonrpc":"2.0","id":true,"method":"ping"}`, wantCode: -32600},
		{name: "null ID", payload: `{"jsonrpc":"2.0","id":null,"method":"ping"}`, wantCode: -32600},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request, err := newProductionMCPRequest(
				ctx,
				http.MethodPost,
				baseURL,
				bytes.NewBufferString(test.payload),
			)
			if err != nil {
				t.Fatalf("create malformed MCP request: %v", err)
			}
			applyDefaultMCPSession(request, baseURL)
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatalf("send malformed MCP request: %v", err)
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusBadRequest {
				body, _ := io.ReadAll(response.Body)
				t.Fatalf("malformed MCP status=%d body=%q, want 400", response.StatusCode, body)
			}
			if contentType := response.Header.Get("Content-Type"); !strings.Contains(contentType, "application/json") {
				t.Fatalf("malformed MCP content type=%q, want application/json", contentType)
			}
			var decoded mcpResponse
			if err := json.NewDecoder(response.Body).Decode(&decoded); err != nil {
				t.Fatalf("decode malformed MCP response: %v", err)
			}
			if decoded.JSONRPC != "2.0" || decoded.Error == nil || decoded.Error.Code != test.wantCode {
				t.Fatalf("malformed MCP response=%+v, want JSON-RPC error %d", decoded, test.wantCode)
			}
			if string(decoded.ID) != "null" {
				t.Fatalf("malformed MCP response id=%q, want null", decoded.ID)
			}
		})
	}

	following := postMCPRequest(t, baseURL, `{"jsonrpc":"2.0","id":9,"method":"ping"}`)
	if following.Error != nil || string(following.ID) != "9" || string(following.Result) != "{}" {
		t.Fatalf("valid request after malformed inputs returned %+v", following)
	}
}

func TestMCPConcurrentAndLongSession_HTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}
	baseline := postMCPRequest(t, baseURL, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	if baseline.Error != nil || len(baseline.Result) == 0 {
		t.Fatalf("baseline tools/list response = %+v", baseline)
	}

	type requestResult struct {
		response mcpResponse
		err      error
		id       int
		tools    bool
	}
	const concurrentRequests = 64
	results := make(chan requestResult, concurrentRequests)
	for index := range concurrentRequests {
		id := 1000 + index
		tools := index%2 == 0
		method := "ping"
		if tools {
			method = "tools/list"
		}
		go func() {
			payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":%q,"params":{}}`, id, method)
			response, err := requestMCPHTTP(ctx, baseURL, payload)
			results <- requestResult{response: response, err: err, id: id, tools: tools}
		}()
	}
	for range concurrentRequests {
		result := <-results
		if result.err != nil {
			t.Fatalf("concurrent request %d failed: %v", result.id, result.err)
		}
		if result.response.JSONRPC != "2.0" || result.response.Error != nil || string(result.response.ID) != fmt.Sprint(result.id) {
			t.Fatalf("concurrent response for %d = %+v", result.id, result.response)
		}
		if result.tools {
			if !bytes.Equal(result.response.Result, baseline.Result) {
				t.Fatalf("concurrent tools/list result drifted for request %d", result.id)
			}
		} else if string(result.response.Result) != "{}" {
			t.Fatalf("concurrent ping result for %d = %q", result.id, result.response.Result)
		}
	}

	const longSessionRequests = 256
	for index := range longSessionRequests {
		id := 2000 + index
		method := "ping"
		wantResult := json.RawMessage(`{}`)
		if index%32 == 0 {
			method = "tools/list"
			wantResult = baseline.Result
		}
		payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":%q,"params":{}}`, id, method)
		response, err := requestMCPHTTP(ctx, baseURL, payload)
		if err != nil {
			t.Fatalf("long-session request %d failed: %v", id, err)
		}
		if response.Error != nil || string(response.ID) != fmt.Sprint(id) || !bytes.Equal(response.Result, wantResult) {
			t.Fatalf("long-session response for %d = %+v", id, response)
		}
	}

	final := postMCPRequest(t, baseURL, `{"jsonrpc":"2.0","id":9999,"method":"tools/list","params":{}}`)
	if final.Error != nil || !bytes.Equal(final.Result, baseline.Result) {
		t.Fatalf("final tools/list response drifted after long session: %+v", final)
	}
}

func TestMCPRequestCancellation_HTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	client := &http.Client{Timeout: 15 * time.Second}
	sessionID := initializeHTTPSession(t, ctx, client, baseURL, 1)
	requestResult := make(chan sessionHTTPResult, 1)
	go func() {
		requestResult <- sendSessionMCP(
			t,
			ctx,
			client,
			baseURL,
			http.MethodPost,
			sessionID,
			`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wait","arguments":{"duration":10}}}`,
		)
	}()
	cancelled := cancelSessionRequestUntilDone(t, ctx, client, baseURL, sessionID, 2, requestResult)
	if cancelled.Status != http.StatusNoContent || len(cancelled.Body) != 0 {
		t.Fatalf("cancelled MCP request status=%d body=%q, want 204 empty", cancelled.Status, cancelled.Body)
	}

	final := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, `{"jsonrpc":"2.0","id":3,"method":"ping"}`)
	var finalResponse mcpResponse
	if final.Err != nil || final.Status != http.StatusOK || json.Unmarshal(final.Body, &finalResponse) != nil ||
		finalResponse.Error != nil || string(finalResponse.ID) != "3" || string(finalResponse.Result) != "{}" {
		t.Fatalf("ping after cancellation status=%d response=%+v body=%q error=%v", final.Status, finalResponse, final.Body, final.Err)
	}
}

func TestMCPInitialize_DisplayGrounding(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	response := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if response.Error != nil {
		t.Fatalf("initialize returned error: %+v", response.Error)
	}
	var result struct {
		DisplayInfo struct {
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
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode initialize display grounding: %v", err)
	}
	if len(result.DisplayInfo.Screens) == 0 {
		t.Fatal("displayInfo.screens is empty")
	}
	for _, screen := range result.DisplayInfo.Screens {
		if screen.ID == "" || screen.Width <= 0 || screen.Height <= 0 || screen.PixelDensity <= 0 {
			t.Fatalf(
				"invalid grounded screen: id=%q size=%vx%v density=%v origin=(%v,%v)",
				screen.ID,
				screen.Width,
				screen.Height,
				screen.PixelDensity,
				screen.OriginX,
				screen.OriginY,
			)
		}
	}
}

func TestMCPToolsList_ReturnsProductionRegistry(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}
	response := postMCPRequest(t, baseURL, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	if response.Error != nil {
		t.Fatalf("tools/list returned error: %+v", response.Error)
	}

	var result struct {
		Tools []struct {
			Name        string         `json:"name"`
			Description string         `json:"description"`
			InputSchema map[string]any `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode tools/list result: %v", err)
	}
	if len(result.Tools) == 0 {
		t.Fatal("production tools/list returned no tools")
	}
	seen := make(map[string]struct{}, len(result.Tools))
	for _, tool := range result.Tools {
		if tool.Name == "" || tool.Description == "" || tool.InputSchema == nil {
			t.Fatalf("invalid production tool metadata: name=%q description=%q schema=%v", tool.Name, tool.Description, tool.InputSchema)
		}
		if _, duplicate := seen[tool.Name]; duplicate {
			t.Fatalf("production tools/list returned duplicate tool %q", tool.Name)
		}
		seen[tool.Name] = struct{}{}
	}
	if _, ok := seen["drag"]; !ok {
		t.Fatal("production tools/list omitted drag")
	}
}

type mcpResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func postMCPRequest(t *testing.T, baseURL, payload string) mcpResponse {
	t.Helper()
	resp, err := postProductionMCP(t.Context(), baseURL, bytes.NewBufferString(payload))
	if err != nil {
		t.Fatalf("send MCP request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("MCP request status=%d body=%q", resp.StatusCode, body)
	}
	var response mcpResponse
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("decode MCP response: %v", err)
	}
	if response.JSONRPC != "2.0" {
		t.Fatalf("jsonrpc=%q, want 2.0", response.JSONRPC)
	}
	return response
}

func requestMCPHTTP(ctx context.Context, baseURL, payload string) (mcpResponse, error) {
	response, err := postProductionMCP(ctx, baseURL, bytes.NewBufferString(payload))
	if err != nil {
		return mcpResponse{}, fmt.Errorf("send request: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		return mcpResponse{}, fmt.Errorf("status=%d body=%q", response.StatusCode, body)
	}
	var decoded mcpResponse
	if err := json.NewDecoder(response.Body).Decode(&decoded); err != nil {
		return mcpResponse{}, fmt.Errorf("decode response: %w", err)
	}
	return decoded, nil
}
