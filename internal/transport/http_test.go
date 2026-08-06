// Copyright 2025 Joseph Cumines
//
// MCP Streamable HTTP transport unit tests

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
	if tr.config.Address != "127.0.0.1:8080" {
		t.Errorf("Default address = %s, want 127.0.0.1:8080", tr.config.Address)
	}
	if tr.config.CORSOrigin != "" {
		t.Errorf("Default CORS = %s, want empty secure default", tr.config.CORSOrigin)
	}
}

func TestNewHTTPTransport_WithConfig(t *testing.T) {
	cfg := &HTTPTransportConfig{
		Address:    ":9000",
		CORSOrigin: "https://example.com",
	}
	tr := NewHTTPTransport(cfg)
	if tr.config.Address != ":9000" {
		t.Errorf("Address = %s, want :9000", tr.config.Address)
	}
	if tr.config.CORSOrigin != "https://example.com" {
		t.Errorf("CORSOrigin = %s, want https://example.com", tr.config.CORSOrigin)
	}
}

func TestDefaultHTTPConfig(t *testing.T) {
	cfg := DefaultHTTPConfig()
	if cfg.Address != "127.0.0.1:8080" {
		t.Errorf("Address = %s, want 127.0.0.1:8080", cfg.Address)
	}
	if cfg.CORSOrigin != "" {
		t.Errorf("CORSOrigin = %s, want empty secure default", cfg.CORSOrigin)
	}
	if cfg.ReadTimeout != 30*time.Second {
		t.Errorf("ReadTimeout = %v, want 30s", cfg.ReadTimeout)
	}
	if cfg.WriteTimeout != 30*time.Second {
		t.Errorf("WriteTimeout = %v, want 30s", cfg.WriteTimeout)
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
	req := httptest.NewRequest("POST", MCPEndpointPath, body)
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("MCP-Session-Id", newHTTPTestSession(t, tr))
	w := httptest.NewRecorder()

	tr.handleMCPPost(w, req)

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

	req := httptest.NewRequest("GET", MCPEndpointPath, nil)
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("MCP-Session-Id", newHTTPTestSession(t, tr))
	w := httptest.NewRecorder()

	tr.handleMCP(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Status = %d, want 405", w.Code)
	}
}

func TestHTTPTransport_HandleMessage_InvalidJSON(t *testing.T) {
	tr := NewHTTPTransport(nil)

	body := bytes.NewBufferString(`{invalid json}`)
	req := httptest.NewRequest("POST", MCPEndpointPath, body)
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("MCP-Session-Id", newHTTPTestSession(t, tr))
	w := httptest.NewRecorder()

	tr.handleMCPPost(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Status = %d, want 400", w.Code)
	}
}

func newHTTPTestSession(t *testing.T, tr *HTTPTransport) string {
	t.Helper()
	sessionID, err := tr.createHTTPSession()
	if err != nil {
		t.Fatalf("create HTTP test session: %v", err)
	}
	return sessionID
}

// TestHTTPTransport_HandleMessage_Notification verifies that JSON-RPC 2.0
// notifications (where handler returns nil, nil) produce the Streamable HTTP
// 202 Accepted response with no body.
func TestHTTPTransport_HandleMessage_Notification(t *testing.T) {
	tr := NewHTTPTransport(nil)
	tr.handler = func(msg *Message) (*Message, error) {
		// Notifications return nil response
		return nil, nil
	}

	body := bytes.NewBufferString(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	req := httptest.NewRequest("POST", MCPEndpointPath, body)
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("MCP-Session-Id", newHTTPTestSession(t, tr))
	w := httptest.NewRecorder()

	tr.handleMCPPost(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusAccepted {
		t.Errorf("Status = %d, want 202 for notification", resp.StatusCode)
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
	var health map[string]any
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

	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
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

	if err := tr.WriteMessage(msg); err == nil || !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("WriteMessage() error = %v, want unsupported", err)
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

	req := httptest.NewRequest("POST", MCPEndpointPath, nil)
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

	req := httptest.NewRequest("POST", MCPEndpointPath, nil)
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

	req := httptest.NewRequest("POST", MCPEndpointPath, nil)
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

	req := httptest.NewRequest("POST", MCPEndpointPath, nil)
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

	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
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
	tr.metrics.RecordRequest("type", "error", 100*time.Millisecond)

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
	if !strings.Contains(bodyStr, "# TYPE go_goroutines gauge") ||
		!strings.Contains(bodyStr, "go_goroutines ") {
		t.Errorf("Missing live Go goroutine gauge, got:\n%s", bodyStr)
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

			req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
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

// TestCORS_Preflight_InvalidOrigin verifies that a configured origin is an
// allowlist boundary, not only a response header value.
func TestCORS_Preflight_InvalidOrigin(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.example.com",
	})

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Next handler should not be called for OPTIONS")
	}))

	// Request from a different origin
	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
	req.Header.Set("Origin", "https://malicious.example.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("Status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("rejected origin received Access-Control-Allow-Origin %q", got)
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
			path:           MCPEndpointPath,
			configOrigin:   "https://trusted.example.com",
			requestOrigin:  "https://trusted.example.com",
			wantAllowedOrg: "https://trusted.example.com",
		},
		{
			name:           "GET request without Origin header",
			method:         "GET",
			path:           MCPEndpointPath,
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

// TestCORS_ActualRequest_InvalidOrigin verifies that an untrusted Origin is
// rejected before request dispatch.
func TestCORS_ActualRequest_InvalidOrigin(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		CORSOrigin: "https://allowed.example.com",
	})

	handlerCalled := false
	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("POST", MCPEndpointPath, nil)
	req.Header.Set("Origin", "https://malicious.example.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if handlerCalled {
		t.Error("handler was called for an untrusted Origin")
	}
	if w.Code != http.StatusForbidden {
		t.Errorf("Status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("rejected origin received Access-Control-Allow-Origin %q", got)
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

			req := httptest.NewRequest(tt.method, MCPEndpointPath, nil)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			allowMethods := w.Header().Get("Access-Control-Allow-Methods")
			expectedMethods := []string{"GET", "POST", "DELETE", "OPTIONS"}
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

	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	allowHeaders := w.Header().Get("Access-Control-Allow-Headers")
	expectedHeaders := []string{"Accept", "Content-Type", "Last-Event-ID", "MCP-Protocol-Version", "MCP-Session-Id", "Authorization"}
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

	req := httptest.NewRequest("GET", MCPEndpointPath, nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	exposeHeaders := w.Header().Get("Access-Control-Expose-Headers")
	if !strings.Contains(exposeHeaders, "Content-Type") {
		t.Errorf("Access-Control-Expose-Headers = %q, missing 'Content-Type'", exposeHeaders)
	}
	if !strings.Contains(exposeHeaders, "MCP-Session-Id") {
		t.Errorf("Access-Control-Expose-Headers = %q, missing 'MCP-Session-Id'", exposeHeaders)
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

			req := httptest.NewRequest(tt.method, MCPEndpointPath, nil)
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
	tr := NewHTTPTransport(nil)

	handler := tr.corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
	req.Header.Set("Origin", "https://any-origin.com")
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("rejected default Origin received Access-Control-Allow-Origin %q", got)
	}
	if w.Code != http.StatusForbidden {
		t.Errorf("Status = %d, want %d", w.Code, http.StatusForbidden)
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

	req := httptest.NewRequest("OPTIONS", MCPEndpointPath, nil)
	w := httptest.NewRecorder()

	handler.ServeHTTP(w, req)

	if handlerCalled {
		t.Error("Next handler should not be called for OPTIONS preflight")
	}
}

// TestCORS_HeadersPresentOnAllEndpoints verifies CORS headers are set
// regardless of the endpoint being accessed.
func TestCORS_HeadersPresentOnAllEndpoints(t *testing.T) {
	endpoints := []string{MCPEndpointPath, "/health", "/metrics"}

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
