// Copyright 2025 Joseph Cumines
//
// Token bucket rate limiter for HTTP transport

package transport

import (
	"net/http"
	"sync"
	"time"
)

// RateLimiter implements a token bucket rate limiting algorithm.
// It provides thread-safe rate limiting with configurable requests per second.
// When the bucket is empty, requests are rejected with HTTP 429 Too Many Requests.
type RateLimiter struct {
	clock      func() time.Time // injectable clock for testing
	lastUpdate time.Time        // last time tokens were refilled
	rate       float64          // tokens added per second
	burst      float64          // maximum bucket capacity
	tokens     float64          // current available tokens
	mu         sync.Mutex       // protects all fields
}

// NewRateLimiter creates a new rate limiter with the specified rate.
// The rate is in requests per second. The burst size is set to 2x the rate.
// Returns nil if rate is 0 or negative (disabling rate limiting).
func NewRateLimiter(requestsPerSecond float64) *RateLimiter {
	if requestsPerSecond <= 0 {
		return nil
	}
	burst := requestsPerSecond * 2
	if burst < 1 {
		burst = 1
	}
	return &RateLimiter{
		rate:       requestsPerSecond,
		burst:      burst,
		tokens:     burst, // start with full bucket
		lastUpdate: time.Now(),
		clock:      time.Now,
	}
}

// NewRateLimiterWithClock creates a rate limiter with an injectable clock.
// This is primarily used for testing to control time progression.
func NewRateLimiterWithClock(requestsPerSecond float64, clock func() time.Time) *RateLimiter {
	if requestsPerSecond <= 0 {
		return nil
	}
	burst := requestsPerSecond * 2
	if burst < 1 {
		burst = 1
	}
	now := clock()
	return &RateLimiter{
		rate:       requestsPerSecond,
		burst:      burst,
		tokens:     burst,
		lastUpdate: now,
		clock:      clock,
	}
}

// Allow checks if a request should be allowed and consumes a token if so.
// Returns true if allowed, false if rate limited. Thread-safe.
func (r *RateLimiter) Allow() bool {
	if r == nil {
		return true // nil limiter means no rate limiting
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.clock()
	elapsed := now.Sub(r.lastUpdate).Seconds()

	// Refill tokens based on elapsed time
	r.tokens += elapsed * r.rate
	if r.tokens > r.burst {
		r.tokens = r.burst
	}
	r.lastUpdate = now

	if r.tokens < 1 {
		return false // no tokens available
	}

	r.tokens--
	return true
}

// Tokens returns the current number of available tokens.
// Returns -1 if the limiter is nil (disabled). Used for testing and monitoring.
func (r *RateLimiter) Tokens() float64 {
	if r == nil {
		return -1 // indicates disabled
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tokens
}

// RateLimitMiddleware creates HTTP middleware that applies rate limiting.
// The /health and /metrics endpoints are exempt. Returns 429 when rate limited.
// If limiter is nil, the middleware is a passthrough.
func RateLimitMiddleware(limiter *RateLimiter, next http.Handler) http.Handler {
	if limiter == nil {
		return next // no rate limiting
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health endpoint is exempt from rate limiting for load balancer health checks
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}

		// Metrics endpoint is exempt from rate limiting for monitoring
		if r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}

		if !limiter.Allow() {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
			return
		}

		next.ServeHTTP(w, r)
	})
}
