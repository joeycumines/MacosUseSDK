// Copyright 2026 Joseph Cumines

package transport

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"sync"
	"testing"
	"time"
)

const stdioFrameTestLimit = 8 << 20

func TestStdioFrameBudgetExactLimitRejectsOversizeAndRecovers(t *testing.T) {
	var input bytes.Buffer
	input.Grow(2*stdioFrameTestLimit + 256)
	input.Write(stdioFrameSizedRequest(t, stdioFrameTestLimit, 1))
	input.WriteByte('\n')
	input.Write(stdioFrameSizedRequest(t, stdioFrameTestLimit+1, 99))
	input.WriteByte('\n')
	input.WriteString(`{"jsonrpc":"2.0","id":2,"method":"recovered"}`)
	input.WriteByte('\n')

	transport := NewStdioTransport(bytes.NewReader(input.Bytes()), io.Discard)
	exact, err := transport.ReadMessage()
	if err != nil {
		t.Fatalf("exact-limit ReadMessage() error = %v", err)
	}
	if exact.Method != "ping" || string(exact.ID) != "1" {
		t.Fatalf("exact-limit message = %+v, want ping id=1", exact)
	}

	_, err = transport.ReadMessage()
	var readErr *MessageReadError
	if !errors.As(err, &readErr) {
		t.Fatalf("limit-plus-one ReadMessage() error = %T %v, want *MessageReadError", err, err)
	}
	if readErr.Code != ErrCodeInvalidRequest || readErr.Message != invalidRequestMessage {
		t.Fatalf("limit-plus-one protocol error = %+v, want code=%d message=%q", readErr, ErrCodeInvalidRequest, invalidRequestMessage)
	}

	recovered, err := transport.ReadMessage()
	if err != nil {
		t.Fatalf("recovery ReadMessage() error = %v", err)
	}
	if recovered.Method != "recovered" || string(recovered.ID) != "2" {
		t.Fatalf("recovery message = %+v, want recovered id=2", recovered)
	}
}

func TestStdioFrameBudgetFragmentationAndRetainedCapacity(t *testing.T) {
	var input bytes.Buffer
	for id := 1; id <= 3; id++ {
		input.Write(stdioFrameSizedRequest(t, stdioFrameTestLimit+id, id))
		input.WriteByte('\n')
	}
	input.WriteString(`{"jsonrpc":"2.0","id":4,"method":"after-fragments"}`)
	input.WriteByte('\n')

	source := &stdioFrameChunkReader{
		reader:   bytes.NewReader(input.Bytes()),
		maxChunk: 127,
	}
	transport := NewStdioTransport(source, io.Discard)
	for id := 1; id <= 3; id++ {
		_, err := transport.ReadMessage()
		var readErr *MessageReadError
		if !errors.As(err, &readErr) || readErr.Code != ErrCodeInvalidRequest {
			t.Errorf("fragmented oversize %d error = %T %v, want invalid-request read error", id, err, err)
		}
	}
	recovered, err := transport.ReadMessage()
	if err != nil {
		t.Fatalf("fragmented recovery ReadMessage() error = %v", err)
	}
	if recovered.Method != "after-fragments" || string(recovered.ID) != "4" {
		t.Fatalf("fragmented recovery message = %+v", recovered)
	}

	frame := reflect.ValueOf(transport).Elem().FieldByName("frame")
	if !frame.IsValid() || frame.Kind() != reflect.Slice {
		t.Error("StdioTransport has no reusable capacity-bounded frame buffer")
	} else if frame.Cap() > stdioFrameTestLimit {
		t.Errorf("retained frame capacity = %d, want <= %d", frame.Cap(), stdioFrameTestLimit)
	}
	if got := transport.reader.Size(); got > 64<<10 {
		t.Errorf("bufio reader size = %d, want one fixed fragment <= %d", got, 64<<10)
	}
	if got := source.maxReadSize(); got > 64<<10 {
		t.Errorf("largest underlying read = %d, want fixed fragments <= %d", got, 64<<10)
	}
}

func TestStdioFrameBudgetServeReturnsRecoverableInvalidRequest(t *testing.T) {
	var input bytes.Buffer
	input.Write(stdioFrameSizedRequest(t, stdioFrameTestLimit+1, 99))
	input.WriteByte('\n')
	input.WriteString(`{"jsonrpc":"2.0","id":7,"method":"after-oversize"}`)
	input.WriteByte('\n')
	var output bytes.Buffer
	transport := NewStdioTransport(bytes.NewReader(input.Bytes()), &output)

	handlerCalls := 0
	err := transport.Serve(func(msg *Message) (*Message, error) {
		handlerCalls++
		return &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  json.RawMessage(`{"ok":true}`),
		}, nil
	})
	if err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	if handlerCalls != 1 {
		t.Fatalf("handler calls = %d, want 1", handlerCalls)
	}

	lines := bytes.Split(bytes.TrimSpace(output.Bytes()), []byte{'\n'})
	if len(lines) != 2 {
		t.Fatalf("response count = %d, want 2", len(lines))
	}
	var rejected Message
	if err := json.Unmarshal(lines[0], &rejected); err != nil {
		t.Fatalf("decode oversize response: %v", err)
	}
	if string(rejected.ID) != "null" || rejected.Error == nil ||
		rejected.Error.Code != ErrCodeInvalidRequest ||
		rejected.Error.Message != invalidRequestMessage {
		t.Fatalf("oversize response = %+v, want null-id invalid request", rejected)
	}
	var recovered Message
	if err := json.Unmarshal(lines[1], &recovered); err != nil {
		t.Fatalf("decode recovery response: %v", err)
	}
	if string(recovered.ID) != "7" || string(recovered.Result) != `{"ok":true}` {
		t.Fatalf("recovery response = %+v, want id=7 success", recovered)
	}
}

func TestStdioFrameBudgetCloseInterruptsAccumulationAndDrain(t *testing.T) {
	tests := []struct {
		name   string
		prefix []byte
	}{
		{
			name:   "accumulation",
			prefix: bytes.Repeat([]byte{'x'}, 1024),
		},
		{
			name:   "oversize drain",
			prefix: bytes.Repeat([]byte{'x'}, stdioFrameTestLimit+1),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			input := newStdioFrameBlockingReadCloser(test.prefix)
			transport := NewStdioTransport(input, io.Discard)
			result := make(chan error, 1)
			go func() {
				_, err := transport.ReadMessage()
				result <- err
			}()
			select {
			case <-input.blocked:
			case <-time.After(5 * time.Second):
				t.Fatal("ReadMessage did not reach the injected blocked read")
			}
			if err := transport.Close(); err != nil {
				t.Fatalf("Close() error = %v", err)
			}
			select {
			case err := <-result:
				if !errors.Is(err, ErrTransportClosed) {
					t.Fatalf("ReadMessage() error = %v, want ErrTransportClosed", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("Close did not interrupt ReadMessage")
			}
		})
	}
}

func TestStdioFrameBudgetUnterminatedFinalFrameRemainsEOF(t *testing.T) {
	tests := []struct {
		name string
		size int
	}{
		{name: "within limit", size: 1024},
		{name: "oversize", size: stdioFrameTestLimit + 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			transport := NewStdioTransport(
				bytes.NewReader(stdioFrameSizedRequest(t, test.size, 1)),
				io.Discard,
			)
			_, err := transport.ReadMessage()
			if !errors.Is(err, io.EOF) {
				t.Fatalf("unterminated ReadMessage() error = %v, want io.EOF", err)
			}
		})
	}
}

func stdioFrameSizedRequest(t *testing.T, size int, id int) []byte {
	t.Helper()
	base := fmt.Appendf(nil, `{"jsonrpc":"2.0","id":%d,"method":"ping"}`, id)
	if len(base) > size {
		t.Fatalf("request base size = %d, exceeds requested size %d", len(base), size)
	}
	frame := make([]byte, size)
	copy(frame, base)
	for index := len(base); index < len(frame); index++ {
		frame[index] = ' '
	}
	return frame
}

type stdioFrameChunkReader struct {
	reader   *bytes.Reader
	maxChunk int
	mu       sync.Mutex
	maxRead  int
}

func (r *stdioFrameChunkReader) Read(buffer []byte) (int, error) {
	if len(buffer) > r.maxChunk {
		buffer = buffer[:r.maxChunk]
	}
	r.mu.Lock()
	if len(buffer) > r.maxRead {
		r.maxRead = len(buffer)
	}
	r.mu.Unlock()
	return r.reader.Read(buffer)
}

func (r *stdioFrameChunkReader) maxReadSize() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.maxRead
}

type stdioFrameBlockingReadCloser struct {
	prefix  []byte
	blocked chan struct{}
	closed  chan struct{}
	offset  int
	block   sync.Once
	close   sync.Once
}

func newStdioFrameBlockingReadCloser(prefix []byte) *stdioFrameBlockingReadCloser {
	return &stdioFrameBlockingReadCloser{
		prefix:  prefix,
		blocked: make(chan struct{}),
		closed:  make(chan struct{}),
	}
}

func (r *stdioFrameBlockingReadCloser) Read(buffer []byte) (int, error) {
	if r.offset < len(r.prefix) {
		count := copy(buffer, r.prefix[r.offset:])
		r.offset += count
		return count, nil
	}
	r.block.Do(func() { close(r.blocked) })
	<-r.closed
	return 0, io.ErrClosedPipe
}

func (r *stdioFrameBlockingReadCloser) Close() error {
	r.close.Do(func() { close(r.closed) })
	return nil
}
