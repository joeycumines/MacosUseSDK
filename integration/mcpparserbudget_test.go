// Copyright 2026 Joseph Cumines

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
)

const mcpStdioFrameTestLimit = 8 << 20

type mcpStdioFrameBackend struct {
	pb.UnimplementedMacosUseServer
	calls atomic.Int64
}

func (s *mcpStdioFrameBackend) ListWindows(
	context.Context,
	*pb.ListWindowsRequest,
) (*pb.ListWindowsResponse, error) {
	s.calls.Add(1)
	return &pb.ListWindowsResponse{}, nil
}

func TestMCPStdioFrameBudget_ProductionProcess(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	grpcAddress, backend, stopBackend := startMCPStdioFrameBackend(t)
	defer stopBackend()
	_, stdin, stdout, stopMCP := startMCPStdioProcessWithOverrides(
		t,
		ctx,
		grpcAddress,
		requestAdmissionProcessOverrides("8", "8"),
	)
	mcpStopped := false
	defer func() {
		if !mcpStopped {
			stopMCP()
		}
	}()

	initialize, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(1))
	if err != nil || initialize.Error != nil {
		t.Fatalf("initialize response=%+v error=%v", initialize, err)
	}
	if err := writeStdioMessage(stdin, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("send initialized notification: %v", err)
	}

	exact := mcpStdioSizedToolRequest(t, mcpStdioFrameTestLimit, 2)
	if err := writeMCPStdioRawFrame(stdin, exact, true); err != nil {
		t.Fatalf("write exact-limit frame: %v", err)
	}
	exactResponse, err := readStdioResponse(ctx, stdout)
	if err != nil {
		t.Fatalf("read exact-limit response: %v", err)
	}
	if exactResponse.Error != nil || string(exactResponse.ID) != "2" {
		t.Fatalf("exact-limit response=%+v, want id=2 success", exactResponse)
	}
	if got := backend.calls.Load(); got != 1 {
		t.Fatalf("backend calls after exact-limit frame=%d, want 1", got)
	}

	oversize := mcpStdioSizedToolRequest(t, mcpStdioFrameTestLimit+1, 999)
	if err := writeMCPStdioRawFrame(stdin, oversize, true); err != nil {
		t.Fatalf("write limit-plus-one frame: %v", err)
	}
	rejected, err := readStdioResponse(ctx, stdout)
	if err != nil {
		t.Fatalf("read limit-plus-one response: %v", err)
	}
	if string(rejected.ID) != "null" || rejected.Error == nil ||
		rejected.Error.Code != -32600 ||
		rejected.Error.Message != "Invalid Request" {
		t.Fatalf("limit-plus-one response=%+v, want null-id -32600", rejected)
	}
	if got := backend.calls.Load(); got != 1 {
		t.Fatalf("backend calls after limit-plus-one frame=%d, want unchanged 1", got)
	}

	ping, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "ping",
	})
	if err != nil {
		t.Fatalf("ping after limit-plus-one frame: %v", err)
	}
	if ping.Error != nil || string(ping.ID) != "3" || string(ping.Result) != "{}" {
		t.Fatalf("ping recovery response=%+v", ping)
	}

	unterminated := mcpStdioSizedToolRequest(t, mcpStdioFrameTestLimit+1, 1000)
	if err := writeMCPStdioRawFrame(stdin, unterminated, false); err != nil {
		t.Fatalf("write unterminated oversize frame: %v", err)
	}
	stopMCP()
	mcpStopped = true
	if got := backend.calls.Load(); got != 1 {
		t.Fatalf("backend calls after unterminated oversize close=%d, want unchanged 1", got)
	}
}

func startMCPStdioFrameBackend(t *testing.T) (string, *mcpStdioFrameBackend, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for stdio-frame backend: %v", err)
	}
	backend := &mcpStdioFrameBackend{}
	server := grpc.NewServer()
	pb.RegisterMacosUseServer(server, backend)
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- server.Serve(listener)
	}()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			server.Stop()
			if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Errorf("stop stdio-frame backend: %v", err)
			}
		})
	}
	return listener.Addr().String(), backend, stop
}

func mcpStdioSizedToolRequest(t *testing.T, size int, id int) []byte {
	t.Helper()
	base, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "list_windows",
			"arguments": map[string]any{
				"app": "applications/frame-budget",
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal stdio-frame request: %v", err)
	}
	if len(base) > size {
		t.Fatalf("stdio-frame request base size=%d exceeds requested size=%d", len(base), size)
	}
	frame := make([]byte, size)
	copy(frame, base)
	copy(frame[len(base):], bytes.Repeat([]byte{' '}, size-len(base)))
	return frame
}

func writeMCPStdioRawFrame(writer io.Writer, frame []byte, newline bool) error {
	if _, err := writer.Write(frame); err != nil {
		return fmt.Errorf("write frame: %w", err)
	}
	if newline {
		if _, err := writer.Write([]byte{'\n'}); err != nil {
			return fmt.Errorf("write frame newline: %w", err)
		}
	}
	return nil
}
