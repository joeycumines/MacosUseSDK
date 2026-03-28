// Copyright 2025 Joseph Cumines
//
// HTTP/SSE transport integration tests

package integration

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// startHTTPTransport starts an HTTP transport for testing and returns
// the transport, the base URL, and cleanup function.
func startHTTPTransport(t *testing.T, ctx context.Context, handler func(*transport.Message) (*transport.Message, error)) (*transport.HTTPTransport, string, func()) {
	t.Helper()

	// Find an available port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to find available port: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	config := &transport.HTTPTransportConfig{
		Address:           addr,
		CORSOrigin:        "*",
		HeartbeatInterval: 1 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0,
	}

	tr := transport.NewHTTPTransport(config)

	serverErrCh := make(chan error, 1)
	go func() {
		serverErrCh <- tr.Serve(handler)
	}()

	baseURL := fmt.Sprintf("http://%s", addr)

	err = PollUntilContext(ctx, 50*time.Millisecond, func() (bool, error) {
		resp, err := http.Get(baseURL + "/health")
		if err != nil {
			return false, nil
		}
		resp.Body.Close()
		return resp.StatusCode == http.StatusOK, nil
	})
	if err != nil {
		tr.Close()
		t.Fatalf("HTTP transport failed to become ready: %v", err)
	}

	cleanup := func() {
		tr.Close()
		select {
		case <-serverErrCh:
		case <-time.After(1 * time.Second):
		}
	}

	return tr, baseURL, cleanup
}

// echoHandler echoes the request method in the result.
func echoHandler(msg *transport.Message) (*transport.Message, error) {
	return &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Result:  json.RawMessage(`{"echo":"ok","method":"` + msg.Method + `"}`),
	}, nil
}

// TestHTTPTransport_HealthEndpoint verifies GET /health returns 200 OK.
func TestHTTPTransport_HealthEndpoint(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Get(baseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /health status = %d, want 200", resp.StatusCode)
	}

	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "application/json") {
		t.Errorf("Content-Type = %s, want application/json", contentType)
	}

	var health map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Fatalf("Failed to decode health response: %v", err)
	}

	if health["status"] != "ok" {
		t.Errorf("health.status = %v, want 'ok'", health["status"])
	}
	if _, ok := health["clients"]; !ok {
		t.Error("health response missing 'clients' field")
	}
	if _, ok := health["server_time"]; !ok {
		t.Error("health response missing 'server_time' field")
	}
}

// TestHTTPTransport_HealthEndpoint_MethodNotAllowed verifies POST to /health returns 405.
func TestHTTPTransport_HealthEndpoint_MethodNotAllowed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Post(baseURL+"/health", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /health failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST /health status = %d, want 405", resp.StatusCode)
	}
}

// TestHTTPTransport_MessageEndpoint verifies POST /message handles JSON-RPC.
func TestHTTPTransport_MessageEndpoint(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	reqBody := `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(reqBody))
	if err != nil {
		t.Fatalf("POST /message failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /message status = %d, want 200. Body: %s", resp.StatusCode, body)
	}

	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "application/json") {
		t.Errorf("Content-Type = %s, want application/json", contentType)
	}

	var msg transport.Message
	if err := json.NewDecoder(resp.Body).Decode(&msg); err != nil {
		t.Fatalf("Failed to decode response: %v", err)
	}

	if msg.JSONRPC != "2.0" {
		t.Errorf("response.jsonrpc = %s, want 2.0", msg.JSONRPC)
	}
	if msg.Error != nil {
		t.Errorf("response has unexpected error: %v", msg.Error)
	}
	if msg.Result == nil {
		t.Error("response.result is nil")
	}

	var result map[string]any
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("Failed to unmarshal result: %v", err)
	}
	if result["method"] != "tools/list" {
		t.Errorf("result.method = %v, want tools/list", result["method"])
	}
}

// TestHTTPTransport_MessageEndpoint_InvalidJSON verifies POST /message with bad JSON returns 400.
func TestHTTPTransport_MessageEndpoint_InvalidJSON(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString("{invalid json}"))
	if err != nil {
		t.Fatalf("POST /message failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("POST /message with invalid JSON status = %d, want 400", resp.StatusCode)
	}
}

// TestHTTPTransport_MessageEndpoint_MethodNotAllowed verifies GET to /message returns 405.
func TestHTTPTransport_MessageEndpoint_MethodNotAllowed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Get(baseURL + "/message")
	if err != nil {
		t.Fatalf("GET /message failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET /message status = %d, want 405", resp.StatusCode)
	}
}

// TestHTTPTransport_SSEConnection verifies the SSE endpoint accepts connections.
func TestHTTPTransport_SSEConnection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/events", nil)
	if err != nil {
		t.Fatalf("Failed to create SSE request: %v", err)
	}

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET /events failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /events status = %d, want 200", resp.StatusCode)
	}

	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "text/event-stream") {
		t.Errorf("Content-Type = %s, want text/event-stream", contentType)
	}

	cacheControl := resp.Header.Get("Cache-Control")
	if !strings.Contains(cacheControl, "no-cache") {
		t.Errorf("Cache-Control = %s, want no-cache", cacheControl)
	}

	reader := bufio.NewReader(resp.Body)
	readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
	defer readCancel()

	receivedHeartbeat := false
	lineCh := make(chan string, 10)
	errCh := make(chan error, 1)

	go func() {
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				errCh <- err
				return
			}
			lineCh <- line
		}
	}()

	for {
		select {
		case <-readCtx.Done():
			if !receivedHeartbeat {
				t.Error("Did not receive heartbeat within timeout")
			}
			return
		case err := <-errCh:
			if err != io.EOF && !receivedHeartbeat {
				t.Errorf("SSE read error: %v", err)
			}
			return
		case line := <-lineCh:
			if strings.HasPrefix(line, ": heartbeat") {
				receivedHeartbeat = true
				return
			}
		}
	}
}

// TestHTTPTransport_SSEConnection_MethodNotAllowed verifies POST to /events returns 405.
func TestHTTPTransport_SSEConnection_MethodNotAllowed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Post(baseURL+"/events", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /events failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST /events status = %d, want 405", resp.StatusCode)
	}
}

// TestHTTPTransport_SSEBroadcast verifies messages are broadcast to SSE clients.
func TestHTTPTransport_SSEBroadcast(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tr, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	sseReq, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/events", nil)
	if err != nil {
		t.Fatalf("Failed to create SSE request: %v", err)
	}

	sseClient := &http.Client{}
	sseResp, err := sseClient.Do(sseReq)
	if err != nil {
		t.Fatalf("GET /events failed: %v", err)
	}
	defer sseResp.Body.Close()

	err = PollUntilContext(ctx, 50*time.Millisecond, func() (bool, error) {
		resp, err := http.Get(baseURL + "/health")
		if err != nil {
			return false, nil
		}
		defer resp.Body.Close()

		var health map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
			return false, nil
		}
		clients, ok := health["clients"].(float64)
		return ok && clients >= 1, nil
	})
	if err != nil {
		t.Fatalf("SSE client count never reached 1: %v", err)
	}

	eventCh := make(chan string, 10)
	go func() {
		reader := bufio.NewReader(sseResp.Body)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			eventCh <- line
		}
	}()

	testMsg := &transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`99`),
		Result:  json.RawMessage(`{"broadcast":"test"}`),
	}
	if err := tr.WriteMessage(testMsg); err != nil {
		t.Fatalf("WriteMessage failed: %v", err)
	}

	receivedBroadcast := false
	broadcastCtx, broadcastCancel := context.WithTimeout(ctx, 5*time.Second)
	defer broadcastCancel()

	for {
		select {
		case <-broadcastCtx.Done():
			if !receivedBroadcast {
				t.Error("Did not receive broadcast event")
			}
			return
		case line := <-eventCh:
			if strings.Contains(line, "broadcast") && strings.Contains(line, "test") {
				receivedBroadcast = true
				return
			}
		}
	}
}

// TestHTTPTransport_CORSHeaders verifies CORS headers are set correctly.
func TestHTTPTransport_CORSHeaders(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	resp, err := http.Get(baseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health failed: %v", err)
	}
	resp.Body.Close()

	corsOrigin := resp.Header.Get("Access-Control-Allow-Origin")
	if corsOrigin != "*" {
		t.Errorf("Access-Control-Allow-Origin = %s, want '*'", corsOrigin)
	}

	corsMethods := resp.Header.Get("Access-Control-Allow-Methods")
	if !strings.Contains(corsMethods, "GET") || !strings.Contains(corsMethods, "POST") {
		t.Errorf("Access-Control-Allow-Methods = %s, want GET, POST, OPTIONS", corsMethods)
	}

	corsHeaders := resp.Header.Get("Access-Control-Allow-Headers")
	if !strings.Contains(corsHeaders, "Content-Type") {
		t.Errorf("Access-Control-Allow-Headers = %s, want Content-Type", corsHeaders)
	}
}

// TestHTTPTransport_CORSPreflight verifies OPTIONS requests are handled for CORS.
func TestHTTPTransport_CORSPreflight(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	req, err := http.NewRequestWithContext(ctx, "OPTIONS", baseURL+"/message", nil)
	if err != nil {
		t.Fatalf("Failed to create OPTIONS request: %v", err)
	}
	req.Header.Set("Origin", "https://example.com")
	req.Header.Set("Access-Control-Request-Method", "POST")
	req.Header.Set("Access-Control-Request-Headers", "Content-Type")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("OPTIONS /message failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("OPTIONS /message status = %d, want 204", resp.StatusCode)
	}

	corsOrigin := resp.Header.Get("Access-Control-Allow-Origin")
	if corsOrigin != "*" {
		t.Errorf("Access-Control-Allow-Origin = %s, want '*'", corsOrigin)
	}

	corsMethods := resp.Header.Get("Access-Control-Allow-Methods")
	if !strings.Contains(corsMethods, "POST") {
		t.Errorf("Access-Control-Allow-Methods = %s, want to contain POST", corsMethods)
	}
}

// TestHTTPTransport_GracefulShutdown verifies transport shuts down gracefully.
func TestHTTPTransport_GracefulShutdown(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	tr, baseURL, _ := startHTTPTransport(t, ctx, echoHandler)

	sseReq, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/events", nil)
	if err != nil {
		t.Fatalf("Failed to create SSE request: %v", err)
	}

	sseClient := &http.Client{}
	sseResp, err := sseClient.Do(sseReq)
	if err != nil {
		t.Fatalf("GET /events failed: %v", err)
	}
	defer sseResp.Body.Close()

	doneCh := make(chan struct{})
	go func() {
		reader := bufio.NewReader(sseResp.Body)
		for {
			_, err := reader.ReadString('\n')
			if err != nil {
				close(doneCh)
				return
			}
		}
	}()

	err = PollUntilContext(ctx, 50*time.Millisecond, func() (bool, error) {
		resp, err := http.Get(baseURL + "/health")
		if err != nil {
			return false, nil
		}
		defer resp.Body.Close()

		var health map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
			return false, nil
		}
		clients, ok := health["clients"].(float64)
		return ok && clients >= 1, nil
	})
	if err != nil {
		t.Fatalf("SSE client not established: %v", err)
	}

	if err := tr.Close(); err != nil {
		t.Errorf("Close() error = %v", err)
	}

	if !tr.IsClosed() {
		t.Error("Transport should be closed after Close()")
	}

	select {
	case <-doneCh:
		// SSE connection closed as expected
	case <-time.After(3 * time.Second):
		t.Error("SSE connection did not close within timeout")
	}
}

// TestHTTPTransport_SSELastEventID verifies Last-Event-ID header is accepted for reconnection.
// This test verifies that the SSE endpoint accepts the Last-Event-ID header which is used
// for clients to resume receiving events after a disconnect.
func TestHTTPTransport_SSELastEventID(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tr, baseURL, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	// First, broadcast some messages to populate the event store
	for i := range 3 {
		testMsg := &transport.Message{
			JSONRPC: "2.0",
			ID:      json.RawMessage(fmt.Sprintf(`%d`, i+1)),
			Result:  json.RawMessage(fmt.Sprintf(`{"event_num":%d}`, i+1)),
		}
		if err := tr.WriteMessage(testMsg); err != nil {
			t.Fatalf("WriteMessage failed: %v", err)
		}
	}

	// Connect with Last-Event-ID header set to "1" to request events after ID 1
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/events", nil)
	if err != nil {
		t.Fatalf("Failed to create SSE request: %v", err)
	}
	req.Header.Set("Last-Event-ID", "1")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET /events with Last-Event-ID failed: %v", err)
	}
	defer resp.Body.Close()

	// Verify the connection is accepted
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /events status = %d, want 200", resp.StatusCode)
	}

	// Verify content type is SSE
	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "text/event-stream") {
		t.Errorf("Content-Type = %s, want text/event-stream", contentType)
	}

	// Read some data to ensure the connection is functional
	reader := bufio.NewReader(resp.Body)
	readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
	defer readCancel()

	receivedData := false
	lineCh := make(chan string, 10)
	errCh := make(chan error, 1)

	go func() {
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				errCh <- err
				return
			}
			lineCh <- line
		}
	}()

	// Wait for any data (heartbeat or replayed events)
	for {
		select {
		case <-readCtx.Done():
			if !receivedData {
				t.Error("Did not receive any data from SSE after reconnect")
			}
			return
		case err := <-errCh:
			if err != io.EOF {
				t.Errorf("SSE read error: %v", err)
			}
			return
		case line := <-lineCh:
			// Any data received indicates the connection is working
			if len(strings.TrimSpace(line)) > 0 || strings.HasPrefix(line, ":") {
				receivedData = true
				return
			}
		}
	}
}
