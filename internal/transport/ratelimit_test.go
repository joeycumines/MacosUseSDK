// Copyright 2025 Joseph Cumines
//
// Rate limiter unit tests

package transport

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewRateLimiter(t *testing.T) {
	tests := []struct {
		name string
		rate float64
		want bool // true = enabled, false = disabled (nil)
	}{
		{"positive rate", 10.0, true},
		{"zero rate", 0, false},
		{"negative rate", -1, false},
		{"small positive rate", 0.5, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := NewRateLimiter(tt.rate)
			if tt.want && rl == nil {
				t.Error("Expected limiter to be enabled (non-nil)")
			}
			if !tt.want && rl != nil {
				t.Error("Expected limiter to be disabled (nil)")
			}
		})
	}
}

func TestRateLimiter_Allow_NilLimiter(t *testing.T) {
	var rl *RateLimiter = nil
	if !rl.Allow() {
		t.Error("Nil limiter should always allow")
	}
}

func TestRateLimiter_Allow_WithTestClock(t *testing.T) {
	// Use a test clock for deterministic testing (no timing dependencies)
	var now time.Time
	now = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	rl := NewRateLimiterWithClock(2.0, clock) // 2 req/s, burst = 4

	// Initial burst should be allowed (burst = 4)
	for i := 0; i < 4; i++ {
		if !rl.Allow() {
			t.Errorf("Request %d should be allowed (within burst)", i+1)
		}
	}

	// Next request should be rejected (bucket exhausted)
	if rl.Allow() {
		t.Error("Request 5 should be rejected (bucket exhausted)")
	}

	// Advance time by 1 second (refill 2 tokens)
	now = now.Add(1 * time.Second)

	// Should allow 2 more requests
	if !rl.Allow() {
		t.Error("Request after 1s should be allowed (2 tokens refilled)")
	}
	if !rl.Allow() {
		t.Error("Second request after 1s should be allowed")
	}

	// Third should be rejected
	if rl.Allow() {
		t.Error("Third request after 1s should be rejected")
	}
}

func TestRateLimiter_Tokens(t *testing.T) {
	var rl *RateLimiter = nil
	if rl.Tokens() != -1 {
		t.Errorf("Nil limiter Tokens() = %f, want -1", rl.Tokens())
	}

	rl = NewRateLimiter(10.0) // burst = 20
	tokens := rl.Tokens()
	if tokens < 19 || tokens > 20 {
		t.Errorf("Initial tokens = %f, want ~20 (burst)", tokens)
	}
}

func TestRateLimiter_ConcurrentAccess(t *testing.T) {
	// Create a limiter with high rate for concurrent test
	rl := NewRateLimiter(1000.0) // 1000 req/s, burst = 2000

	var allowed atomic.Int64
	var rejected atomic.Int64

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				if rl.Allow() {
					allowed.Add(1)
				} else {
					rejected.Add(1)
				}
			}
		}()
	}
	wg.Wait()

	total := allowed.Load() + rejected.Load()
	if total != 1000 {
		t.Errorf("Total requests = %d, want 1000", total)
	}

	// Most should be allowed with such high rate
	if allowed.Load() < 500 {
		t.Errorf("Expected most requests to be allowed, got allowed=%d, rejected=%d", allowed.Load(), rejected.Load())
	}
}

func TestRateLimitMiddleware_NilLimiter(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	middleware := RateLimitMiddleware(nil, handler)

	req := httptest.NewRequest("GET", "/message", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Status = %d, want 200 (nil limiter should pass through)", w.Code)
	}
}

func TestRateLimitMiddleware_HealthExempt(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// Create a very restrictive limiter (0.001 req/s = 1 request per 1000 seconds)
	rl := NewRateLimiterWithClock(0.001, clock)

	// Exhaust the tiny bucket
	for i := 0; i < 10; i++ {
		rl.Allow()
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	middleware := RateLimitMiddleware(rl, handler)

	// Health should still work
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Health status = %d, want 200 (exempt from rate limiting)", w.Code)
	}
}

func TestRateLimitMiddleware_MetricsExempt(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// Create a very restrictive limiter
	rl := NewRateLimiterWithClock(0.001, clock)

	// Exhaust the bucket
	for i := 0; i < 10; i++ {
		rl.Allow()
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	middleware := RateLimitMiddleware(rl, handler)

	// Metrics should still work
	req := httptest.NewRequest("GET", "/metrics", nil)
	w := httptest.NewRecorder()
	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Metrics status = %d, want 200 (exempt from rate limiting)", w.Code)
	}
}

func TestRateLimitMiddleware_RateLimited(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// Create a limiter with small burst
	rl := NewRateLimiterWithClock(1.0, clock) // 1 req/s, burst = 2

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	middleware := RateLimitMiddleware(rl, handler)

	// First 2 requests should succeed (burst)
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("POST", "/message", nil)
		w := httptest.NewRecorder()
		middleware.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("Request %d status = %d, want 200", i+1, w.Code)
		}
	}

	// Third request should be rate limited
	req := httptest.NewRequest("POST", "/message", nil)
	w := httptest.NewRecorder()
	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Errorf("Rate limited status = %d, want 429", w.Code)
	}

	retryAfter := w.Header().Get("Retry-After")
	if retryAfter == "" {
		t.Error("Expected Retry-After header on 429 response")
	}
}

func TestRateLimiter_BurstCalculation(t *testing.T) {
	tests := []struct {
		name          string
		rate          float64
		expectedBurst float64
	}{
		{"rate 10", 10.0, 20.0},
		{"rate 0.25", 0.25, 1.0}, // 0.5 would be clamped to 1
		{"rate 100", 100.0, 200.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := NewRateLimiter(tt.rate)
			if rl == nil {
				t.Fatal("Expected non-nil limiter")
			}
			if rl.burst != tt.expectedBurst {
				t.Errorf("burst = %f, want %f", rl.burst, tt.expectedBurst)
			}
		})
	}
}

// -----------------------------------------------------------------------------
// Task 42: Expanded Rate Limiting Tests
// -----------------------------------------------------------------------------

// TestRateLimiter_RequestsWithinLimitPass verifies that requests within the
// configured limit all succeed without being rejected.
func TestRateLimiter_RequestsWithinLimitPass(t *testing.T) {
	tests := []struct {
		name     string
		rate     float64
		requests int // number of requests to send (must be <= burst)
		wantPass int // expected number of allowed requests
	}{
		{
			name:     "all requests within burst succeed",
			rate:     5.0,   // burst = 10
			requests: 10,    // exactly burst
			wantPass: 10,
		},
		{
			name:     "partial burst succeeds",
			rate:     10.0,  // burst = 20
			requests: 15,    // less than burst
			wantPass: 15,
		},
		{
			name:     "single request succeeds",
			rate:     1.0,   // burst = 2
			requests: 1,
			wantPass: 1,
		},
		{
			name:     "zero requests is trivially successful",
			rate:     5.0,
			requests: 0,
			wantPass: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
			clock := func() time.Time { return now }
			rl := NewRateLimiterWithClock(tt.rate, clock)

			passed := 0
			for i := 0; i < tt.requests; i++ {
				if rl.Allow() {
					passed++
				}
			}

			if passed != tt.wantPass {
				t.Errorf("passed = %d, want %d", passed, tt.wantPass)
			}
		})
	}
}

// TestRateLimiter_ExcessRequestsRejected verifies that excess requests beyond
// the burst capacity are rejected.
func TestRateLimiter_ExcessRequestsRejected(t *testing.T) {
	tests := []struct {
		name         string
		rate         float64
		requests     int
		wantRejected int
	}{
		{
			name:         "one excess request rejected",
			rate:         2.0,    // burst = 4
			requests:     5,
			wantRejected: 1,
		},
		{
			name:         "multiple excess requests rejected",
			rate:         3.0,    // burst = 6
			requests:     10,
			wantRejected: 4,
		},
		{
			name:         "double burst all excess rejected",
			rate:         5.0,    // burst = 10
			requests:     20,
			wantRejected: 10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
			clock := func() time.Time { return now }
			rl := NewRateLimiterWithClock(tt.rate, clock)

			rejected := 0
			for i := 0; i < tt.requests; i++ {
				if !rl.Allow() {
					rejected++
				}
			}

			if rejected != tt.wantRejected {
				t.Errorf("rejected = %d, want %d", rejected, tt.wantRejected)
			}
		})
	}
}

// TestRateLimitMiddleware_HTTP429OnExcess verifies that the middleware
// returns HTTP 429 Too Many Requests when the rate limit is exceeded.
func TestRateLimitMiddleware_HTTP429OnExcess(t *testing.T) {
	tests := []struct {
		name       string
		rate       float64
		requests   int
		want429    int
	}{
		{
			name:     "one 429 for one excess",
			rate:     1.0, // burst = 2
			requests: 3,
			want429:  1,
		},
		{
			name:     "two 429s for two excess",
			rate:     2.0, // burst = 4
			requests: 6,
			want429:  2,
		},
		{
			name:     "no 429 when within limit",
			rate:     5.0, // burst = 10
			requests: 10,
			want429:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
			clock := func() time.Time { return now }
			rl := NewRateLimiterWithClock(tt.rate, clock)

			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			})
			middleware := RateLimitMiddleware(rl, handler)

			got429 := 0
			for i := 0; i < tt.requests; i++ {
				req := httptest.NewRequest("GET", "/api/test", nil)
				w := httptest.NewRecorder()
				middleware.ServeHTTP(w, req)
				if w.Code == http.StatusTooManyRequests {
					got429++
				}
			}

			if got429 != tt.want429 {
				t.Errorf("got %d 429 responses, want %d", got429, tt.want429)
			}
		})
	}
}

// TestRateLimitMiddleware_RetryAfterHeaderPresent verifies that the Retry-After
// header is present on all 429 responses.
func TestRateLimitMiddleware_RetryAfterHeaderPresent(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rl := NewRateLimiterWithClock(1.0, clock) // burst = 2

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	middleware := RateLimitMiddleware(rl, handler)

	// Exhaust the burst
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("GET", "/api/test", nil)
		w := httptest.NewRecorder()
		middleware.ServeHTTP(w, req)
	}

	// Send multiple requests that should all be rate limited
	for i := 0; i < 5; i++ {
		req := httptest.NewRequest("GET", "/api/test", nil)
		w := httptest.NewRecorder()
		middleware.ServeHTTP(w, req)

		if w.Code != http.StatusTooManyRequests {
			t.Fatalf("Request %d: expected 429, got %d", i+1, w.Code)
		}

		retryAfter := w.Header().Get("Retry-After")
		if retryAfter == "" {
			t.Errorf("Request %d: Retry-After header missing on 429 response", i+1)
		}
	}
}

// TestRateLimitMiddleware_RetryAfterValue verifies the Retry-After header value.
// Note: The current implementation uses a hardcoded value of "1" second.
// This test documents the current behavior.
func TestRateLimitMiddleware_RetryAfterValue(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rl := NewRateLimiterWithClock(1.0, clock) // burst = 2

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	middleware := RateLimitMiddleware(rl, handler)

	// Exhaust the burst
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("GET", "/api/test", nil)
		w := httptest.NewRecorder()
		middleware.ServeHTTP(w, req)
	}

	// Send a rate-limited request
	req := httptest.NewRequest("GET", "/api/test", nil)
	w := httptest.NewRecorder()
	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("Expected 429, got %d", w.Code)
	}

	retryAfter := w.Header().Get("Retry-After")
	if retryAfter == "" {
		t.Fatal("Retry-After header missing")
	}

	// Parse the Retry-After value
	seconds, err := strconv.Atoi(retryAfter)
	if err != nil {
		t.Fatalf("Retry-After value %q is not a valid integer: %v", retryAfter, err)
	}

	// Current implementation hardcodes "1" - verify this behavior
	if seconds != 1 {
		t.Errorf("Retry-After = %d, want 1 (current hardcoded value)", seconds)
	}

	// Verify value is positive (basic sanity check)
	if seconds <= 0 {
		t.Errorf("Retry-After = %d, should be positive", seconds)
	}
}

// TestRateLimiter_ResetAfterWindow verifies that the rate limit resets
// after the refill window expires, allowing new requests to succeed.
func TestRateLimiter_ResetAfterWindow(t *testing.T) {
	var now time.Time
	now = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// 2 req/s, burst = 4
	rl := NewRateLimiterWithClock(2.0, clock)

	// Exhaust all tokens
	for i := 0; i < 4; i++ {
		if !rl.Allow() {
			t.Fatalf("Request %d should be allowed (within burst)", i+1)
		}
	}

	// Next request should be rejected
	if rl.Allow() {
		t.Error("Request 5 should be rejected (bucket exhausted)")
	}

	// Advance time by 2 seconds (refills 4 tokens = full bucket)
	now = now.Add(2 * time.Second)

	// Should now allow 4 more requests (full bucket refilled)
	for i := 0; i < 4; i++ {
		if !rl.Allow() {
			t.Errorf("Request %d after reset should be allowed", i+1)
		}
	}

	// Bucket exhausted again
	if rl.Allow() {
		t.Error("Request after re-exhaustion should be rejected")
	}
}

// TestRateLimiter_PartialRefill verifies that partial time windows
// refill a proportional number of tokens.
func TestRateLimiter_PartialRefill(t *testing.T) {
	var now time.Time
	now = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// 10 req/s, burst = 20
	rl := NewRateLimiterWithClock(10.0, clock)

	// Exhaust all 20 tokens
	for i := 0; i < 20; i++ {
		rl.Allow()
	}

	// Advance by 500ms (should refill 5 tokens)
	now = now.Add(500 * time.Millisecond)

	// Should allow exactly 5 requests
	allowed := 0
	for i := 0; i < 10; i++ {
		if rl.Allow() {
			allowed++
		}
	}

	if allowed != 5 {
		t.Errorf("After 500ms refill: allowed = %d, want 5", allowed)
	}
}

// TestRateLimitMiddleware_ResetAfterWindow verifies that the middleware
// allows requests again after the rate limit window expires.
func TestRateLimitMiddleware_ResetAfterWindow(t *testing.T) {
	var now time.Time
	now = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// 1 req/s, burst = 2
	rl := NewRateLimiterWithClock(1.0, clock)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("success"))
	})
	middleware := RateLimitMiddleware(rl, handler)

	// Exhaust burst
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("GET", "/api/test", nil)
		w := httptest.NewRecorder()
		middleware.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("Initial request %d: expected 200, got %d", i+1, w.Code)
		}
	}

	// Should get 429
	req := httptest.NewRequest("GET", "/api/test", nil)
	w := httptest.NewRecorder()
	middleware.ServeHTTP(w, req)
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("Expected 429, got %d", w.Code)
	}

	// Advance time by 2 seconds (refills 2 tokens = full bucket)
	now = now.Add(2 * time.Second)

	// Should succeed again
	req = httptest.NewRequest("GET", "/api/test", nil)
	w = httptest.NewRecorder()
	middleware.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("After window reset: expected 200, got %d", w.Code)
	}
}

// TestRateLimiter_ConcurrentAccessSafety verifies that the rate limiter
// handles concurrent access without data races or incorrect behavior.
// This test is designed to be run with -race flag.
func TestRateLimiter_ConcurrentAccessSafety(t *testing.T) {
	// Use real clock for realistic concurrent access testing
	rl := NewRateLimiter(10000.0) // 10000 req/s to minimize timing effects

	const goroutines = 50
	const requestsPerGoroutine = 100

	var allowed atomic.Int64
	var rejected atomic.Int64

	var wg sync.WaitGroup
	start := make(chan struct{}) // synchronize start

	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start // wait for signal
			for j := 0; j < requestsPerGoroutine; j++ {
				if rl.Allow() {
					allowed.Add(1)
				} else {
					rejected.Add(1)
				}
			}
		}()
	}

	close(start) // release all goroutines
	wg.Wait()

	total := allowed.Load() + rejected.Load()
	expected := int64(goroutines * requestsPerGoroutine)
	if total != expected {
		t.Errorf("Total requests = %d, want %d", total, expected)
	}

	// With high rate, most should be allowed
	if allowed.Load() < expected/2 {
		t.Errorf("Expected majority allowed, got allowed=%d, rejected=%d", allowed.Load(), rejected.Load())
	}
}

// TestRateLimitMiddleware_ConcurrentAccessSafety verifies that the middleware
// handles concurrent HTTP requests without data races.
// This test is designed to be run with -race flag.
func TestRateLimitMiddleware_ConcurrentAccessSafety(t *testing.T) {
	// Use real time for realistic testing
	rl := NewRateLimiter(10000.0) // 10000 req/s

	var handlerCalls atomic.Int64
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalls.Add(1)
		w.WriteHeader(http.StatusOK)
	})
	middleware := RateLimitMiddleware(rl, handler)

	const goroutines = 50
	const requestsPerGoroutine = 50

	var status200 atomic.Int64
	var status429 atomic.Int64

	var wg sync.WaitGroup
	start := make(chan struct{})

	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for j := 0; j < requestsPerGoroutine; j++ {
				req := httptest.NewRequest("GET", "/api/test", nil)
				w := httptest.NewRecorder()
				middleware.ServeHTTP(w, req)
				if w.Code == http.StatusOK {
					status200.Add(1)
				} else if w.Code == http.StatusTooManyRequests {
					status429.Add(1)
				}
			}
		}()
	}

	close(start)
	wg.Wait()

	total := status200.Load() + status429.Load()
	expected := int64(goroutines * requestsPerGoroutine)
	if total != expected {
		t.Errorf("Total responses = %d, want %d", total, expected)
	}

	// Verify handler was called for allowed requests
	if handlerCalls.Load() != status200.Load() {
		t.Errorf("Handler calls = %d, but got %d 200 responses", handlerCalls.Load(), status200.Load())
	}
}

// TestRateLimiter_ExactBurstBoundary verifies behavior at the exact
// burst boundary (edge case testing).
func TestRateLimiter_ExactBurstBoundary(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// 5 req/s, burst = 10
	rl := NewRateLimiterWithClock(5.0, clock)

	// Allow exactly burst requests
	for i := 0; i < 10; i++ {
		if !rl.Allow() {
			t.Errorf("Request %d should be allowed (within burst of 10)", i+1)
		}
	}

	// The 11th request should fail
	if rl.Allow() {
		t.Error("Request 11 should be rejected (beyond burst)")
	}
}

// TestRateLimiter_TokensAccuracy verifies that Tokens() returns accurate
// values before and after Allow() calls.
func TestRateLimiter_TokensAccuracy(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// 5 req/s, burst = 10
	rl := NewRateLimiterWithClock(5.0, clock)

	// Initial tokens should be burst
	if tokens := rl.Tokens(); tokens != 10 {
		t.Errorf("Initial tokens = %f, want 10", tokens)
	}

	// Consume one token
	rl.Allow()
	if tokens := rl.Tokens(); tokens != 9 {
		t.Errorf("After 1 Allow: tokens = %f, want 9", tokens)
	}

	// Consume 4 more
	for i := 0; i < 4; i++ {
		rl.Allow()
	}
	if tokens := rl.Tokens(); tokens != 5 {
		t.Errorf("After 5 Allow: tokens = %f, want 5", tokens)
	}
}

// TestRateLimitMiddleware_ExemptEndpointsWithConcurrentTraffic verifies that
// exempt endpoints remain accessible even under concurrent rate-limited traffic.
func TestRateLimitMiddleware_ExemptEndpointsWithConcurrentTraffic(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }

	// Very restrictive limiter
	rl := NewRateLimiterWithClock(0.001, clock) // 0.001 req/s, burst = 1

	// Exhaust the single token
	rl.Allow()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	middleware := RateLimitMiddleware(rl, handler)

	// Run concurrent requests to both exempt and non-exempt endpoints
	const goroutines = 20

	var healthOK, metricsOK, apiRateLimited atomic.Int64
	var wg sync.WaitGroup

	for i := 0; i < goroutines; i++ {
		wg.Add(3)

		// Health endpoint
		go func() {
			defer wg.Done()
			req := httptest.NewRequest("GET", "/health", nil)
			w := httptest.NewRecorder()
			middleware.ServeHTTP(w, req)
			if w.Code == http.StatusOK {
				healthOK.Add(1)
			}
		}()

		// Metrics endpoint
		go func() {
			defer wg.Done()
			req := httptest.NewRequest("GET", "/metrics", nil)
			w := httptest.NewRecorder()
			middleware.ServeHTTP(w, req)
			if w.Code == http.StatusOK {
				metricsOK.Add(1)
			}
		}()

		// API endpoint (should be rate limited)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest("GET", "/api/something", nil)
			w := httptest.NewRecorder()
			middleware.ServeHTTP(w, req)
			if w.Code == http.StatusTooManyRequests {
				apiRateLimited.Add(1)
			}
		}()
	}

	wg.Wait()

	// All health requests should succeed
	if healthOK.Load() != int64(goroutines) {
		t.Errorf("healthOK = %d, want %d (all should succeed)", healthOK.Load(), goroutines)
	}

	// All metrics requests should succeed
	if metricsOK.Load() != int64(goroutines) {
		t.Errorf("metricsOK = %d, want %d (all should succeed)", metricsOK.Load(), goroutines)
	}

	// All API requests should be rate limited
	if apiRateLimited.Load() != int64(goroutines) {
		t.Errorf("apiRateLimited = %d, want %d (all should be rate limited)", apiRateLimited.Load(), goroutines)
	}
}
