// Copyright 2026 Joseph Cumines

package server

import (
	"encoding/json"
	"testing"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

func TestHandleHTTPMessage_ValidatesRequestBeforeDispatch(t *testing.T) {
	server := &MCPServer{}
	tests := []struct {
		name    string
		message *transport.Message
	}{
		{name: "nil message"},
		{name: "wrong version", message: &transport.Message{JSONRPC: "1.0", ID: json.RawMessage(`1`), Method: "ping"}},
		{name: "missing method", message: &transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`1`)}},
		{name: "scalar params", message: &transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "ping", Params: json.RawMessage(`"bad"`)}},
		{name: "boolean ID", message: &transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`true`), Method: "ping"}},
		{name: "null ID", message: &transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`null`), Method: "ping"}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response, err := server.handleHTTPMessage(test.message)
			if err != nil {
				t.Fatalf("handleHTTPMessage() error = %v", err)
			}
			if response == nil || response.Error == nil || response.Error.Code != transport.ErrCodeInvalidRequest {
				t.Fatalf("handleHTTPMessage() response = %+v, want invalid request", response)
			}
			if response.JSONRPC != "2.0" || string(response.ID) != "null" {
				t.Fatalf("handleHTTPMessage() response = %+v, want JSON-RPC 2.0 null ID", response)
			}
		})
	}
}

func TestHandleHTTPMessage_NotificationHasAbsentID(t *testing.T) {
	server := &MCPServer{}
	notification, err := server.handleHTTPMessage(&transport.Message{JSONRPC: "2.0", Method: "ping"})
	if err != nil {
		t.Fatalf("notification error = %v", err)
	}
	if notification != nil {
		t.Fatalf("notification response = %+v, want nil", notification)
	}
}

func TestValidateAndProcessInitialize_RejectsInvalidParams(t *testing.T) {
	server := &MCPServer{}
	tests := []struct {
		name   string
		params json.RawMessage
	}{
		{name: "missing params"},
		{name: "array params", params: json.RawMessage(`[]`)},
		{name: "empty object", params: json.RawMessage(`{}`)},
		{name: "wrong protocol version type", params: json.RawMessage(`{"protocolVersion":42,"capabilities":{},"clientInfo":{"name":"test","version":"1"}}`)},
		{name: "missing protocol version", params: json.RawMessage(`{"capabilities":{},"clientInfo":{"name":"test","version":"1"}}`)},
		{name: "missing capabilities", params: json.RawMessage(`{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"}}`)},
		{name: "null capabilities", params: json.RawMessage(`{"protocolVersion":"2025-11-25","capabilities":null,"clientInfo":{"name":"test","version":"1"}}`)},
		{name: "missing client info", params: json.RawMessage(`{"protocolVersion":"2025-11-25","capabilities":{}}`)},
		{name: "empty client name", params: json.RawMessage(`{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"","version":"1"}}`)},
		{name: "empty client version", params: json.RawMessage(`{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":""}}`)},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response, err := server.validateAndProcessInitialize(&transport.Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "initialize",
				Params:  test.params,
			})
			if err != nil {
				t.Fatalf("validateAndProcessInitialize() error = %v", err)
			}
			if response == nil || response.Error == nil || response.Error.Code != transport.ErrCodeInvalidParams {
				t.Fatalf("validateAndProcessInitialize() response = %+v, want invalid params", response)
			}
			if response.JSONRPC != "2.0" || string(response.ID) != "1" || len(response.Result) != 0 {
				t.Fatalf("validateAndProcessInitialize() response = %+v, want correlated JSON-RPC error", response)
			}
		})
	}
}
