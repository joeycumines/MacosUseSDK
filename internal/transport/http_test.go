// Copyright 2025 Joseph Cumines
//
// HTTP/SSE transport unit tests

package transport

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNewHTTPTransport(t *testing.T) {
	tr := NewHTTPTransport(nil)
	if tr == nil {
		t.Fatal("NewHTTPTransport returned nil")
	}
	if tr.config == nil {
		t.Error("Transport config is nil")
	}
	if tr.config.Address != ":8080" {
		t.Errorf("Default address = %s, want :8080", tr.config.Address)
	}
	if tr.config.HeartbeatInterval != 15*time.Second {
		t.Errorf("Default heartbeat = %v, want 15s", tr.config.HeartbeatInterval)
	}
	if tr.config.CORSOrigin != "*" {
		t.Errorf("Default CORS = %s, want *", tr.config.CORSOrigin)
	}
}

func TestNewHTTPTransport_WithConfig(t *testing.T) {
	cfg := &HTTPTransportConfig{
		Address:           ":9000",
		HeartbeatInterval: 60 * time.Second,
		CORSOrigin:        "https://example.com",
	}
	tr := NewHTTPTransport(cfg)
	if tr.config.Address != ":9000" {
		t.Errorf("Address = %s, want :9000", tr.config.Address)
	}
	if tr.config.HeartbeatInterval != 60*time.Second {
		t.Errorf("HeartbeatInterval = %v, want 60s", tr.config.HeartbeatInterval)
	}
	if tr.config.CORSOrigin != "https://example.com" {
		t.Errorf("CORSOrigin = %s, want https://example.com", tr.config.CORSOrigin)
	}
}

func TestDefaultHTTPConfig(t *testing.T) {
	cfg := DefaultHTTPConfig()
	if cfg.Address != ":8080" {
		t.Errorf("Address = %s, want :8080", cfg.Address)
	}
	if cfg.HeartbeatInterval != 15*time.Second {
		t.Errorf("HeartbeatInterval = %v, want 15s", cfg.HeartbeatInterval)
	}
	if cfg.CORSOrigin != "*" {
		t.Errorf("CORSOrigin = %s, want *", cfg.CORSOrigin)
	}
	if cfg.ReadTimeout != 30*time.Second {
		t.Errorf("ReadTimeout = %v, want 30s", cfg.ReadTimeout)
	}
	if cfg.WriteTimeout != 0 {
		t.Errorf("WriteTimeout = %v, want 0 (disabled for SSE)", cfg.WriteTimeout)
	}
}

func TestHTTPTransport_HandleMessage(t *testing.T) {
	tr := NewHTTPTransport(nil)
	tr.handler = func(msg *Message) (*Message, error) {
		return &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  json.RawMessage(`{"ok":true}`),
		}, nil
	}

	// Create test request
	body := bytes.NewBufferString(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	req := httptest.NewRequest("POST", "/message", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	tr.handleMessage(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("Status = %d, want 200", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	var msg Message
	if err := json.Unmarshal(respBody, &msg); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}

	if msg.JSONRPC != "2.0" {
		t.Errorf("JSONRPC = %s, want 2.0", msg.JSONRPC)
	}
}

func TestHTTPTransport_HandleMessage_MethodNotAllowed(t *testing.T) {
	tr := NewHTTPTransport(nil)

	req := httptest.NewRequest("GET", "/message", nil)
	w := httptest.NewRecorder()

	tr.handleMessage(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Status = %d, want 405", w.Code)
	}
}

func TestHTTPTransport_HandleMessage_InvalidJSON(t *testing.T) {
	tr := NewHTTPTransport(nil)

	body := bytes.NewBufferString(`{invalid json}`)
	req := httptest.NewRequest("POST", "/message", body)
	w := httptest.NewRecorder()

	tr.handleMessage(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Status = %d, want 400", w.Code)
	}
}

// TestHTTPTransport_HandleMessage_Notification verifies that JSON-RPC 2.0
// notifications (where handler returns nil, nil) produce a 204 No Content
// response instead of encoding JSON null. A prior bug sent "null" as the
// response body with 200 OK.
func TestHTTPTransport_HandleMessage_Notification(t *testing.T) {
	tr := NewHTTPTransport(nil)
	tr.handler = func(msg *Message) (*Message, error) {
		// Notifications return nil response
		return nil, nil
	}

	body := bytes.NewBufferString(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	req := httptest.NewRequest("POST", "/message", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	tr.handleMessage(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("Status = %d, want 204 for notification", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	if len(respBody) > 0 {
		t.Errorf("Expected empty body for notification, got: %s", respBody)
	}
}

func TestHTTPTransport_HandleHealth(t *testing.T) {
	tr := NewHTTPTransport(nil)

	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()

	tr.handleHealth(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("Status = %d, want 200", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	var health map[string]interface{}
	if err := json.Unmarshal(respBody, &health); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}

	if health["status"] != "ok" {
		t.Errorf("Status = %v, want ok", health["status"])
	}
}

func TestHTTPTransport_CORS(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.com",
	})

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("OPTIONS", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Header().Get("Access-Control-Allow-Origin") != "https://allowed.com" {
		t.Errorf("CORS Origin = %s, want https://allowed.com", w.Header().Get("Access-Control-Allow-Origin"))
	}

	if w.Code != http.StatusNoContent {
		t.Errorf("OPTIONS Status = %d, want 204", w.Code)
	}
}

func TestHTTPTransport_Close(t *testing.T) {
	tr := NewHTTPTransport(nil)

	if tr.IsClosed() {
		t.Error("Transport should not be closed initially")
	}

	if err := tr.Close(); err != nil {
		t.Errorf("Close() error = %v", err)
	}

	if !tr.IsClosed() {
		t.Error("Transport should be closed after Close()")
	}

	// Second close should not error
	if err := tr.Close(); err != nil {
		t.Errorf("Close() again error = %v", err)
	}
}

func TestHTTPTransport_ReadMessage(t *testing.T) {
	tr := NewHTTPTransport(nil)

	// HTTPTransport should return error immediately - it doesn't support ReadMessage
	_, err := tr.ReadMessage()
	if err == nil {
		t.Error("Expected error from HTTPTransport.ReadMessage")
	}
	if !strings.Contains(err.Error(), "not supported") {
		t.Errorf("Error should mention 'not supported', got: %v", err)
	}
}

func TestHTTPTransport_WriteMessage(t *testing.T) {
	tr := NewHTTPTransport(nil)

	msg := &Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Result:  json.RawMessage(`{"ok":true}`),
	}

	if err := tr.WriteMessage(msg); err != nil {
		t.Errorf("WriteMessage() error = %v", err)
	}
}

func TestHTTPTransport_WriteMessage_Closed(t *testing.T) {
	tr := NewHTTPTransport(nil)
	tr.Close()

	msg := &Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
	}

	err := tr.WriteMessage(msg)
	if err == nil {
		t.Error("Expected error writing to closed transport")
	}
	if !strings.Contains(err.Error(), "closed") {
		t.Errorf("Error should mention closed, got: %v", err)
	}
}

func TestClientRegistry(t *testing.T) {
	reg := NewClientRegistry()

	if reg.Count() != 0 {
		t.Errorf("Initial count = %d, want 0", reg.Count())
	}

	client := reg.Add("")
	if client == nil {
		t.Fatal("Add() returned nil")
	}
	if client.ID == "" {
		t.Error("Client ID should not be empty")
	}

	if reg.Count() != 1 {
		t.Errorf("Count after add = %d, want 1", reg.Count())
	}

	found, ok := reg.Get(client.ID)
	if !ok || found.ID != client.ID {
		t.Error("Get() should return the added client")
	}

	reg.Remove(client.ID)
	if reg.Count() != 0 {
		t.Errorf("Count after remove = %d, want 0", reg.Count())
	}
}

func TestClientRegistry_Broadcast(t *testing.T) {
	reg := NewClientRegistry()
	client := reg.Add("")

	event := &SSEEvent{
		ID:    "1",
		Event: "message",
		Data:  "test data",
	}

	reg.Broadcast(event)

	select {
	case received := <-client.ResponseChan:
		if received.ID != "1" {
			t.Errorf("Event ID = %s, want 1", received.ID)
		}
	default:
		t.Error("Client should have received the broadcast")
	}
}

func TestEventStore(t *testing.T) {
	store := NewEventStore(3)

	store.Add(&SSEEvent{ID: "1", Event: "msg", Data: "data1"})
	store.Add(&SSEEvent{ID: "2", Event: "msg", Data: "data2"})
	store.Add(&SSEEvent{ID: "3", Event: "msg", Data: "data3"})

	events := store.GetSince("1")
	if len(events) != 2 {
		t.Errorf("GetSince('1') returned %d events, want 2", len(events))
	}

	// Add one more to trigger eviction (store max is 3, now has 4, so oldest is evicted)
	store.Add(&SSEEvent{ID: "4", Event: "msg", Data: "data4"})

	// Event 1 was evicted, so GetSince("1") returns nothing (ID not found)
	events = store.GetSince("1")
	if len(events) != 0 {
		t.Errorf("GetSince('1') after eviction returned %d events, want 0 (ID 1 evicted)", len(events))
	}

	// GetSince("2") should return events 3 and 4
	events = store.GetSince("2")
	if len(events) != 2 {
		t.Errorf("GetSince('2') after eviction returned %d events, want 2", len(events))
	}
}

func TestSSEEvent_Format(t *testing.T) {
	event := &SSEEvent{
		ID:    "123",
		Event: "message",
		Data:  `{"test":true}`,
	}

	if event.ID != "123" {
		t.Errorf("ID = %s, want 123", event.ID)
	}
	if event.Event != "message" {
		t.Errorf("Event = %s, want message", event.Event)
	}
	if event.Data != `{"test":true}` {
		t.Errorf("Data = %s, want {\"test\":true}", event.Data)
	}
}

func TestSSEClient(t *testing.T) {
	client := &SSEClient{
		ID:           "client-1",
		ResponseChan: make(chan *SSEEvent, 10),
		CreatedAt:    time.Now(),
		LastEventID:  "0",
	}

	if client.ID != "client-1" {
		t.Errorf("ID = %s, want client-1", client.ID)
	}
}

func TestHTTPTransport_AuthMiddleware_NoAuthRequired(t *testing.T) {
	// Without APIKey, no auth should be required
	tr := NewHTTPTransport(nil)

	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()

	tr.handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Status = %d, want 200 (no auth required)", w.Code)
	}
}

func TestHTTPTransport_AuthMiddleware_ValidToken(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("authenticated"))
	}))

	req := httptest.NewRequest("POST", "/message", nil)
	req.Header.Set("Authorization", "Bearer test-secret-key")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Status = %d, want 200", w.Code)
	}
}

func TestHTTPTransport_AuthMiddleware_InvalidToken(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("POST", "/message", nil)
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Status = %d, want 401", w.Code)
	}
	if !strings.Contains(w.Body.String(), "Invalid API key") {
		t.Errorf("Response = %s, want 'Invalid API key' message", w.Body.String())
	}
}

func TestHTTPTransport_AuthMiddleware_MissingHeader(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("POST", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Status = %d, want 401", w.Code)
	}
	if !strings.Contains(w.Body.String(), "Authorization header required") {
		t.Errorf("Response = %s, want 'Authorization header required' message", w.Body.String())
	}
}

func TestHTTPTransport_AuthMiddleware_InvalidFormat(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("POST", "/message", nil)
	req.Header.Set("Authorization", "Basic dXNlcjpwYXNz") // Using Basic auth instead of Bearer
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Status = %d, want 401", w.Code)
	}
	if !strings.Contains(w.Body.String(), "Invalid authorization format") {
		t.Errorf("Response = %s, want 'Invalid authorization format' message", w.Body.String())
	}
}

func TestHTTPTransport_AuthMiddleware_HealthExempt(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("health ok"))
	}))

	// Health endpoint without auth should still work
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Status = %d, want 200 (health is exempt from auth)", w.Code)
	}
}

func TestHTTPTransport_IsTLSEnabled(t *testing.T) {
	tests := []struct {
		name    string
		config  *HTTPTransportConfig
		enabled bool
	}{
		{
			name:    "both paths set",
			config:  &HTTPTransportConfig{TLSCertFile: "/path/cert.pem", TLSKeyFile: "/path/key.pem"},
			enabled: true,
		},
		{
			name:    "only cert set",
			config:  &HTTPTransportConfig{TLSCertFile: "/path/cert.pem"},
			enabled: false,
		},
		{
			name:    "only key set",
			config:  &HTTPTransportConfig{TLSKeyFile: "/path/key.pem"},
			enabled: false,
		},
		{
			name:    "neither set",
			config:  &HTTPTransportConfig{},
			enabled: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(tt.config)
			if got := tr.IsTLSEnabled(); got != tt.enabled {
				t.Errorf("IsTLSEnabled() = %v, want %v", got, tt.enabled)
			}
		})
	}
}

func TestHTTPTransport_IsAuthEnabled(t *testing.T) {
	tests := []struct {
		name    string
		config  *HTTPTransportConfig
		enabled bool
	}{
		{
			name:    "api key set",
			config:  &HTTPTransportConfig{APIKey: "secret"},
			enabled: true,
		},
		{
			name:    "api key empty",
			config:  &HTTPTransportConfig{APIKey: ""},
			enabled: false,
		},
		{
			name:    "default config",
			config:  nil,
			enabled: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(tt.config)
			if got := tr.IsAuthEnabled(); got != tt.enabled {
				t.Errorf("IsAuthEnabled() = %v, want %v", got, tt.enabled)
			}
		})
	}
}

func TestHTTPTransport_CORS_AuthorizationHeader(t *testing.T) {
	// Verify CORS allows Authorization header
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.com",
	})

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("OPTIONS", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	allowHeaders := w.Header().Get("Access-Control-Allow-Headers")
	if !strings.Contains(allowHeaders, "Authorization") {
		t.Errorf("Access-Control-Allow-Headers = %s, should include 'Authorization'", allowHeaders)
	}
}

func TestHTTPTransport_HandleMetrics(t *testing.T) {
	tr := NewHTTPTransport(nil)

	// Record some metrics
	tr.metrics.RecordRequest("click", "ok", 50*time.Millisecond)
	tr.metrics.RecordRequest("type_text", "error", 100*time.Millisecond)
	tr.metrics.SetSSEConnections(3)
	tr.metrics.RecordSSEEvent()

	req := httptest.NewRequest("GET", "/metrics", nil)
	w := httptest.NewRecorder()

	tr.handleMetrics(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("Status = %d, want 200", resp.StatusCode)
	}

	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "text/plain") {
		t.Errorf("Content-Type = %s, want text/plain", contentType)
	}

	body, _ := io.ReadAll(resp.Body)
	bodyStr := string(body)

	// Verify Prometheus format
	if !strings.Contains(bodyStr, "# TYPE mcp_requests_total counter") {
		t.Errorf("Missing counter type, got:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, "# TYPE mcp_request_duration_seconds histogram") {
		t.Errorf("Missing histogram type, got:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, "# TYPE mcp_sse_connections_active gauge") {
		t.Errorf("Missing gauge type, got:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, `tool="click"`) {
		t.Errorf("Missing click tool metric, got:\n%s", bodyStr)
	}
}

func TestHTTPTransport_HandleMetrics_MethodNotAllowed(t *testing.T) {
	tr := NewHTTPTransport(nil)

	req := httptest.NewRequest("POST", "/metrics", nil)
	w := httptest.NewRecorder()

	tr.handleMetrics(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Status = %d, want 405", w.Code)
	}
}

func TestHTTPTransport_Metrics(t *testing.T) {
	tr := NewHTTPTransport(nil)

	m := tr.Metrics()
	if m == nil {
		t.Fatal("Metrics() returned nil")
	}
}

func TestHTTPTransport_IsRateLimitEnabled(t *testing.T) {
	tests := []struct {
		name    string
		config  *HTTPTransportConfig
		enabled bool
	}{
		{
			name:    "rate limit set",
			config:  &HTTPTransportConfig{RateLimit: 10.0},
			enabled: true,
		},
		{
			name:    "rate limit zero",
			config:  &HTTPTransportConfig{RateLimit: 0},
			enabled: false,
		},
		{
			name:    "rate limit negative",
			config:  &HTTPTransportConfig{RateLimit: -1},
			enabled: false,
		},
		{
			name:    "default config",
			config:  nil,
			enabled: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(tt.config)
			if got := tr.IsRateLimitEnabled(); got != tt.enabled {
				t.Errorf("IsRateLimitEnabled() = %v, want %v", got, tt.enabled)
			}
		})
	}
}

// =============================================================================
// CORS Tests - Comprehensive coverage for CORS middleware behavior
// =============================================================================

// TestCORS_Preflight_ValidOrigin verifies OPTIONS preflight requests return
// 204 No Content with correct CORS headers for various origin configurations.
func TestCORS_Preflight_ValidOrigin(t *testing.T) {
	tests := []struct {
		name           string
		configOrigin   string
		requestOrigin  string
		wantAllowedOrg string
		wantStatus     int
	}{
		{
			name:           "wildcard origin allows any request",
			configOrigin:   "*",
			requestOrigin:  "https://example.com",
			wantAllowedOrg: "*",
			wantStatus:     http.StatusNoContent,
		},
		{
			name:           "specific origin echoes configured value",
			configOrigin:   "https://allowed.example.com",
			requestOrigin:  "https://allowed.example.com",
			wantAllowedOrg: "https://allowed.example.com",
			wantStatus:     http.StatusNoContent,
		},
		{
			name:           "preflight without Origin header still returns configured CORS",
			configOrigin:   "https://allowed.com",
			requestOrigin:  "",
			wantAllowedOrg: "https://allowed.com",
			wantStatus:     http.StatusNoContent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(&HTTPTransportConfig{
				CORSOrigin: tt.configOrigin,
			})

			handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				t.Error("Next handler should not be called for OPTIONS")
			}))

			req := httptest.NewRequest("OPTIONS", "/message", nil)
			if tt.requestOrigin != "" {
				req.Header.Set("Origin", tt.requestOrigin)
			}
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("Status = %d, want %d", w.Code, tt.wantStatus)
			}
			if got := w.Header().Get("Access-Control-Allow-Origin"); got != tt.wantAllowedOrg {
				t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, tt.wantAllowedOrg)
			}
		})
	}
}

// TestCORS_Preflight_InvalidOrigin verifies that when a specific origin is
// configured, the server still echoes it back (current implementation does
// not validate the incoming Origin header against an allowlist).
func TestCORS_Preflight_InvalidOrigin(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.example.com",
	})

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Next handler should not be called for OPTIONS")
	}))

	// Request from a different origin
	req := httptest.NewRequest("OPTIONS", "/message", nil)
	req.Header.Set("Origin", "https://malicious.example.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	// Current implementation: origin is NOT validated, configured value is echoed
	// The browser will reject the response if it doesn't match the request Origin,
	// but the server doesn't perform this validation.
	if w.Code != http.StatusNoContent {
		t.Errorf("Status = %d, want %d", w.Code, http.StatusNoContent)
	}
	// Server echoes configured origin (not the request origin)
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "https://allowed.example.com" {
		t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, "https://allowed.example.com")
	}
}

// TestCORS_ActualRequest_ValidOrigin verifies that actual (non-preflight)
// requests include CORS headers and proceed to the handler.
func TestCORS_ActualRequest_ValidOrigin(t *testing.T) {
	tests := []struct {
		name           string
		method         string
		path           string
		configOrigin   string
		requestOrigin  string
		wantAllowedOrg string
	}{
		{
			name:           "GET request with wildcard origin",
			method:         "GET",
			path:           "/health",
			configOrigin:   "*",
			requestOrigin:  "https://client.example.com",
			wantAllowedOrg: "*",
		},
		{
			name:           "POST request with specific origin",
			method:         "POST",
			path:           "/message",
			configOrigin:   "https://trusted.example.com",
			requestOrigin:  "https://trusted.example.com",
			wantAllowedOrg: "https://trusted.example.com",
		},
		{
			name:           "GET request without Origin header",
			method:         "GET",
			path:           "/events",
			configOrigin:   "https://app.example.com",
			requestOrigin:  "",
			wantAllowedOrg: "https://app.example.com",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(&HTTPTransportConfig{
				CORSOrigin: tt.configOrigin,
			})

			handlerCalled := false
			handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				handlerCalled = true
				w.WriteHeader(http.StatusOK)
			}))

			req := httptest.NewRequest(tt.method, tt.path, nil)
			if tt.requestOrigin != "" {
				req.Header.Set("Origin", tt.requestOrigin)
			}
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if !handlerCalled {
				t.Error("Handler was not called for non-OPTIONS request")
			}
			if got := w.Header().Get("Access-Control-Allow-Origin"); got != tt.wantAllowedOrg {
				t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, tt.wantAllowedOrg)
			}
		})
	}
}

// TestCORS_ActualRequest_InvalidOrigin verifies CORS headers are echoed
// even when the request Origin doesn't match the configured allowed origin.
// Note: The browser enforces CORS, not the server. The server echoes the
// configured origin and the browser rejects mismatches.
func TestCORS_ActualRequest_InvalidOrigin(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.example.com",
	})

	handlerCalled := false
	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("POST", "/message", nil)
	req.Header.Set("Origin", "https://malicious.example.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	// Handler is still called (server doesn't block requests based on Origin)
	if !handlerCalled {
		t.Error("Handler should be called (server doesn't enforce CORS origin)")
	}
	// Server echoes configured origin, not request origin
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "https://allowed.example.com" {
		t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, "https://allowed.example.com")
	}
}

// TestCORS_AllowMethods verifies Access-Control-Allow-Methods header lists
// the expected HTTP methods (GET, POST, OPTIONS).
func TestCORS_AllowMethods(t *testing.T) {
	tests := []struct {
		name   string
		method string
	}{
		{"OPTIONS preflight", "OPTIONS"},
		{"GET request", "GET"},
		{"POST request", "POST"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(nil)

			handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			}))

			req := httptest.NewRequest(tt.method, "/message", nil)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			allowMethods := w.Header().Get("Access-Control-Allow-Methods")
			expectedMethods := []string{"GET", "POST", "OPTIONS"}
			for _, method := range expectedMethods {
				if !strings.Contains(allowMethods, method) {
					t.Errorf("Access-Control-Allow-Methods = %q, missing %q", allowMethods, method)
				}
			}
		})
	}
}

// TestCORS_AllowHeaders verifies Access-Control-Allow-Headers includes
// required headers (Content-Type, Last-Event-ID, Authorization).
func TestCORS_AllowHeaders(t *testing.T) {
	tr := NewHTTPTransport(nil)

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("OPTIONS", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	allowHeaders := w.Header().Get("Access-Control-Allow-Headers")
	expectedHeaders := []string{"Content-Type", "Last-Event-ID", "Authorization"}
	for _, header := range expectedHeaders {
		if !strings.Contains(allowHeaders, header) {
			t.Errorf("Access-Control-Allow-Headers = %q, missing %q", allowHeaders, header)
		}
	}
}

// TestCORS_ExposeHeaders verifies Access-Control-Expose-Headers includes
// headers that should be accessible to client JavaScript.
func TestCORS_ExposeHeaders(t *testing.T) {
	tr := NewHTTPTransport(nil)

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	exposeHeaders := w.Header().Get("Access-Control-Expose-Headers")
	if !strings.Contains(exposeHeaders, "Content-Type") {
		t.Errorf("Access-Control-Expose-Headers = %q, missing 'Content-Type'", exposeHeaders)
	}
}

// TestCORS_WildcardOriginHandling verifies that wildcard "*" origin behaves
// correctly for both preflight and actual requests.
func TestCORS_WildcardOriginHandling(t *testing.T) {
	tests := []struct {
		name          string
		method        string
		requestOrigin string
	}{
		{"preflight from any origin", "OPTIONS", "https://any-domain.com"},
		{"preflight from localhost", "OPTIONS", "http://localhost:3000"},
		{"GET from any origin", "GET", "https://example.org"},
		{"POST from any origin", "POST", "https://api.client.com"},
		{"request with null origin", "GET", "null"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := NewHTTPTransport(&HTTPTransportConfig{
				CORSOrigin: "*",
			})

			handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			}))

			req := httptest.NewRequest(tt.method, "/message", nil)
			req.Header.Set("Origin", tt.requestOrigin)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			// With wildcard "*", all origins should receive "*" in response
			if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
				t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, "*")
			}
		})
	}
}

// TestCORS_DefaultConfig verifies CORS behavior with default configuration.
func TestCORS_DefaultConfig(t *testing.T) {
	tr := NewHTTPTransport(nil) // Uses default config with CORSOrigin: "*"

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("OPTIONS", "/message", nil)
	req.Header.Set("Origin", "https://any-origin.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	// Default config should allow all origins
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("Access-Control-Allow-Origin = %q, want %q (default)", got, "*")
	}
	if w.Code != http.StatusNoContent {
		t.Errorf("Status = %d, want %d", w.Code, http.StatusNoContent)
	}
}

// TestCORS_PreflightDoesNotCallNextHandler verifies that OPTIONS preflight
// requests are handled entirely by the CORS middleware and do not reach
// the underlying handler.
func TestCORS_PreflightDoesNotCallNextHandler(t *testing.T) {
	tr := NewHTTPTransport(nil)

	handlerCalled := false
	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true
	}))

	req := httptest.NewRequest("OPTIONS", "/message", nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if handlerCalled {
		t.Error("Next handler should not be called for OPTIONS preflight")
	}
}

// TestCORS_HeadersPresentOnAllEndpoints verifies CORS headers are set
// regardless of the endpoint being accessed.
func TestCORS_HeadersPresentOnAllEndpoints(t *testing.T) {
	endpoints := []string{"/message", "/events", "/health", "/metrics"}

	for _, endpoint := range endpoints {
		t.Run(endpoint, func(t *testing.T) {
			tr := NewHTTPTransport(&HTTPTransportConfig{
				CORSOrigin: "https://test.example.com",
			})

			handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			}))

			req := httptest.NewRequest("GET", endpoint, nil)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if got := w.Header().Get("Access-Control-Allow-Origin"); got == "" {
				t.Errorf("Access-Control-Allow-Origin missing for endpoint %s", endpoint)
			}
			if got := w.Header().Get("Access-Control-Allow-Methods"); got == "" {
				t.Errorf("Access-Control-Allow-Methods missing for endpoint %s", endpoint)
			}
			if got := w.Header().Get("Access-Control-Allow-Headers"); got == "" {
				t.Errorf("Access-Control-Allow-Headers missing for endpoint %s", endpoint)
			}
		})
	}
}
