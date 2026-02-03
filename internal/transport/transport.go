// Copyright 2025 Joseph Cumines
//
// Transport interface for MCP communication

package transport

// Transport defines the interface for MCP message transport
type Transport interface {
	// ReadMessage reads a JSON-RPC 2.0 message from the transport
	ReadMessage() (*Message, error)

	// WriteMessage writes a JSON-RPC 2.0 message to the transport
	WriteMessage(msg *Message) error

	// Close closes the transport
	Close() error

	// IsClosed returns whether the transport is closed
	IsClosed() bool
}

// Ensure StdioTransport implements Transport interface
var _ Transport = (*StdioTransport)(nil)
