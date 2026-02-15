// Copyright 2025 Joseph Cumines
//
// HTTP/SSE transport API key authentication tests

package transport

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// =============================================================================
// Bearer Token Authentication Tests - Comprehensive Coverage
// =============================================================================

// TestAuthMiddleware_ValidBearerToken verifies that requests with correct
// Authorization: Bearer <key> header are accepted.
func TestAuthMiddleware_ValidBearerToken(t *testing.T) {
	const apiKey = "test-secret-key-12345"
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: apiKey,
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("authenticated"))
	}))

	endpoints := []string{"/message", "/events", "/metrics"}
	for _, endpoint := range endpoints {
		t.Run(endpoint, func(t *testing.T) {
			req := httptest.NewRequest("POST", endpoint, nil)
			req.Header.Set("Authorization", "Bearer "+apiKey)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Errorf("%s: Status = %d, want 200", endpoint, w.Code)
			}
			if body := w.Body.String(); body != "authenticated" {
				t.Errorf("%s: Body = %q, want 'authenticated'", endpoint, body)
			}
		})
	}
}

// TestAuthMiddleware_InvalidBearerToken verifies that requests with wrong
// API key are rejected with HTTP 401 Unauthorized.
func TestAuthMiddleware_InvalidBearerToken(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "correct-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Handler should not be called for invalid token")
	}))

	invalidKeys := []struct {
		name string
		key  string
	}{
		{"wrong key", "wrong-secret-key"},
		{"empty key after Bearer", ""},
		{"partial key", "correct-secret"},
		{"key with extra suffix", "correct-secret-key-extra"},
		{"uppercase key", "CORRECT-SECRET-KEY"},
		{"key with leading space", " correct-secret-key"},
		{"key with trailing space", "correct-secret-key "},
	}

	for _, tt := range invalidKeys {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/message", nil)
			req.Header.Set("Authorization", "Bearer "+tt.key)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("Status = %d, want 401", w.Code)
			}
			if !strings.Contains(w.Body.String(), "Invalid API key") {
				t.Errorf("Body = %q, want to contain 'Invalid API key'", w.Body.String())
			}
		})
	}
}

// TestAuthMiddleware_MissingAuthorizationHeader verifies that requests without
// Authorization header are rejected with HTTP 401 Unauthorized.
func TestAuthMiddleware_MissingAuthorizationHeader(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Handler should not be called for missing auth")
	}))

	endpoints := []string{"/message", "/events", "/metrics"}
	for _, endpoint := range endpoints {
		t.Run(endpoint, func(t *testing.T) {
			req := httptest.NewRequest("GET", endpoint, nil)
			// No Authorization header
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("%s: Status = %d, want 401", endpoint, w.Code)
			}
			if !strings.Contains(w.Body.String(), "Authorization header required") {
				t.Errorf("%s: Body = %q, want to contain 'Authorization header required'", endpoint, w.Body.String())
			}
		})
	}
}

// TestAuthMiddleware_HealthEndpointExempt verifies that /health endpoint does
// not require authentication (for load balancer health checks).
func TestAuthMiddleware_HealthEndpointExempt(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("health ok"))
	}))

	tests := []struct {
		name       string
		authHeader string
	}{
		{"no auth header", ""},
		{"wrong auth header", "Bearer wrong-key"},
		{"invalid format", "Basic dXNlcjpwYXNz"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/health", nil)
			if tt.authHeader != "" {
				req.Header.Set("Authorization", tt.authHeader)
			}
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Errorf("Status = %d, want 200 (health is exempt)", w.Code)
			}
			if body := w.Body.String(); body != "health ok" {
				t.Errorf("Body = %q, want 'health ok'", body)
			}
		})
	}
}

// TestAuthMiddleware_MetricsEndpointRequiresAuth verifies that /metrics endpoint
// does require authentication when APIKey is configured.
func TestAuthMiddleware_MetricsEndpointRequiresAuth(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("metrics data"))
	}))

	// Without auth header - should be rejected
	t.Run("without auth", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/metrics", nil)
		w := httptest.NewRecorder()

		handler.ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401", w.Code)
		}
	})

	// With valid auth - should succeed
	t.Run("with valid auth", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/metrics", nil)
		req.Header.Set("Authorization", "Bearer test-secret-key")
		w := httptest.NewRecorder()

		handler.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("Status = %d, want 200", w.Code)
		}
	})
}

// TestAuthMiddleware_MalformedAuthorizationHeader verifies that various
// malformed Authorization headers are rejected with HTTP 401.
func TestAuthMiddleware_MalformedAuthorizationHeader(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "test-secret-key",
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Handler should not be called for malformed auth")
	}))

	malformedHeaders := []struct {
		name               string
		authHeader         string
		wantErrorSubstring string
	}{
		{"Bearer without key", "Bearer", "Invalid authorization format"},
		{"Bearer with only space", "Bearer ", "Invalid API key"},
		{"Basic auth scheme", "Basic dXNlcjpwYXNz", "Invalid authorization format"},
		{"Digest auth scheme", "Digest username=test", "Invalid authorization format"},
		{"empty header value", "", "Authorization header required"},
		{"just the key (no scheme)", "test-secret-key", "Invalid authorization format"},
		{"wrong scheme Bearer2", "Bearer2 test-secret-key", "Invalid authorization format"},
		{"lowercase bearer", "bearer test-secret-key", "Invalid authorization format"},
		{"mixed case bEaReR", "bEaReR test-secret-key", "Invalid authorization format"},
		{"extra spaces", "Bearer  test-secret-key", "Invalid API key"},
		{"token scheme", "Token test-secret-key", "Invalid authorization format"},
		{"API-Key scheme", "API-Key test-secret-key", "Invalid authorization format"},
	}

	for _, tt := range malformedHeaders {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/message", nil)
			if tt.authHeader != "" {
				req.Header.Set("Authorization", tt.authHeader)
			}
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("Status = %d, want 401", w.Code)
			}
			if !strings.Contains(w.Body.String(), tt.wantErrorSubstring) {
				t.Errorf("Body = %q, want to contain %q", w.Body.String(), tt.wantErrorSubstring)
			}
		})
	}
}

// TestAuthMiddleware_CaseSensitivity verifies that the "Bearer" scheme
// is case-sensitive as per RFC 7235 (HTTP Authentication).
func TestAuthMiddleware_CaseSensitivity(t *testing.T) {
	const apiKey = "test-secret-key"
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: apiKey,
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	tests := []struct {
		name       string
		scheme     string
		wantStatus int
	}{
		// RFC 7235: Authorization = credentials
		// credentials = auth-scheme #auth-param
		// auth-scheme is case-insensitive in HTTP/1.1 BUT "Bearer" is commonly
		// implemented as case-sensitive. Our implementation is case-sensitive.
		{"Bearer (correct case)", "Bearer", http.StatusOK},
		{"bearer (lowercase)", "bearer", http.StatusUnauthorized},
		{"BEARER (uppercase)", "BEARER", http.StatusUnauthorized},
		{"BeAReR (mixed case)", "BeAReR", http.StatusUnauthorized},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/message", nil)
			req.Header.Set("Authorization", tt.scheme+" "+apiKey)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("Status = %d, want %d", w.Code, tt.wantStatus)
			}
		})
	}
}

// TestAuthMiddleware_NoAuthConfigured verifies that when APIKey is not set,
// all requests pass through without authentication checks.
func TestAuthMiddleware_NoAuthConfigured(t *testing.T) {
	// No APIKey configured
	tr := NewHTTPTransport(&HTTPTransportConfig{
		// APIKey is empty
	})

	// Verify auth is not enabled
	if tr.IsAuthEnabled() {
		t.Fatal("Auth should not be enabled when APIKey is empty")
	}

	// When creating the transport without APIKey, authMiddleware is NOT applied
	// to the handler chain. So we test the handler directly.
	endpoints := []string{"/message", "/events", "/health", "/metrics"}
	methods := []string{"GET", "POST"}

	for _, endpoint := range endpoints {
		for _, method := range methods {
			t.Run(method+" "+endpoint, func(t *testing.T) {
				req := httptest.NewRequest(method, endpoint, nil)
				// No Authorization header
				w := httptest.NewRecorder()

				// Note: This tests the raw handler without auth middleware
				switch endpoint {
				case "/health":
					tr.handleHealth(w, req)
				case "/metrics":
					tr.handleMetrics(w, req)
				default:
					// Other endpoints expect specific HTTP methods
					// We just verify the handler chain setup
				}

				// Health and metrics should respond OK
				if endpoint == "/health" && method == "GET" {
					if w.Code != http.StatusOK {
						t.Errorf("Status = %d, want 200", w.Code)
					}
				}
				if endpoint == "/metrics" && method == "GET" {
					if w.Code != http.StatusOK {
						t.Errorf("Status = %d, want 200", w.Code)
					}
				}
			})
		}
	}
}

// =============================================================================
// Full HTTP Server Integration Tests - Tests the entire middleware chain
// =============================================================================

// TestAuthIntegration_FullServerWithAuth tests authentication using httptest.Server
// to verify the entire middleware chain (CORS -> Auth -> Rate Limit -> Handler).
func TestAuthIntegration_FullServerWithAuth(t *testing.T) {
	const apiKey = "integration-test-key-abc123"
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: apiKey,
	})

	// Create test server using the transport's HTTP handler
	ts := httptest.NewServer(tr.server.Handler)
	defer ts.Close()

	client := ts.Client()

	// Test 1: Valid auth on /message
	t.Run("valid auth on /message POST", func(t *testing.T) {
		req, _ := http.NewRequest("POST", ts.URL+"/message", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"test"}`))
		req.Header.Set("Authorization", "Bearer "+apiKey)
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		// Server may return various codes depending on handler setup,
		// but NOT 401 if auth succeeded
		if resp.StatusCode == http.StatusUnauthorized {
			body, _ := io.ReadAll(resp.Body)
			t.Errorf("Got 401 with valid auth: %s", body)
		}
	})

	// Test 2: Invalid auth on /message
	t.Run("invalid auth on /message POST", func(t *testing.T) {
		req, _ := http.NewRequest("POST", ts.URL+"/message", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"test"}`))
		req.Header.Set("Authorization", "Bearer wrong-key")
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401", resp.StatusCode)
		}
	})

	// Test 3: Missing auth on /message
	t.Run("missing auth on /message POST", func(t *testing.T) {
		req, _ := http.NewRequest("POST", ts.URL+"/message", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"test"}`))
		req.Header.Set("Content-Type", "application/json")
		// No Authorization header

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401", resp.StatusCode)
		}
	})

	// Test 4: Health endpoint without auth
	t.Run("health without auth", func(t *testing.T) {
		resp, err := client.Get(ts.URL + "/health")
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Errorf("Status = %d, want 200 (health is exempt)", resp.StatusCode)
		}
	})

	// Test 5: Metrics endpoint requires auth
	t.Run("metrics without auth", func(t *testing.T) {
		resp, err := client.Get(ts.URL + "/metrics")
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401", resp.StatusCode)
		}
	})

	// Test 6: Metrics endpoint with valid auth
	t.Run("metrics with valid auth", func(t *testing.T) {
		req, _ := http.NewRequest("GET", ts.URL+"/metrics", nil)
		req.Header.Set("Authorization", "Bearer "+apiKey)

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Errorf("Status = %d, want 200", resp.StatusCode)
		}
	})

	// Test 7: SSE events endpoint requires auth
	t.Run("events without auth", func(t *testing.T) {
		resp, err := client.Get(ts.URL + "/events")
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401", resp.StatusCode)
		}
	})
}

// TestAuthIntegration_FullServerWithoutAuth tests that without APIKey configured,
// all endpoints are accessible without authentication.
func TestAuthIntegration_FullServerWithoutAuth(t *testing.T) {
	// No APIKey configured
	tr := NewHTTPTransport(&HTTPTransportConfig{})

	ts := httptest.NewServer(tr.server.Handler)
	defer ts.Close()

	client := ts.Client()

	// All endpoints should be accessible without auth
	endpoints := []struct {
		method string
		path   string
	}{
		{"GET", "/health"},
		{"GET", "/metrics"},
		// Note: /message requires POST, /events requires GET
		// but we're testing auth bypass, not endpoint behavior
	}

	for _, ep := range endpoints {
		t.Run(ep.method+" "+ep.path, func(t *testing.T) {
			req, _ := http.NewRequest(ep.method, ts.URL+ep.path, nil)
			// No Authorization header

			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("Request failed: %v", err)
			}
			defer resp.Body.Close()

			// Should NOT be 401 - no auth required
			if resp.StatusCode == http.StatusUnauthorized {
				t.Errorf("Got 401 but auth should not be required")
			}
		})
	}
}

// TestAuthIntegration_CORSWithAuth verifies that CORS preflight with auth enabled.
// Note: The current middleware chain is: RateLimit -> Auth -> CORS -> mux,
// which means Auth checks run BEFORE CORS. This is intentional for security:
// auth is enforced on all endpoints (except explicitly exempted ones like /health).
// CORS preflight (OPTIONS) requests WITHOUT auth will be rejected with 401.
// Clients must include valid Authorization headers even in preflight requests,
// OR the server should exempt OPTIONS from auth. Current behavior: auth required.
func TestAuthIntegration_CORSWithAuth(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey:     "test-key",
		CORSOrigin: "https://allowed.example.com",
	})

	ts := httptest.NewServer(tr.server.Handler)
	defer ts.Close()

	client := ts.Client()

	// Test 1: OPTIONS preflight WITHOUT auth - rejected because auth middleware runs first
	t.Run("OPTIONS without auth - rejected", func(t *testing.T) {
		req, _ := http.NewRequest("OPTIONS", ts.URL+"/message", nil)
		req.Header.Set("Origin", "https://allowed.example.com")
		req.Header.Set("Access-Control-Request-Method", "POST")
		req.Header.Set("Access-Control-Request-Headers", "Authorization, Content-Type")

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		// Auth runs before CORS, so OPTIONS without auth gets 401
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("Status = %d, want 401 (auth runs before CORS)", resp.StatusCode)
		}
	})

	// Test 2: OPTIONS preflight WITH auth - CORS works
	t.Run("OPTIONS with auth - CORS works", func(t *testing.T) {
		req, _ := http.NewRequest("OPTIONS", ts.URL+"/message", nil)
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Origin", "https://allowed.example.com")
		req.Header.Set("Access-Control-Request-Method", "POST")
		req.Header.Set("Access-Control-Request-Headers", "Authorization, Content-Type")

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		// With valid auth, request passes through to CORS middleware
		if resp.StatusCode != http.StatusNoContent {
			t.Errorf("Status = %d, want 204 for CORS preflight with auth", resp.StatusCode)
		}

		// Verify CORS headers are present
		if v := resp.Header.Get("Access-Control-Allow-Origin"); v != "https://allowed.example.com" {
			t.Errorf("Access-Control-Allow-Origin = %q, want 'https://allowed.example.com'", v)
		}
		if v := resp.Header.Get("Access-Control-Allow-Headers"); !strings.Contains(v, "Authorization") {
			t.Errorf("Access-Control-Allow-Headers = %q, should include 'Authorization'", v)
		}
	})

	// Test 3: OPTIONS on /health - exempt from auth
	t.Run("OPTIONS on health - exempt from auth", func(t *testing.T) {
		req, _ := http.NewRequest("OPTIONS", ts.URL+"/health", nil)
		req.Header.Set("Origin", "https://allowed.example.com")
		req.Header.Set("Access-Control-Request-Method", "GET")

		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		defer resp.Body.Close()

		// /health is exempt from auth, so OPTIONS works
		if resp.StatusCode != http.StatusNoContent {
			t.Errorf("Status = %d, want 204 for CORS preflight on /health", resp.StatusCode)
		}
	})
}

// TestAuthMiddleware_ConstantTimeComparison verifies the auth uses constant-time
// comparison by checking that timing is consistent (best-effort test).
// This is more of a sanity check than a rigorous timing attack test.
func TestAuthMiddleware_ConstantTimeComparison(t *testing.T) {
	const apiKey = "secret-key-for-timing-test"
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: apiKey,
	})

	handler := tr.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	// Test various keys - all should fail in similar time
	// (We can't truly verify constant-time here, but we verify the logic works)
	keys := []string{
		"a",                                // Much shorter
		"secret-key-for-timing-tesX",       // One char different at end
		"Xecret-key-for-timing-test",       // One char different at start
		"secret-key-for-timing-test-extra", // Longer
		"completely-different-key",         // Totally different
	}

	for _, key := range keys {
		t.Run("key="+key, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/message", nil)
			req.Header.Set("Authorization", "Bearer "+key)
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("Status = %d, want 401 for wrong key", w.Code)
			}
		})
	}
}

// TestAuthMiddleware_EmptyAPIKey verifies behavior when APIKey is explicitly empty string.
func TestAuthMiddleware_EmptyAPIKey(t *testing.T) {
	tr := NewHTTPTransport(&HTTPTransportConfig{
		APIKey: "", // Explicitly empty
	})

	if tr.IsAuthEnabled() {
		t.Error("IsAuthEnabled() = true, want false when APIKey is empty")
	}
}
