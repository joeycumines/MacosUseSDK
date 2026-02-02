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

// Message represents a JSON-RPC 2.0 message
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Message struct {
	Error   *ErrorObj
	JSONRPC string
	Method  string
	ID      json.RawMessage
	Params  json.RawMessage
	Result  json.RawMessage
}

// ErrorObj represents a JSON-RPC 2.0 error
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type ErrorObj struct {
	Message string
	Data    json.RawMessage
	Code    int
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
