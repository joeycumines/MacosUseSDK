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

func TestMCPStreamableHTTP_ProductionLifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initializeStatus, initializeHeaders, initializeBody := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"production-test","version":"1"}}}`,
		"",
		"",
	)
	if initializeStatus != http.StatusOK {
		t.Fatalf("initialize status=%d body=%q, want 200", initializeStatus, initializeBody)
	}
	if contentType := initializeHeaders.Get("Content-Type"); contentType != "application/json" {
		t.Fatalf("initialize Content-Type=%q, want application/json", contentType)
	}
	sessionID := initializeHeaders.Get("MCP-Session-Id")
	if sessionID == "" {
		t.Fatal("production initialize omitted MCP-Session-Id")
	}
	var initializeResponse mcpResponse
	if err := json.Unmarshal(initializeBody, &initializeResponse); err != nil || initializeResponse.Error != nil {
		t.Fatalf("decode initialize response=%+v error=%v body=%q", initializeResponse, err, initializeBody)
	}

	notificationStatus, _, notificationBody := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		"2025-11-25",
		sessionID,
	)
	if notificationStatus != http.StatusAccepted || len(notificationBody) != 0 {
		t.Fatalf("initialized notification status=%d body=%q, want 202 and empty body", notificationStatus, notificationBody)
	}

	listStatus, _, listBody := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}`,
		"2025-11-25",
		sessionID,
	)
	if listStatus != http.StatusOK {
		t.Fatalf("tools/list status=%d body=%q, want 200", listStatus, listBody)
	}
	var listResponse mcpResponse
	if err := json.Unmarshal(listBody, &listResponse); err != nil || listResponse.Error != nil {
		t.Fatalf("decode tools/list response=%+v error=%v body=%q", listResponse, err, listBody)
	}

	unsupportedStatus, _, _ := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}`,
		"2099-01-01",
		sessionID,
	)
	if unsupportedStatus != http.StatusBadRequest {
		t.Fatalf("unsupported protocol version status=%d, want 400", unsupportedStatus)
	}

	getRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/mcp", nil)
	if err != nil {
		t.Fatalf("create Streamable HTTP GET: %v", err)
	}
	getRequest.Header.Set("Accept", "text/event-stream")
	getRequest.Header.Set("MCP-Session-Id", sessionID)
	getResponse, err := http.DefaultClient.Do(getRequest)
	if err != nil {
		t.Fatalf("send Streamable HTTP GET: %v", err)
	}
	getResponse.Body.Close()
	if getResponse.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET /mcp status=%d, want 405", getResponse.StatusCode)
	}

	for _, legacyPath := range []string{"/message", "/events"} {
		legacyRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+legacyPath, nil)
		if err != nil {
			t.Fatalf("create legacy endpoint request: %v", err)
		}
		legacyResponse, err := http.DefaultClient.Do(legacyRequest)
		if err != nil {
			t.Fatalf("request legacy endpoint %s: %v", legacyPath, err)
		}
		legacyResponse.Body.Close()
		if legacyResponse.StatusCode != http.StatusNotFound {
			t.Fatalf("legacy endpoint %s status=%d, want 404", legacyPath, legacyResponse.StatusCode)
		}
	}

	recoveryStatus, _, recoveryBody := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}`,
		"2025-11-25",
		sessionID,
	)
	if recoveryStatus != http.StatusOK {
		t.Fatalf("recovery ping status=%d body=%q, want 200", recoveryStatus, recoveryBody)
	}

	deleteRequest, err := http.NewRequestWithContext(ctx, http.MethodDelete, baseURL+"/mcp", nil)
	if err != nil {
		t.Fatalf("create Streamable HTTP DELETE: %v", err)
	}
	deleteRequest.Header.Set("MCP-Session-Id", sessionID)
	deleteResponse, err := http.DefaultClient.Do(deleteRequest)
	if err != nil {
		t.Fatalf("terminate Streamable HTTP session: %v", err)
	}
	deleteResponse.Body.Close()
	if deleteResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE /mcp status=%d, want 204", deleteResponse.StatusCode)
	}
	staleStatus, _, _ := sendProductionStreamableHTTP(
		t,
		ctx,
		baseURL,
		`{"jsonrpc":"2.0","id":4,"method":"ping","params":{}}`,
		"2025-11-25",
		sessionID,
	)
	if staleStatus != http.StatusNotFound {
		t.Fatalf("terminated session reuse status=%d, want 404", staleStatus)
	}
}

func sendProductionStreamableHTTP(
	t *testing.T,
	ctx context.Context,
	baseURL string,
	payload string,
	protocolVersion string,
	sessionID string,
) (int, http.Header, []byte) {
	t.Helper()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/mcp", bytes.NewBufferString(payload))
	if err != nil {
		t.Fatalf("create Streamable HTTP request: %v", err)
	}
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Content-Type", "application/json")
	if protocolVersion != "" {
		request.Header.Set("MCP-Protocol-Version", protocolVersion)
	}
	if sessionID != "" {
		request.Header.Set("MCP-Session-Id", sessionID)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("send Streamable HTTP request: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read Streamable HTTP response: %v", err)
	}
	return response.StatusCode, response.Header.Clone(), body
}
