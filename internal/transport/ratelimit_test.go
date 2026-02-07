// Copyright 2025 Joseph Cumines
//
// Rate limiter unit tests

package transport

import (
	"net/http"
	"net/http/httptest"
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
