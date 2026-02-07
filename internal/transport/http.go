// Copyright 2025 Joseph Cumines
//
// HTTP/SSE transport for JSON-RPC 2.0 communication

package transport

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// HTTP transport constants
const (
	// maxEventStoreSize is the maximum number of events to retain for reconnection replay.
	maxEventStoreSize = 1000
	// sseClientBufferSize is the buffer size for SSE client response channels.
	sseClientBufferSize = 100
	// serverShutdownTimeout is the timeout for graceful HTTP server shutdown.
	serverShutdownTimeout = 5 * time.Second
)

// HTTPTransportConfig holds configuration for HTTP transport.
// Address is the HTTP server address (e.g., ":8080" or "localhost:8080").
// SocketPath is an optional Unix domain socket path (takes precedence over Address).
// CORSOrigin is the allowed CORS origin (default: "*").
// HeartbeatInterval is the interval for SSE heartbeat pings (default: 15s).
// ReadTimeout for HTTP server (default: 30s).
// WriteTimeout for HTTP server (default: 0 = disabled for SSE compatibility).
// Note: WriteTimeout is disabled by default because SSE streams require long-lived connections.
// TLSCertFile is the path to the TLS certificate file (optional, enables TLS if set).
// TLSKeyFile is the path to the TLS private key file (optional, required if TLSCertFile is set).
// APIKey is the API key for Bearer token authentication (optional, no auth if empty).
// RateLimit is the rate limit in requests per second (0 = disabled).
type HTTPTransportConfig struct {
	Address           string
	SocketPath        string
	CORSOrigin        string
	TLSCertFile       string
	TLSKeyFile        string
	APIKey            string
	HeartbeatInterval time.Duration
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
	RateLimit         float64
}

// DefaultHTTPConfig returns the default HTTP transport configuration.
// Address defaults to ":8080", heartbeat interval to 15 seconds,
// CORS allows all origins, and read timeout is 30 seconds.
func DefaultHTTPConfig() *HTTPTransportConfig {
	return &HTTPTransportConfig{
		Address:           ":8080",
		HeartbeatInterval: 15 * time.Second,
		CORSOrigin:        "*",
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0, // Disabled for SSE compatibility
	}
}

// HTTPTransport implements HTTP/SSE transport for MCP.
// It provides POST /message for JSON-RPC requests, GET /events for SSE streaming,
// GET /health for server health checks, and GET /metrics for Prometheus-style metrics.
// This is a non-standard MCP transport extension documented in docs/05-mcp-integration.md.
type HTTPTransport struct {
	config      *HTTPTransportConfig
	server      *http.Server
	handler     func(*Message) (*Message, error)
	clients     *ClientRegistry
	metrics     *MetricsRegistry
	rateLimiter *RateLimiter
	shutdownCh  chan struct{}
	eventID     atomic.Uint64
	closed      atomic.Bool
}

// ClientRegistry manages connected SSE clients and event distribution.
// It maintains a thread-safe registry of clients and an event store for
// reconnection handling via Last-Event-ID.
type ClientRegistry struct {
	clients    map[string]*SSEClient
	eventStore *EventStore
	mu         sync.RWMutex
	nextID     atomic.Uint64
}

// SSEClient represents a connected SSE client with its event channel.
// The ResponseChan is buffered to prevent blocking on slow clients.
type SSEClient struct {
	ResponseChan chan *SSEEvent
	CreatedAt    time.Time
	ID           string
	LastEventID  string
}

// SSEEvent represents a Server-Sent Event with optional id, event type, and data.
// The ID is used for reconnection handling via Last-Event-ID header.
type SSEEvent struct {
	ID    string
	Event string
	Data  string
}

// EventStore stores recent events for reconnection handling.
// When a client reconnects with Last-Event-ID, missed events can be replayed.
type EventStore struct {
	eventMap map[string]*SSEEvent
	events   []*SSEEvent
	mu       sync.RWMutex
	maxSize  int
}

// NewEventStore creates a new event store with the specified maximum capacity.
// When the store is full, the oldest events are discarded to make room for new ones.
func NewEventStore(maxSize int) *EventStore {
	return &EventStore{
		events:   make([]*SSEEvent, 0, maxSize),
		maxSize:  maxSize,
		eventMap: make(map[string]*SSEEvent),
	}
}

// Add adds an event to the store. If the store is at capacity,
// the oldest event is removed to make room for the new event.
func (s *EventStore) Add(event *SSEEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if len(s.events) >= s.maxSize {
		// Remove oldest
		oldest := s.events[0]
		delete(s.eventMap, oldest.ID)
		s.events = s.events[1:]
	}
	s.events = append(s.events, event)
	s.eventMap[event.ID] = event
}

// GetSince returns all events that occurred after the event with the given ID.
// If lastEventID is empty or not found, returns nil (no replay).
// This is used for SSE reconnection replay via the Last-Event-ID header.
func (s *EventStore) GetSince(lastEventID string) []*SSEEvent {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if lastEventID == "" {
		return nil
	}

	found := false
	var result []*SSEEvent
	for _, e := range s.events {
		if found {
			result = append(result, e)
		}
		if e.ID == lastEventID {
			found = true
		}
	}
	return result
}

// NewClientRegistry creates a new client registry with an internal event store
// for replay support. The registry manages SSE client connections and event broadcasting.
func NewClientRegistry() *ClientRegistry {
	return &ClientRegistry{
		clients:    make(map[string]*SSEClient),
		eventStore: NewEventStore(maxEventStoreSize),
	}
}

// Add adds a new SSE client to the registry and returns the client handle.
// The lastEventID is used for potential event replay on reconnection.
// The client's ResponseChan receives events broadcast to all clients.
func (r *ClientRegistry) Add(lastEventID string) *SSEClient {
	r.mu.Lock()
	defer r.mu.Unlock()

	id := fmt.Sprintf("client-%d", r.nextID.Add(1))
	client := &SSEClient{
		ID:           id,
		ResponseChan: make(chan *SSEEvent, sseClientBufferSize),
		CreatedAt:    time.Now(),
		LastEventID:  lastEventID,
	}
	r.clients[id] = client
	return client
}

// Remove removes a client from the registry and closes its event channel.
// Safe to call multiple times; subsequent calls are no-ops.
func (r *ClientRegistry) Remove(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if client, ok := r.clients[id]; ok {
		close(client.ResponseChan)
		delete(r.clients, id)
	}
}

// Get returns a client by ID, or (nil, false) if not found.
func (r *ClientRegistry) Get(id string) (*SSEClient, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	client, ok := r.clients[id]
	return client, ok
}

// Broadcast sends an event to all connected clients via their ResponseChan.
// Events are also stored in the event store for replay on reconnection.
// If a client's buffer is full, the event is dropped for that client with a warning log.
func (r *ClientRegistry) Broadcast(event *SSEEvent) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	r.eventStore.Add(event)

	for _, client := range r.clients {
		select {
		case client.ResponseChan <- event:
		default:
			// Client buffer full, event will be lost for this client
			log.Printf("Warning: dropping event %s for client %s (buffer full)", event.ID, client.ID)
		}
	}
}

// Count returns the current number of connected SSE clients.
func (r *ClientRegistry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.clients)
}

// NewHTTPTransport creates a new HTTP/SSE transport with the given configuration.
// If config is nil, default configuration is used. The transport sets up routes
// for /message, /events, /health, and /metrics endpoints.
func NewHTTPTransport(config *HTTPTransportConfig) *HTTPTransport {
	if config == nil {
		config = DefaultHTTPConfig()
	}
	if config.HeartbeatInterval == 0 {
		config.HeartbeatInterval = 15 * time.Second
	}
	if config.CORSOrigin == "" {
		config.CORSOrigin = "*"
	}
	if config.ReadTimeout == 0 {
		config.ReadTimeout = 30 * time.Second
	}
	// Note: WriteTimeout defaults to 0 (disabled) for SSE compatibility.
	// SSE streams require long-lived connections, so we don't force a default.

	t := &HTTPTransport{
		config:      config,
		clients:     NewClientRegistry(),
		metrics:     NewMetricsRegistry(),
		rateLimiter: NewRateLimiter(config.RateLimit),
		shutdownCh:  make(chan struct{}),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/message", t.handleMessage)
	mux.HandleFunc("/events", t.handleSSE)
	mux.HandleFunc("/health", t.handleHealth)
	mux.HandleFunc("/metrics", t.handleMetrics)

	// Build middleware chain: CORS wrapper -> Auth wrapper -> Rate limit wrapper -> mux
	var handler http.Handler = mux
	handler = t.corsMiddleware(handler)
	if config.APIKey != "" {
		handler = t.authMiddleware(handler)
	}
	if t.rateLimiter != nil {
		handler = RateLimitMiddleware(t.rateLimiter, handler)
	}

	t.server = &http.Server{
		Handler:      handler,
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
	}

	return t
}

// corsMiddleware adds CORS headers to all responses
func (t *HTTPTransport) corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", t.config.CORSOrigin)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Last-Event-ID, Authorization")
		w.Header().Set("Access-Control-Expose-Headers", "Content-Type")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// authMiddleware validates Bearer token authentication.
// If the APIKey is configured, requests must include a valid Authorization header.
// The /health endpoint is exempt from authentication for load balancer health checks.
func (t *HTTPTransport) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health check endpoint is exempt from authentication
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}

		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, "Authorization header required", http.StatusUnauthorized)
			return
		}

		// Expect "Bearer <token>" format
		const bearerPrefix = "Bearer "
		if !strings.HasPrefix(authHeader, bearerPrefix) {
			http.Error(w, "Invalid authorization format, expected Bearer token", http.StatusUnauthorized)
			return
		}

		token := strings.TrimPrefix(authHeader, bearerPrefix)
		// Use constant-time comparison to prevent timing attacks
		if subtle.ConstantTimeCompare([]byte(token), []byte(t.config.APIKey)) != 1 {
			http.Error(w, "Invalid API key", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// handleMessage handles POST /message for JSON-RPC requests
func (t *HTTPTransport) handleMessage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var msg Message
	if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
		http.Error(w, fmt.Sprintf("Invalid JSON: %v", err), http.StatusBadRequest)
		return
	}

	if t.handler == nil {
		http.Error(w, "Handler not set", http.StatusInternalServerError)
		return
	}

	response, err := t.handler(&msg)
	if err != nil {
		response = &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &ErrorObj{
				Code:    ErrCodeInternalError,
				Message: err.Error(),
			},
		}
	}

	// JSON-RPC 2.0 notifications have no response; return 204 No Content.
	if response == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding response: %v", err)
	}

	// Also broadcast the response as an SSE event for streaming clients
	if response != nil {
		eventData, err := json.Marshal(response)
		if err != nil {
			log.Printf("Error marshaling SSE event data: %v", err)
		} else {
			t.clients.Broadcast(&SSEEvent{
				ID:    fmt.Sprintf("%d", t.eventID.Add(1)),
				Event: "message",
				Data:  string(eventData),
			})
			t.metrics.RecordSSEEvent()
		}
	}
}

// handleSSE handles GET /events for SSE streaming
func (t *HTTPTransport) handleSSE(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	// Handle Last-Event-ID for reconnection
	lastEventID := r.Header.Get("Last-Event-ID")

	client := t.clients.Add(lastEventID)
	defer func() {
		t.clients.Remove(client.ID)
		t.metrics.SetSSEConnections(t.clients.Count())
	}()

	// Update active connection count
	t.metrics.SetSSEConnections(t.clients.Count())

	log.Printf("SSE client connected: %s", client.ID)

	// Send any missed events if reconnecting
	if lastEventID != "" {
		missedEvents := t.clients.eventStore.GetSince(lastEventID)
		for _, event := range missedEvents {
			if err := writeSSEEvent(w, event); err != nil {
				log.Printf("SSE client %s: write error during reconnect replay: %v", client.ID, err)
				return
			}
		}
		flusher.Flush()
	}

	// Start heartbeat
	heartbeatTicker := time.NewTicker(t.config.HeartbeatInterval)
	defer heartbeatTicker.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			log.Printf("SSE client disconnected: %s", client.ID)
			return
		case <-t.shutdownCh:
			fmt.Fprintf(w, "event: complete\ndata: server shutdown\n\n")
			flusher.Flush()
			return
		case <-heartbeatTicker.C:
			// Send heartbeat
			if _, err := fmt.Fprintf(w, ": heartbeat\n\n"); err != nil {
				log.Printf("SSE client %s: heartbeat write error: %v", client.ID, err)
				return
			}
			flusher.Flush()
		case event, ok := <-client.ResponseChan:
			if !ok {
				return
			}
			if err := writeSSEEvent(w, event); err != nil {
				log.Printf("SSE client %s: write error: %v", client.ID, err)
				return
			}
			flusher.Flush()
		}
	}
}

// writeSSEEvent writes an SSE event to the writer, properly handling multiline data.
// Returns an error if writing fails (e.g., client disconnected).
func writeSSEEvent(w io.Writer, event *SSEEvent) error {
	if _, err := fmt.Fprintf(w, "id: %s\n", event.ID); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "event: %s\n", event.Event); err != nil {
		return err
	}
	// SSE spec: each line of data must be prefixed with "data:"
	for _, line := range strings.Split(event.Data, "\n") {
		if _, err := fmt.Fprintf(w, "data: %s\n", line); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprint(w, "\n"); err != nil {
		return err
	}
	return nil
}

// handleHealth handles GET /health for health checks
func (t *HTTPTransport) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"clients":     t.clients.Count(),
		"server_time": time.Now().UTC().Format(time.RFC3339),
	}); err != nil {
		log.Printf("Error encoding health response: %v", err)
	}
}

// handleMetrics handles GET /metrics for Prometheus-style metrics exposition.
// Exposes mcp_requests_total, mcp_request_duration_seconds, mcp_sse_connections_active,
// and mcp_sse_events_sent_total in Prometheus text format.
func (t *HTTPTransport) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	if err := t.metrics.WritePrometheus(w); err != nil {
		log.Printf("Error writing metrics: %v", err)
	}
}

// Serve starts the HTTP server and handles messages.
// If TLSCertFile and TLSKeyFile are configured, the server uses TLS.
// Otherwise, it serves plain HTTP.
func (t *HTTPTransport) Serve(handler func(*Message) (*Message, error)) error {
	t.handler = handler

	var listener net.Listener
	var err error

	if t.config.SocketPath != "" {
		// Use Unix domain socket - remove stale socket file if it exists
		if err := os.Remove(t.config.SocketPath); err != nil && !os.IsNotExist(err) {
			log.Printf("Warning: failed to remove stale socket %s: %v", t.config.SocketPath, err)
		}
		listener, err = net.Listen("unix", t.config.SocketPath)
		if err != nil {
			return fmt.Errorf("failed to listen on socket %s: %w", t.config.SocketPath, err)
		}
		log.Printf("HTTP/SSE transport listening on unix:%s", t.config.SocketPath)
	} else {
		// Use TCP
		listener, err = net.Listen("tcp", t.config.Address)
		if err != nil {
			return fmt.Errorf("failed to listen on %s: %w", t.config.Address, err)
		}
		log.Printf("HTTP/SSE transport listening on %s", t.config.Address)
	}

	// If TLS is configured, wrap the listener with TLS
	if t.config.TLSCertFile != "" && t.config.TLSKeyFile != "" {
		cert, err := tls.LoadX509KeyPair(t.config.TLSCertFile, t.config.TLSKeyFile)
		if err != nil {
			return fmt.Errorf("failed to load TLS certificate: %w", err)
		}
		tlsConfig := &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
		listener = tls.NewListener(listener, tlsConfig)
		log.Printf("TLS enabled with certificate: %s", t.config.TLSCertFile)
	}

	if err := t.server.Serve(listener); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// IsTLSEnabled returns true if TLS is configured for this transport.
func (t *HTTPTransport) IsTLSEnabled() bool {
	return t.config.TLSCertFile != "" && t.config.TLSKeyFile != ""
}

// IsAuthEnabled returns true if API key authentication is configured.
func (t *HTTPTransport) IsAuthEnabled() bool {
	return t.config.APIKey != ""
}

// Metrics returns the metrics registry for this transport.
// This allows the MCP server to record request metrics for tool invocations.
func (t *HTTPTransport) Metrics() *MetricsRegistry {
	return t.metrics
}

// IsRateLimitEnabled returns true if rate limiting is configured.
func (t *HTTPTransport) IsRateLimitEnabled() bool {
	return t.rateLimiter != nil
}

// ReadMessage is provided for Transport interface compatibility but is not the
// primary message handling pattern for HTTPTransport. The HTTP transport uses
// the callback-based Serve(handler) pattern instead, where messages are delivered
// directly to the handler function. This method returns immediately with an error
// explaining the correct usage pattern.
func (t *HTTPTransport) ReadMessage() (*Message, error) {
	// HTTP transport uses callback pattern via Serve(handler).
	// Return immediately with a clear error rather than blocking.
	return nil, fmt.Errorf("ReadMessage is not supported by HTTPTransport: use Serve(handler) callback pattern instead")
}

// WriteMessage broadcasts a message to all connected SSE clients.
// The message is serialized to JSON and sent as an SSE event.
func (t *HTTPTransport) WriteMessage(msg *Message) error {
	if t.closed.Load() {
		return fmt.Errorf("transport is closed")
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}

	t.clients.Broadcast(&SSEEvent{
		ID:    fmt.Sprintf("%d", t.eventID.Add(1)),
		Event: "message",
		Data:  string(data),
	})
	t.metrics.RecordSSEEvent()

	return nil
}

// Close closes the HTTP transport and shuts down the server gracefully.
// It signals all SSE clients and waits up to 5 seconds for cleanup.
func (t *HTTPTransport) Close() error {
	if t.closed.Swap(true) {
		return nil
	}

	close(t.shutdownCh)

	ctx, cancel := context.WithTimeout(context.Background(), serverShutdownTimeout)
	defer cancel()

	if err := t.server.Shutdown(ctx); err != nil {
		return fmt.Errorf("failed to shutdown server: %w", err)
	}

	// Clean up Unix socket file if we were using one
	if t.config.SocketPath != "" {
		if err := os.Remove(t.config.SocketPath); err != nil && !os.IsNotExist(err) {
			log.Printf("Warning: failed to remove socket file %s: %v", t.config.SocketPath, err)
		}
	}

	return nil
}

// IsClosed returns true if the transport has been closed.
func (t *HTTPTransport) IsClosed() bool {
	return t.closed.Load()
}

// Ensure HTTPTransport implements Transport interface
var _ Transport = (*HTTPTransport)(nil)
