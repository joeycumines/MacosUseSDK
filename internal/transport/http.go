// Copyright 2025 Joseph Cumines
//
// HTTP/SSE transport for JSON-RPC 2.0 communication

package transport

import (
	"context"
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

// HTTPTransportConfig holds configuration for HTTP transport.
// Address is the HTTP server address (e.g., ":8080" or "localhost:8080").
// SocketPath is an optional Unix domain socket path (takes precedence over Address).
// CORSOrigin is the allowed CORS origin (default: "*").
// HeartbeatInterval is the interval for SSE heartbeat pings (default: 15s).
// ReadTimeout for HTTP server (default: 30s).
// WriteTimeout for HTTP server (default: 0 = disabled for SSE compatibility).
// Note: WriteTimeout is disabled by default because SSE streams require long-lived connections.
type HTTPTransportConfig struct {
	Address           string
	SocketPath        string
	CORSOrigin        string
	HeartbeatInterval time.Duration
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
}

// DefaultHTTPConfig returns default HTTP transport configuration
func DefaultHTTPConfig() *HTTPTransportConfig {
	return &HTTPTransportConfig{
		Address:           ":8080",
		HeartbeatInterval: 15 * time.Second,
		CORSOrigin:        "*",
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0, // Disabled for SSE compatibility
	}
}

// HTTPTransport implements HTTP/SSE transport for MCP
type HTTPTransport struct {
	config     *HTTPTransportConfig
	server     *http.Server
	handler    func(*Message) (*Message, error)
	clients    *ClientRegistry
	shutdownCh chan struct{}
	eventID    atomic.Uint64
	closed     atomic.Bool
}

// ClientRegistry manages connected SSE clients
type ClientRegistry struct {
	clients    map[string]*SSEClient
	eventStore *EventStore
	mu         sync.RWMutex
	nextID     atomic.Uint64
}

// SSEClient represents a connected SSE client
type SSEClient struct {
	ResponseChan chan *SSEEvent
	CreatedAt    time.Time
	ID           string
	LastEventID  string
}

// SSEEvent represents a Server-Sent Event
type SSEEvent struct {
	ID    string
	Event string
	Data  string
}

// EventStore stores recent events for reconnection handling
type EventStore struct {
	eventMap map[string]*SSEEvent
	events   []*SSEEvent
	mu       sync.RWMutex
	maxSize  int
}

// NewEventStore creates a new event store
func NewEventStore(maxSize int) *EventStore {
	return &EventStore{
		events:   make([]*SSEEvent, 0, maxSize),
		maxSize:  maxSize,
		eventMap: make(map[string]*SSEEvent),
	}
}

// Add adds an event to the store
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

// GetSince returns events since the given ID
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

// NewClientRegistry creates a new client registry
func NewClientRegistry() *ClientRegistry {
	return &ClientRegistry{
		clients:    make(map[string]*SSEClient),
		eventStore: NewEventStore(1000),
	}
}

// Add adds a client to the registry
func (r *ClientRegistry) Add(lastEventID string) *SSEClient {
	r.mu.Lock()
	defer r.mu.Unlock()

	id := fmt.Sprintf("client-%d", r.nextID.Add(1))
	client := &SSEClient{
		ID:           id,
		ResponseChan: make(chan *SSEEvent, 100),
		CreatedAt:    time.Now(),
		LastEventID:  lastEventID,
	}
	r.clients[id] = client
	return client
}

// Remove removes a client from the registry
func (r *ClientRegistry) Remove(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if client, ok := r.clients[id]; ok {
		close(client.ResponseChan)
		delete(r.clients, id)
	}
}

// Get returns a client by ID
func (r *ClientRegistry) Get(id string) (*SSEClient, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	client, ok := r.clients[id]
	return client, ok
}

// Broadcast sends an event to all connected clients
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

// Count returns the number of connected clients
func (r *ClientRegistry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.clients)
}

// NewHTTPTransport creates a new HTTP/SSE transport
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
		config:     config,
		clients:    NewClientRegistry(),
		shutdownCh: make(chan struct{}),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/message", t.handleMessage)
	mux.HandleFunc("/events", t.handleSSE)
	mux.HandleFunc("/health", t.handleHealth)

	t.server = &http.Server{
		Handler:      t.corsMiddleware(mux),
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
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Last-Event-ID")
		w.Header().Set("Access-Control-Expose-Headers", "Content-Type")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusNoContent)
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
				Code:    -32603,
				Message: err.Error(),
			},
		}
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding response: %v", err)
	}

	// Also broadcast the response as an SSE event for streaming clients
	if response != nil {
		eventData, _ := json.Marshal(response)
		t.clients.Broadcast(&SSEEvent{
			ID:    fmt.Sprintf("%d", t.eventID.Add(1)),
			Event: "message",
			Data:  string(eventData),
		})
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
	defer t.clients.Remove(client.ID)

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

// Serve starts the HTTP server and handles messages
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

	if err := t.server.Serve(listener); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
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

// WriteMessage broadcasts a message to all connected SSE clients
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

	return nil
}

// Close closes the HTTP transport
func (t *HTTPTransport) Close() error {
	if t.closed.Swap(true) {
		return nil
	}

	close(t.shutdownCh)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
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

// IsClosed returns whether the transport is closed
func (t *HTTPTransport) IsClosed() bool {
	return t.closed.Load()
}

// Ensure HTTPTransport implements Transport interface
var _ Transport = (*HTTPTransport)(nil)
