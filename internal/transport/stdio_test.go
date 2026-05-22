// Copyright 2025 Joseph Cumines
//
// Stdio transport unit tests

package transport

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

func TestNewStdioTransport(t *testing.T) {
	var stdin bytes.Buffer
	var stdout bytes.Buffer

	transport := NewStdioTransport(&stdin, &stdout)
	if transport == nil {
		t.Fatal("NewStdioTransport returned nil")
	}
	if transport.reader == nil {
		t.Error("Transport reader is nil")
	}
	if transport.writer == nil {
		t.Error("Transport writer is nil")
	}
	if transport.closed.Load() {
		t.Error("Transport should not be closed initially")
	}
}

func TestReadMessage(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantErr  bool
		wantMeth string
	}{
		{
			name:     "valid request",
			input:    `{"jsonrpc":"2.0","id":1,"method":"test"}` + "\n",
			wantErr:  false,
			wantMeth: "test",
		},
		{
			name:     "valid notification",
			input:    `{"jsonrpc":"2.0","method":"notify"}` + "\n",
			wantErr:  false,
			wantMeth: "notify",
		},
		{
			name:    "invalid json",
			input:   `{not valid json}` + "\n",
			wantErr: true,
		},
		{
			name:    "empty line",
			input:   "\n",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stdin := strings.NewReader(tt.input)
			var stdout bytes.Buffer
			transport := NewStdioTransport(stdin, &stdout)

			msg, err := transport.ReadMessage()
			if (err != nil) != tt.wantErr {
				t.Errorf("ReadMessage() error = %v, wantErr = %v", err, tt.wantErr)
				return
			}

			if tt.wantErr {
				return
			}

			if msg.Method != tt.wantMeth {
				t.Errorf("Method = %q, want %q", msg.Method, tt.wantMeth)
			}
		})
	}
}

func TestReadMessage_EOF(t *testing.T) {
	stdin := strings.NewReader("")
	var stdout bytes.Buffer
	transport := NewStdioTransport(stdin, &stdout)

	_, err := transport.ReadMessage()
	if err == nil {
		t.Error("Expected error for EOF, got nil")
	}
	if !strings.Contains(err.Error(), "stdin closed") {
		t.Errorf("Error should mention stdin closed, got: %v", err)
	}
}

func TestWriteMessage(t *testing.T) {
	tests := []struct {
		name    string
		msg     *Message
		wantErr bool
	}{
		{
			name: "success response",
			msg: &Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Result:  json.RawMessage(`{"content":[]}`),
			},
			wantErr: false,
		},
		{
			name: "error response",
			msg: &Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Error: &ErrorObj{
					Code:    -32600,
					Message: "Invalid Request",
				},
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stdin bytes.Buffer
			var stdout bytes.Buffer
			transport := NewStdioTransport(&stdin, &stdout)

			err := transport.WriteMessage(tt.msg)
			if (err != nil) != tt.wantErr {
				t.Errorf("WriteMessage() error = %v, wantErr = %v", err, tt.wantErr)
				return
			}

			if tt.wantErr {
				return
			}

			output := stdout.String()
			if !strings.HasSuffix(output, "\n") {
				t.Error("Output should end with newline")
			}

			jsonStr := strings.TrimSpace(output)
			var parsed map[string]any
			if err := json.Unmarshal([]byte(jsonStr), &parsed); err != nil {
				t.Errorf("Output is not valid JSON: %v", err)
			}
		})
	}
}

func TestClose(t *testing.T) {
	var stdin bytes.Buffer
	var stdout bytes.Buffer
	transport := NewStdioTransport(&stdin, &stdout)

	if transport.IsClosed() {
		t.Error("Transport should not be closed initially")
	}

	if err := transport.Close(); err != nil {
		t.Errorf("Close() error = %v", err)
	}

	if !transport.IsClosed() {
		t.Error("Transport should be closed after Close()")
	}

	if err := transport.Close(); err != nil {
		t.Errorf("Close() again error = %v", err)
	}
}

func TestReadMessage_AfterClose(t *testing.T) {
	stdin := strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"test"}` + "\n")
	var stdout bytes.Buffer
	transport := NewStdioTransport(stdin, &stdout)

	transport.Close()

	_, err := transport.ReadMessage()
	if err == nil {
		t.Error("Expected error reading from closed transport")
	}
	if !strings.Contains(err.Error(), "closed") {
		t.Errorf("Error should mention closed, got: %v", err)
	}
}

func TestWriteMessage_AfterClose(t *testing.T) {
	var stdin bytes.Buffer
	var stdout bytes.Buffer
	transport := NewStdioTransport(&stdin, &stdout)

	transport.Close()

	err := transport.WriteMessage(&Message{JSONRPC: "2.0"})
	if err == nil {
		t.Error("Expected error writing to closed transport")
	}
	if !strings.Contains(err.Error(), "closed") {
		t.Errorf("Error should mention closed, got: %v", err)
	}
}

func TestMessage_JSON(t *testing.T) {
	tests := []struct {
		name    string
		msg     Message
		wantErr bool
	}{
		{
			name: "request with params",
			msg: Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "test",
				Params:  json.RawMessage(`{"key":"value"}`),
			},
			wantErr: false,
		},
		{
			name: "response with result",
			msg: Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`"abc"`),
				Result:  json.RawMessage(`{"content":[]}`),
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, err := json.Marshal(&tt.msg)
			if (err != nil) != tt.wantErr {
				t.Fatalf("Marshal error = %v, wantErr = %v", err, tt.wantErr)
			}

			if tt.wantErr {
				return
			}

			var parsed Message
			if err := json.Unmarshal(data, &parsed); err != nil {
				t.Fatalf("Unmarshal error = %v", err)
			}

			if parsed.JSONRPC != tt.msg.JSONRPC {
				t.Errorf("JSONRPC = %q, want %q", parsed.JSONRPC, tt.msg.JSONRPC)
			}
			if parsed.Method != tt.msg.Method {
				t.Errorf("Method = %q, want %q", parsed.Method, tt.msg.Method)
			}
		})
	}
}

func TestErrorObj_JSON(t *testing.T) {
	errObj := ErrorObj{
		Code:    -32600,
		Message: "Invalid Request",
	}

	data, err := json.Marshal(&errObj)
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}

	var parsed ErrorObj
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}

	if parsed.Code != errObj.Code {
		t.Errorf("Code = %d, want %d", parsed.Code, errObj.Code)
	}
	if parsed.Message != errObj.Message {
		t.Errorf("Message = %q, want %q", parsed.Message, errObj.Message)
	}
}

func TestServe(t *testing.T) {
	input := `{"jsonrpc":"2.0","id":1,"method":"test"}` + "\n" +
		`{"jsonrpc":"2.0","id":2,"method":"test2"}` + "\n"

	stdin := strings.NewReader(input)
	var stdout bytes.Buffer
	transport := NewStdioTransport(stdin, &stdout)

	callCount := 0
	handler := func(msg *Message) (*Message, error) {
		callCount++
		return &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  json.RawMessage(`{"ok":true}`),
		}, nil
	}

	err := transport.Serve(handler)
	if err != nil {
		t.Errorf("Serve() error = %v", err)
	}

	if callCount != 2 {
		t.Errorf("Handler called %d times, want 2", callCount)
	}

	output := stdout.String()
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) != 2 {
		t.Errorf("Got %d output lines, want 2", len(lines))
	}
}

type failWriter struct{}

func (f *failWriter) Write(p []byte) (n int, err error) {
	return 0, io.ErrUnexpectedEOF
}

func TestWriteMessage_WriterError(t *testing.T) {
	var stdin bytes.Buffer
	transport := NewStdioTransport(&stdin, &failWriter{})

	err := transport.WriteMessage(&Message{JSONRPC: "2.0"})
	if err == nil {
		t.Error("Expected error for writer failure")
	}
}

func TestConcurrentAccess(t *testing.T) {
	var stdin bytes.Buffer
	var stdout bytes.Buffer
	transport := NewStdioTransport(&stdin, &stdout)

	done := make(chan bool)

	for i := range 10 {
		go func(id int) {
			msg := &Message{
				JSONRPC: "2.0",
				ID:      json.RawMessage(`1`),
				Method:  "test",
			}
			_ = transport.WriteMessage(msg)
			done <- true
		}(i)
	}

	for range 10 {
		<-done
	}

	go transport.Close()
	go transport.IsClosed()
}

// TestConcurrentReadWrite verifies that WriteMessage does not deadlock when
// ReadMessage is blocked waiting for input. This was a critical bug: the old
// implementation used a single mutex for both read and write, causing
// WriteMessage to block indefinitely while ReadMessage held the lock during
// a blocking stdin read.
func TestConcurrentReadWrite(t *testing.T) {
	// slowReader blocks on Read until we close the channel, simulating
	// a stdin that has no data yet (the normal steady state).
	pr, pw := io.Pipe()
	var stdout bytes.Buffer
	tr := NewStdioTransport(pr, &stdout)

	// Start a goroutine that blocks on ReadMessage (stdin has no data).
	readDone := make(chan error, 1)
	go func() {
		_, err := tr.ReadMessage()
		readDone <- err
	}()

	// Give the reader goroutine time to block inside ReadString.
	// (Not a sleep-based assertion; the actual assertion is below.)
	select {
	case <-readDone:
		t.Fatal("ReadMessage should be blocking, but it returned early")
	default:
	}

	// WriteMessage MUST succeed even though ReadMessage is blocked.
	// Under the old single-mutex design this would deadlock.
	writeDone := make(chan error, 1)
	go func() {
		writeDone <- tr.WriteMessage(&Message{
			JSONRPC: "2.0",
			ID:      json.RawMessage(`1`),
			Result:  json.RawMessage(`{"ok":true}`),
		})
	}()

	select {
	case err := <-writeDone:
		if err != nil {
			t.Fatalf("WriteMessage failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("WriteMessage deadlocked (timed out after 2s)")
	}

	// Clean up: send data so ReadMessage unblocks, then close.
	_, _ = pw.Write([]byte(`{"jsonrpc":"2.0","method":"ping"}` + "\n"))
	select {
	case err := <-readDone:
		if err != nil {
			t.Fatalf("ReadMessage failed after unblocking: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ReadMessage did not unblock after write")
	}
	pw.Close()
}
