// Copyright 2025 Joseph Cumines
//
// Stdio transport for JSON-RPC 2.0 communication

package transport

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
)

// StdioTransport implements JSON-RPC 2.0 transport over stdin/stdout
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type StdioTransport struct {
	reader *bufio.Reader
	writer io.Writer
	mu     sync.Mutex
	closed bool
}

// NewStdioTransport creates a new stdio transport
func NewStdioTransport(stdin io.Reader, stdout io.Writer) *StdioTransport {
	return &StdioTransport{
		reader: bufio.NewReader(stdin),
		writer: stdout,
	}
}

// Message represents a JSON-RPC 2.0 message.
//
// This is a union type that can represent either a Request or a Response:
//
// Request format:
//   - JSONRPC: "2.0" (required)
//   - Method: The method name (required)
//   - Params: Method parameters (optional)
//   - ID: Request identifier (optional; omit for notifications)
//
// Response format:
//   - JSONRPC: "2.0" (required)
//   - Result: Success result (mutually exclusive with Error)
//   - Error: Error object (mutually exclusive with Result)
//   - ID: Matches the request ID (required; null for notification responses)
//
// Field names are lowercase per JSON-RPC 2.0 specification.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Message struct {
	// Error contains error details for failed requests.
	// Present only in error responses; mutually exclusive with Result.
	Error *ErrorObj `json:"error,omitempty"`

	// JSONRPC is always "2.0" per the JSON-RPC specification.
	JSONRPC string `json:"jsonrpc"`

	// Method is the name of the method to invoke.
	// Present only in requests.
	Method string `json:"method,omitempty"`

	// ID is the request identifier.
	// For requests: any JSON value (string, number, null).
	// For responses: matches the request ID.
	// Omitted for notifications (requests without responses).
	ID json.RawMessage `json:"id,omitempty"`

	// Params contains the method parameters.
	// Present only in requests; may be object or array.
	Params json.RawMessage `json:"params,omitempty"`

	// Result contains the success response data.
	// Present only in success responses; mutually exclusive with Error.
	Result json.RawMessage `json:"result,omitempty"`
}

// ErrorObj represents a JSON-RPC 2.0 error object.
//
// Standard error codes:
//   - -32700: Parse error
//   - -32600: Invalid Request
//   - -32601: Method not found
//   - -32602: Invalid params
//   - -32603: Internal error
//   - -32000 to -32099: Server error (reserved for implementation-defined errors)
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type ErrorObj struct {
	// Message is a human-readable description of the error.
	Message string `json:"message"`

	// Data contains additional error information.
	// May be any JSON value; structure is implementation-defined.
	Data json.RawMessage `json:"data,omitempty"`

	// Code is a number indicating the error type.
	// See JSON-RPC 2.0 specification for standard codes.
	Code int `json:"code"`
}

// ReadMessage reads a JSON-RPC 2.0 message
func (t *StdioTransport) ReadMessage() (*Message, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return nil, fmt.Errorf("transport is closed")
	}

	line, err := t.reader.ReadString('\n')
	if err != nil {
		if err == io.EOF {
			return nil, fmt.Errorf("stdin closed")
		}
		return nil, fmt.Errorf("failed to read line: %w", err)
	}

	line = strings.TrimSpace(line)
	if line == "" {
		return nil, fmt.Errorf("empty line received")
	}

	var msg Message
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %w", err)
	}

	return &msg, nil
}

// WriteMessage writes a JSON-RPC 2.0 message
func (t *StdioTransport) WriteMessage(msg *Message) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return fmt.Errorf("transport is closed")
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to encode message: %w", err)
	}

	if _, err := t.writer.Write(data); err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}
	if _, err := t.writer.Write([]byte("\n")); err != nil {
		return fmt.Errorf("failed to write newline: %w", err)
	}

	return nil
}

// Close closes the transport
func (t *StdioTransport) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return nil
	}

	t.closed = true
	return nil
}

// IsClosed returns whether the transport is closed
func (t *StdioTransport) IsClosed() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closed
}

// Serve starts serving JSON-RPC 2.0 messages
func (t *StdioTransport) Serve(handler func(*Message) (*Message, error)) error {
	for {
		msg, err := t.ReadMessage()
		if err != nil {
			if err.Error() == "stdin closed" {
				log.Println("Stdin closed, exiting")
				return nil
			}
			log.Printf("Error reading message: %v", err)
			continue
		}

		response, err := handler(msg)
		if err != nil {
			log.Printf("Error handling message: %v", err)
			response = &Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &ErrorObj{
					Code:    -32603,
					Message: err.Error(),
				},
			}
		}

		if response != nil {
			if err := t.WriteMessage(response); err != nil {
				log.Printf("Error writing message: %v", err)
			}
		}
	}
}
