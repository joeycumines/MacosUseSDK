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
