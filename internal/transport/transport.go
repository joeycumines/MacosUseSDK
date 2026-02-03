// Copyright 2025 Joseph Cumines
//
// Transport interface for MCP communication

package transport

// Transport defines the interface for MCP message transport.
//
// Implementations must be safe for concurrent use from multiple goroutines.
// The transport manages the lifecycle of connections and handles serialization
// of JSON-RPC 2.0 messages.
//
// There are two main implementations:
//   - StdioTransport: Uses stdin/stdout for communication (default)
//   - HTTPTransport: Uses HTTP POST for requests and SSE for responses
//
// Error handling:
//   - io.EOF indicates the transport was closed by the peer
//   - Errors containing "closed" indicate the transport was closed locally
//   - Other errors indicate transport-layer failures
type Transport interface {
	// ReadMessage reads a JSON-RPC 2.0 message from the transport.
	// Blocks until a message is available, an error occurs, or the transport is closed.
	// Returns io.EOF when the peer closes the connection.
	//
	// Note: HTTPTransport does not support ReadMessage; it uses a callback pattern
	// via Serve(handler) instead. Calling ReadMessage on HTTPTransport returns
	// an error immediately.
	ReadMessage() (*Message, error)

	// WriteMessage writes a JSON-RPC 2.0 message to the transport.
	// For StdioTransport, writes to stdout.
	// For HTTPTransport, broadcasts to all connected SSE clients.
	// Returns an error if the transport is closed or the write fails.
	WriteMessage(msg *Message) error

	// Close closes the transport and releases any resources.
	// After Close is called, subsequent operations return errors.
	// Close is idempotent and safe to call multiple times.
	Close() error

	// IsClosed returns whether the transport has been closed.
	// Thread-safe and can be called from any goroutine.
	IsClosed() bool
}

// Ensure StdioTransport implements Transport interface
var _ Transport = (*StdioTransport)(nil)
