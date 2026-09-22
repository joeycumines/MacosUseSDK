// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/transport"
)

func TestMCPRequestCancellation_IsolatedByClientScope(t *testing.T) {
	serverCtx, cancelServer := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelServer()
	entered := make(chan string, 2)
	server := &MCPServer{
		ctx:            serverCtx,
		activeRequests: make(map[activeRequestKey]*activeRequest),
		tools: map[string]*Tool{
			"block": blockingCancellationTestTool(entered),
		},
	}
	scopeA := transport.NewClientScope()
	scopeB := transport.NewClientScope()
	defer scopeA.Close()
	defer scopeB.Close()

	type dispatchResult struct {
		response *transport.Message
		err      error
	}
	results := map[string]chan dispatchResult{
		"a": make(chan dispatchResult, 1),
		"b": make(chan dispatchResult, 1),
	}
	invoke := func(label string, scope *transport.ClientScope) {
		params, err := json.Marshal(map[string]any{
			"name":      "block",
			"arguments": map[string]any{"label": label},
		})
		if err != nil {
			results[label] <- dispatchResult{err: err}
			return
		}
		response, err := server.handleHTTPMessage(&transport.Message{
			ClientScope: scope,
			JSONRPC:     "2.0",
			ID:          json.RawMessage(`77`),
			Method:      "tools/call",
			Params:      params,
		})
		results[label] <- dispatchResult{response: response, err: err}
	}
	go invoke("a", scopeA)
	go invoke("b", scopeB)

	enteredSet := make(map[string]bool)
	for range 2 {
		select {
		case label := <-entered:
			enteredSet[label] = true
		case <-serverCtx.Done():
			t.Fatalf("requests did not enter handlers: %v", serverCtx.Err())
		}
	}
	if !enteredSet["a"] || !enteredSet["b"] {
		t.Fatalf("entered labels=%v, want both clients", enteredSet)
	}

	cancelMCPTestRequest(t, server, scopeA, json.RawMessage(`77`))
	resultA := <-results["a"]
	if resultA.response != nil || !errors.Is(resultA.err, transport.ErrRequestCancelled) {
		t.Fatalf("client A result=(%+v, %v), want suppressed cancellation", resultA.response, resultA.err)
	}

	requestID, err := canonicalMCPRequestID(json.RawMessage(`77`))
	if err != nil {
		t.Fatalf("canonicalize request ID: %v", err)
	}
	server.activeMu.Lock()
	activeB, existsB := server.activeRequests[activeRequestKey{scope: scopeB, id: requestID}]
	server.activeMu.Unlock()
	if !existsB || activeB.cancelled {
		t.Fatalf("client B active request exists=%t cancelled=%t after client A cancellation", existsB, existsB && activeB.cancelled)
	}

	cancelMCPTestRequest(t, server, scopeB, json.RawMessage(`77`))
	resultB := <-results["b"]
	if resultB.response != nil || !errors.Is(resultB.err, transport.ErrRequestCancelled) {
		t.Fatalf("client B result=(%+v, %v), want independent suppressed cancellation", resultB.response, resultB.err)
	}
	server.activeMu.Lock()
	remaining := len(server.activeRequests)
	server.activeMu.Unlock()
	if remaining != 0 {
		t.Fatalf("active request leak count=%d, want 0", remaining)
	}
}

func blockingCancellationTestTool(entered chan<- string) *Tool {
	return &Tool{
		Name:           "block",
		MutationPolicy: mutationPolicyReadOnly,
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"label": map[string]any{"type": "string"},
			},
			"required":             []string{"label"},
			"additionalProperties": false,
		},
		Handler: func(call *ToolCall) (*ToolResult, error) {
			var params struct {
				Label string `json:"label"`
			}
			if err := json.Unmarshal(call.Arguments, &params); err != nil {
				return nil, fmt.Errorf("decode blocking test tool: %w", err)
			}
			entered <- params.Label
			<-call.Context.Done()
			return errorResult("cancelled"), nil
		},
	}
}

func cancelMCPTestRequest(t *testing.T, server *MCPServer, scope *transport.ClientScope, requestID json.RawMessage) {
	t.Helper()
	params, err := json.Marshal(map[string]any{"requestId": requestID})
	if err != nil {
		t.Fatalf("marshal cancellation: %v", err)
	}
	response, err := server.handleHTTPMessage(&transport.Message{
		ClientScope: scope,
		JSONRPC:     "2.0",
		Method:      "notifications/cancelled",
		Params:      params,
	})
	if err != nil || response != nil {
		t.Fatalf("cancellation notification response=%+v error=%v, want no response", response, err)
	}
}
