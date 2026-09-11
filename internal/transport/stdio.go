// Copyright 2025 Joseph Cumines
//
// Stdio transport for JSON-RPC 2.0 communication

package transport

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"sync/atomic"
)

const stdioReadFragmentBytes = 32 << 10

// MessageReadError is a recoverable JSON-RPC input error. The caller must
// return Code and Message with a null ID, then continue reading later inputs.
type MessageReadError struct {
	Cause   error
	Message string
	Code    int
}

func (e *MessageReadError) Error() string {
	if e.Cause == nil {
		return e.Message
	}
	return fmt.Sprintf("%s: %v", e.Message, e.Cause)
}

func (e *MessageReadError) Unwrap() error {
	return e.Cause
}

// StdioTransport implements the Transport interface for JSON-RPC 2.0
// communication over standard input/output streams. This is the default
// transport for MCP and is used for local communication with parent processes.
//
// Concurrency model:
//   - ReadMessage is safe for a single reader goroutine (no serialization needed).
//   - WriteMessage is safe for concurrent writer goroutines (serialized by writeMu).
//   - Read and Write may proceed concurrently without deadlock because they do
//     not share a mutex. This is critical: ReadMessage blocks on stdin and must
//     never hold a lock that WriteMessage requires.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type StdioTransport struct {
	reader      *bufio.Reader
	writer      io.Writer
	scope       *ClientScope
	inputCloser io.Closer
	closeErr    error
	frame       []byte
	writeMu     sync.Mutex // protects writer only; never held during blocking reads
	closeOnce   sync.Once
	closed      atomic.Bool
}

// NewStdioTransport creates a new stdio transport with the given reader and writer.
// The reader is typically os.Stdin and writer is typically os.Stdout.
func NewStdioTransport(stdin io.Reader, stdout io.Writer) *StdioTransport {
	transport := &StdioTransport{
		reader: bufio.NewReaderSize(stdin, stdioReadFragmentBytes),
		writer: stdout,
		scope:  NewClientScope(),
	}
	// A closeable stdin is transport-owned. Production os.Stdin, pipes, and
	// sockets satisfy this contract, allowing shutdown to interrupt a blocked
	// read rather than abandoning its goroutine. Finite in-memory readers need
	// no close operation and remain supported for decoder tests.
	transport.inputCloser, _ = stdin.(io.Closer)
	return transport
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

	// Context carries transport request cancellation into server dispatch.
	// It is local process state and is never serialized.
	Context context.Context `json:"-"`

	// ClientScope is opaque transport-owned identity for request isolation.
	// It is local process state and is never serialized.
	ClientScope *ClientScope `json:"-"`

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

// ReadMessage reads a JSON-RPC 2.0 message from stdin.
// It blocks until a complete newline-delimited JSON message is available.
// Returns an error if the transport is closed or reading fails.
//
// This method does NOT hold a mutex during the blocking read so that
// concurrent WriteMessage calls are never starved.
// It is safe for exactly one goroutine to call ReadMessage at a time.
func (t *StdioTransport) ReadMessage() (*Message, error) {
	if t.closed.Load() {
		return nil, ErrTransportClosed
	}

	t.frame = t.frame[:0]
	oversized := false
	for {
		fragment, err := t.reader.ReadSlice('\n')
		if t.closed.Load() {
			t.frame = t.frame[:0]
			return nil, ErrTransportClosed
		}

		payload := fragment
		if err == nil {
			// ReadSlice includes the delimiter. Only the terminating LF is
			// framing; a preceding CR remains part of the message budget.
			payload = fragment[:len(fragment)-1]
		}
		if !oversized && !t.appendFrame(payload) {
			// Stop retaining bytes immediately, but drain through this frame's
			// newline before returning so the next read starts synchronized.
			oversized = true
			t.frame = t.frame[:0]
		}

		switch {
		case err == nil:
			if oversized {
				return nil, newRequestReadError(
					ErrCodeInvalidRequest,
					invalidRequestMessage,
					fmt.Errorf("JSON-RPC message exceeds %d bytes", MaxJSONRPCMessageBytes),
				)
			}
			msg, decodeErr := DecodeRequest(t.frame)
			t.frame = t.frame[:0]
			if decodeErr != nil {
				return nil, decodeErr
			}
			msg.ClientScope = t.scope
			return msg, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case errors.Is(err, io.EOF):
			t.frame = t.frame[:0]
			if t.closed.Load() {
				return nil, ErrTransportClosed
			}
			return nil, io.EOF
		default:
			t.frame = t.frame[:0]
			if t.closed.Load() {
				return nil, ErrTransportClosed
			}
			return nil, fmt.Errorf("failed to read line: %w", err)
		}
	}
}

func (t *StdioTransport) appendFrame(fragment []byte) bool {
	if len(fragment) > MaxJSONRPCMessageBytes-len(t.frame) {
		return false
	}
	required := len(t.frame) + len(fragment)
	if required > cap(t.frame) {
		nextCapacity := min(max(max(cap(t.frame)*2, stdioReadFragmentBytes), required), MaxJSONRPCMessageBytes)
		grown := make([]byte, len(t.frame), nextCapacity)
		copy(grown, t.frame)
		t.frame = grown
	}
	t.frame = append(t.frame, fragment...)
	return true
}

// WriteMessage writes a JSON-RPC 2.0 message to stdout.
// The message is serialized as a single line of JSON followed by a newline.
// Safe for concurrent use by multiple goroutines.
func (t *StdioTransport) WriteMessage(msg *Message) error {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()

	if t.closed.Load() {
		return ErrTransportClosed
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

// Close closes the transport and marks it as unavailable.
// Subsequent operations will return an error.
func (t *StdioTransport) Close() error {
	t.closeOnce.Do(func() {
		t.closed.Store(true)
		t.scope.Close()
		if t.inputCloser != nil {
			if err := t.inputCloser.Close(); err != nil {
				t.closeErr = fmt.Errorf("close stdio input: %w", err)
			}
		}
	})
	return t.closeErr
}

// IsClosed returns true if the transport has been closed.
func (t *StdioTransport) IsClosed() bool {
	return t.closed.Load()
}

// Serve starts serving JSON-RPC 2.0 messages using the provided handler.
// It reads messages from stdin, dispatches them to the handler, and writes
// responses to stdout. This method blocks until stdin is closed.
func (t *StdioTransport) Serve(handler func(*Message) (*Message, error)) error {
	for {
		msg, err := t.ReadMessage()
		if err != nil {
			if errors.Is(err, ErrTransportClosed) {
				return nil
			}
			if errors.Is(err, io.EOF) {
				log.Println("Stdin closed, exiting")
				return nil
			}
			if readErr, ok := errors.AsType[*MessageReadError](err); ok {
				if writeErr := t.WriteMessage(&Message{
					JSONRPC: "2.0",
					ID:      json.RawMessage("null"),
					Error: &ErrorObj{
						Code:    readErr.Code,
						Message: readErr.Message,
					},
				}); writeErr != nil {
					return fmt.Errorf("write JSON-RPC frame error: %w", writeErr)
				}
				continue
			}
			log.Printf("Error reading message: %v", err)
			return err
		}

		response, err := handler(msg)
		if err != nil {
			if errors.Is(err, ErrRequestCancelled) {
				continue
			}
			log.Printf("Error handling message: %v", err)
			response = &Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &ErrorObj{
					Code:    ErrCodeInternalError,
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
