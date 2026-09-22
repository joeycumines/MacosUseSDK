// Copyright 2025 Joseph Cumines

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/transport"
)

func startHTTPTransport(
	t *testing.T,
	ctx context.Context,
	handler func(*transport.Message) (*transport.Message, error),
) (*transport.HTTPTransport, string, string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve HTTP transport address: %v", err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatalf("release reserved HTTP transport address: %v", err)
	}

	tr := transport.NewHTTPTransport(&transport.HTTPTransportConfig{
		Address:      address,
		CORSOrigin:   "https://trusted.example",
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	})
	serverResult := make(chan error, 1)
	go func() { serverResult <- tr.Serve(handler) }()
	baseURL := "http://" + address

	readyCtx, cancelReady := context.WithTimeout(ctx, 5*time.Second)
	defer cancelReady()
	if err := PollUntilContext(readyCtx, 25*time.Millisecond, func() (bool, error) {
		response, err := http.Get(baseURL + "/health")
		if err != nil {
			return false, nil
		}
		_, drainErr := io.Copy(io.Discard, response.Body)
		closeErr := response.Body.Close()
		return response.StatusCode == http.StatusOK && drainErr == nil && closeErr == nil, nil
	}); err != nil {
		_ = tr.Close()
		t.Fatalf("HTTP transport did not become ready: %v", err)
	}

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			if err := tr.Close(); err != nil {
				t.Errorf("close HTTP transport: %v", err)
			}
			stoppedCtx, cancelStopped := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancelStopped()
			var serveErr error
			if err := PollUntilContext(stoppedCtx, 10*time.Millisecond, func() (bool, error) {
				select {
				case serveErr = <-serverResult:
					return true, nil
				default:
					return false, nil
				}
			}); err != nil {
				t.Errorf("HTTP transport serve loop did not stop: %v", err)
			} else if serveErr != nil {
				t.Errorf("HTTP transport serve error: %v", serveErr)
			}
		})
	}
	return tr, baseURL, address, cleanup
}

func echoHandler(message *transport.Message) (*transport.Message, error) {
	return &transport.Message{
		JSONRPC: "2.0",
		ID:      message.ID,
		Result:  json.RawMessage(`{"echo":"ok","method":"` + message.Method + `"}`),
	}, nil
}

func TestHTTPTransport_HealthEndpoint(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, baseURL, _, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	response, err := http.Get(baseURL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("GET /health status=%d, want 200", response.StatusCode)
	}
	if contentType := response.Header.Get("Content-Type"); !strings.Contains(contentType, "application/json") {
		t.Fatalf("GET /health Content-Type=%q, want application/json", contentType)
	}
	var health map[string]any
	if err := json.NewDecoder(response.Body).Decode(&health); err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	if health["status"] != "ok" || health["server_time"] == nil {
		t.Fatalf("health response=%v, want status and server_time", health)
	}

	post, err := http.Post(baseURL+"/health", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /health: %v", err)
	}
	post.Body.Close()
	if post.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST /health status=%d, want 405", post.StatusCode)
	}
}

func TestHTTPTransport_StreamableRequestAndRecovery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, baseURL, _, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()
	sessionID := initializeDirectStreamableHTTPSession(t, ctx, http.DefaultClient, baseURL)

	response := sendDirectStreamableHTTP(t, ctx, baseURL, sessionID, `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("POST /mcp status=%d body=%q, want 200", response.StatusCode, body)
	}
	var message transport.Message
	if err := json.NewDecoder(response.Body).Decode(&message); err != nil {
		t.Fatalf("decode /mcp response: %v", err)
	}
	if message.JSONRPC != "2.0" || string(message.ID) != "1" || message.Error != nil {
		t.Fatalf("unexpected /mcp response: %+v", message)
	}

	malformed := sendDirectStreamableHTTP(t, ctx, baseURL, sessionID, `{invalid json}`)
	defer malformed.Body.Close()
	if malformed.StatusCode != http.StatusBadRequest {
		t.Fatalf("malformed POST /mcp status=%d, want 400", malformed.StatusCode)
	}
	var parseResponse transport.Message
	if err := json.NewDecoder(malformed.Body).Decode(&parseResponse); err != nil {
		t.Fatalf("decode parse-error response: %v", err)
	}
	if parseResponse.Error == nil || parseResponse.Error.Code != transport.ErrCodeParseError || string(parseResponse.ID) != "null" {
		t.Fatalf("parse-error response=%+v", parseResponse)
	}

	recovered := sendDirectStreamableHTTP(t, ctx, baseURL, sessionID, `{"jsonrpc":"2.0","id":2,"method":"ping"}`)
	defer recovered.Body.Close()
	if recovered.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(recovered.Body)
		t.Fatalf("recovery POST /mcp status=%d body=%q, want 200", recovered.StatusCode, body)
	}
}

func TestHTTPTransport_StreamableTopology(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, baseURL, _, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()
	sessionID := initializeDirectStreamableHTTPSession(t, ctx, http.DefaultClient, baseURL)

	get, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+transport.MCPEndpointPath, nil)
	if err != nil {
		t.Fatalf("create GET /mcp: %v", err)
	}
	get.Header.Set("Accept", "text/event-stream")
	get.Header.Set("MCP-Session-Id", sessionID)
	getResponse, err := http.DefaultClient.Do(get)
	if err != nil {
		t.Fatalf("GET /mcp: %v", err)
	}
	getResponse.Body.Close()
	if getResponse.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET /mcp status=%d, want 405", getResponse.StatusCode)
	}

	for _, path := range []string{"/message", "/events"} {
		response, err := http.Get(baseURL + path)
		if err != nil {
			t.Fatalf("GET legacy %s: %v", path, err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf("legacy %s status=%d, want 404", path, response.StatusCode)
		}
	}
}

func TestHTTPTransport_ConcurrentResponsesRemainRequestScoped(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, baseURL, _, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()
	// A dedicated non-reusing client prevents the fixture from racing surplus
	// speculative dials into net/http StateNew after all intended requests have
	// completed. The 64 requests still execute concurrently on distinct sockets.
	clientTransport := &http.Transport{DisableKeepAlives: true}
	defer clientTransport.CloseIdleConnections()
	client := &http.Client{Transport: clientTransport}
	sessionID := initializeDirectStreamableHTTPSession(t, ctx, client, baseURL)

	const requestCount = 64
	errors := make(chan error, requestCount)
	var waitGroup sync.WaitGroup
	for id := 1; id <= requestCount; id++ {
		waitGroup.Add(1)
		go func(id int) {
			defer waitGroup.Done()
			payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"ping"}`, id)
			response := sendDirectStreamableHTTPNoFatalWithClient(client, ctx, baseURL, sessionID, payload)
			if response.err != nil {
				errors <- response.err
				return
			}
			var message transport.Message
			if err := json.NewDecoder(response.response.Body).Decode(&message); err != nil {
				_ = response.response.Body.Close()
				errors <- fmt.Errorf("request %d decode: %w", id, err)
				return
			}
			// A JSON decoder may stop after the first value without consuming the
			// response terminator. Drain and close before declaring this request
			// complete so graceful shutdown is testing the server, not 64 client
			// connections that the test itself left mid-response.
			if _, err := io.Copy(io.Discard, response.response.Body); err != nil {
				_ = response.response.Body.Close()
				errors <- fmt.Errorf("request %d drain response: %w", id, err)
				return
			}
			if err := response.response.Body.Close(); err != nil {
				errors <- fmt.Errorf("request %d close response: %w", id, err)
				return
			}
			if response.response.StatusCode != http.StatusOK || string(message.ID) != fmt.Sprint(id) {
				errors <- fmt.Errorf("request %d received status=%d id=%q", id, response.response.StatusCode, message.ID)
			}
		}(id)
	}
	waitGroup.Wait()
	close(errors)
	for err := range errors {
		t.Error(err)
	}
}

func TestHTTPTransport_CORSPreflight(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, baseURL, _, cleanup := startHTTPTransport(t, ctx, echoHandler)
	defer cleanup()

	request, err := http.NewRequestWithContext(ctx, http.MethodOptions, baseURL+transport.MCPEndpointPath, nil)
	if err != nil {
		t.Fatalf("create CORS preflight: %v", err)
	}
	request.Header.Set("Origin", "https://trusted.example")
	request.Header.Set("Access-Control-Request-Method", "POST")
	request.Header.Set("Access-Control-Request-Headers", "Accept, Content-Type, MCP-Protocol-Version")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("send CORS preflight: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("CORS preflight status=%d, want 204", response.StatusCode)
	}
	if response.Header.Get("Access-Control-Allow-Origin") != "https://trusted.example" {
		t.Fatalf("CORS origin=%q, want trusted origin", response.Header.Get("Access-Control-Allow-Origin"))
	}
	for _, required := range []string{"POST", "DELETE"} {
		if !strings.Contains(response.Header.Get("Access-Control-Allow-Methods"), required) {
			t.Errorf("CORS methods omitted %s: %q", required, response.Header.Get("Access-Control-Allow-Methods"))
		}
	}
	for _, required := range []string{"Accept", "MCP-Protocol-Version"} {
		if !strings.Contains(response.Header.Get("Access-Control-Allow-Headers"), required) {
			t.Errorf("CORS headers omitted %s: %q", required, response.Header.Get("Access-Control-Allow-Headers"))
		}
	}
}

func TestHTTPTransport_GracefulShutdown(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tr, _, address, cleanup := startHTTPTransport(t, ctx, echoHandler)
	cleanup()
	if !tr.IsClosed() {
		t.Fatal("transport is not closed after cleanup")
	}
	if err := tr.Close(); err != nil {
		t.Fatalf("second Close() error=%v, want idempotent success", err)
	}
	releaseCtx, cancelRelease := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelRelease()
	if err := waitForPortAvailable(t, releaseCtx, address); err != nil {
		t.Fatalf("HTTP transport address was not released: %v", err)
	}
}

func sendDirectStreamableHTTP(
	t *testing.T,
	ctx context.Context,
	baseURL string,
	sessionID string,
	payload string,
) *http.Response {
	t.Helper()
	result := sendDirectStreamableHTTPNoFatal(ctx, baseURL, sessionID, payload)
	if result.err != nil {
		t.Fatalf("send Streamable HTTP request: %v", result.err)
	}
	return result.response
}

type directStreamableHTTPResult struct {
	response *http.Response
	err      error
}

func sendDirectStreamableHTTPNoFatal(
	ctx context.Context,
	baseURL string,
	sessionID string,
	payload string,
) directStreamableHTTPResult {
	return sendDirectStreamableHTTPNoFatalWithClient(http.DefaultClient, ctx, baseURL, sessionID, payload)
}

func sendDirectStreamableHTTPNoFatalWithClient(
	client *http.Client,
	ctx context.Context,
	baseURL string,
	sessionID string,
	payload string,
) directStreamableHTTPResult {
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		baseURL+transport.MCPEndpointPath,
		bytes.NewBufferString(payload),
	)
	if err != nil {
		return directStreamableHTTPResult{err: err}
	}
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("MCP-Protocol-Version", transport.MCPProtocolVersionCurrent)
	if sessionID != "" {
		request.Header.Set("MCP-Session-Id", sessionID)
	}
	response, err := client.Do(request)
	return directStreamableHTTPResult{response: response, err: err}
}

func initializeDirectStreamableHTTPSession(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
) string {
	t.Helper()
	result := sendDirectStreamableHTTPNoFatalWithClient(
		client,
		ctx,
		baseURL,
		"",
		`{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{}}`,
	)
	if result.err != nil {
		t.Fatalf("initialize Streamable HTTP session: %v", result.err)
	}
	defer result.response.Body.Close()
	if result.response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(result.response.Body)
		t.Fatalf("initialize Streamable HTTP session status=%d body=%q", result.response.StatusCode, body)
	}
	sessionID := result.response.Header.Get("MCP-Session-Id")
	if sessionID == "" {
		t.Fatal("initialize Streamable HTTP session omitted MCP-Session-Id")
	}
	if _, err := io.Copy(io.Discard, result.response.Body); err != nil {
		t.Fatalf("drain Streamable HTTP initialize response: %v", err)
	}
	return sessionID
}
