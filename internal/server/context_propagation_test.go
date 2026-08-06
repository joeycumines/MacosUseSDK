// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/config"
)

func TestHandleWait_UsesToolCallContext(t *testing.T) {
	requestCtx, cancelRequest := context.WithCancel(context.Background())
	cancelRequest()
	server := &MCPServer{
		cfg: &config.Config{RequestTimeout: 30},
		ctx: context.Background(),
	}

	result, err := server.handleWait(&ToolCall{
		Context:   requestCtx,
		Arguments: []byte(`{"duration":10}`),
	})
	if err != nil {
		t.Fatalf("handleWait() error = %v", err)
	}
	if result == nil || !result.IsError || len(result.Content) != 1 || result.Content[0].Text != "Wait cancelled" {
		t.Fatalf("handleWait() result = %+v, want cancellation error", result)
	}
}

func TestNewToolCallContext_CancelsFromRequestOrServer(t *testing.T) {
	tests := []struct {
		name          string
		cancelRequest bool
	}{
		{name: "request", cancelRequest: true},
		{name: "server"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			serverCtx, cancelServer := context.WithCancel(context.Background())
			defer cancelServer()
			requestCtx, cancelRequest := context.WithCancel(context.Background())
			defer cancelRequest()
			server := &MCPServer{ctx: serverCtx}
			callCtx, cancelCall := server.newToolCallContext(requestCtx)
			defer cancelCall()

			if test.cancelRequest {
				cancelRequest()
			} else {
				cancelServer()
			}
			deadlineCtx, cancelDeadline := context.WithTimeout(context.Background(), time.Second)
			defer cancelDeadline()
			select {
			case <-callCtx.Done():
			case <-deadlineCtx.Done():
				t.Fatalf("tool call context ignored %s cancellation", test.name)
			}
		})
	}
}

func TestToolHandlersDoNotDeriveWorkFromServerLifetime(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller could not locate server package")
	}
	files, err := filepath.Glob(filepath.Join(filepath.Dir(currentFile), "cua_*.go"))
	if err != nil {
		t.Fatalf("glob CUA handler sources: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("no CUA handler sources found")
	}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("read %s: %v", file, err)
		}
		source := string(data)
		for _, forbidden := range []string{"context.WithTimeout(s.ctx", "<-s.ctx.Done()"} {
			if strings.Contains(source, forbidden) {
				t.Errorf("%s derives tool work from server lifetime via %q", filepath.Base(file), forbidden)
			}
		}
	}
}
