// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/transport"
)

func TestRequestAdmissionGlobalPerClientNonBlockingAndReusable(t *testing.T) {
	admission := newTestRequestAdmission(t, 2, 1)
	scopeA := transport.NewClientScope()
	scopeB := transport.NewClientScope()
	defer scopeA.Close()
	defer scopeB.Close()

	leaseA, ok := admission.tryAcquire(scopeA)
	if !ok || leaseA == nil {
		t.Fatal("first client A request was not admitted")
	}
	if lease, ok := admission.tryAcquire(scopeA); ok || lease != nil {
		t.Fatal("client A exceeded its per-client request budget")
	}
	leaseB, ok := admission.tryAcquire(scopeB)
	if !ok || leaseB == nil {
		t.Fatal("client B could not use independent global capacity")
	}
	if lease, ok := admission.tryAcquire(nil); ok || lease != nil {
		t.Fatal("request exceeded the global request budget")
	}

	leaseA.release()
	leaseA.release()
	nilScopeLease, ok := admission.tryAcquire(nil)
	if !ok || nilScopeLease == nil {
		t.Fatal("released global capacity was not reusable")
	}
	if lease, ok := admission.tryAcquire(scopeB); ok || lease != nil {
		t.Fatal("client B exceeded its per-client request budget while global capacity remained")
	}

	leaseB.release()
	nilScopeLease.release()
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if admission.active != 0 || len(admission.clients) != 0 {
		t.Fatalf("released admission state = active %d clients %v, want empty", admission.active, admission.clients)
	}
}

func TestRequestAdmissionDrainRejectsNewAndWaitsForAllLeases(t *testing.T) {
	admission := newTestRequestAdmission(t, 2, 1)
	scope := transport.NewClientScope()
	defer scope.Close()
	lease, ok := admission.tryAcquire(scope)
	if !ok || lease == nil {
		t.Fatal("initial request was not admitted")
	}

	drained := admission.beginDrain()
	select {
	case <-drained:
		t.Fatal("admission drained while a lease remained active")
	default:
	}
	if extra, ok := admission.tryAcquire(nil); ok || extra != nil {
		t.Fatal("draining admission accepted new work")
	}
	if repeated := admission.beginDrain(); repeated != drained {
		t.Fatal("repeated drain returned a different completion channel")
	}

	lease.release()
	lease.release()
	select {
	case <-drained:
	case <-time.After(time.Second):
		t.Fatal("admission did not drain after its final lease released")
	}
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if admission.active != 0 || len(admission.clients) != 0 {
		t.Fatalf("drained admission state = active %d clients %v, want empty", admission.active, admission.clients)
	}
}

func TestMCPRequestAdmissionCancellationAndClientCloseBypassSaturation(t *testing.T) {
	serverContext, cancelServer := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelServer()
	entered := make(chan string, 4)
	server := &MCPServer{
		ctx:            serverContext,
		admission:      newTestRequestAdmission(t, 2, 1),
		activeRequests: make(map[activeRequestKey]*activeRequest),
		tools: map[string]*Tool{
			"block": blockingCancellationTestTool(entered),
		},
	}
	scopeA := transport.NewClientScope()
	scopeB := transport.NewClientScope()
	scopeC := transport.NewClientScope()
	defer scopeA.Close()
	defer scopeB.Close()
	defer scopeC.Close()

	type result struct {
		response *transport.Message
		err      error
	}
	results := make(chan result, 3)
	invoke := func(scope *transport.ClientScope, id int, label string) {
		params, err := json.Marshal(map[string]any{
			"name":      "block",
			"arguments": map[string]any{"label": label},
		})
		if err != nil {
			results <- result{err: err}
			return
		}
		response, err := server.handleHTTPMessage(&transport.Message{
			ClientScope: scope,
			JSONRPC:     "2.0",
			ID:          json.RawMessage(strconv.Itoa(id)),
			Method:      "tools/call",
			Params:      params,
		})
		results <- result{response: response, err: err}
	}

	go invoke(scopeA, 1, "a")
	requireRequestAdmissionEntry(t, serverContext, entered, "a")
	assertRequestAdmissionBusy(t, server, scopeA, 2, "same-client overflow")
	assertRequestAdmissionNotificationDropped(t, server, scopeA, "same-client notification")

	go invoke(scopeB, 1, "b")
	requireRequestAdmissionEntry(t, serverContext, entered, "b")
	assertRequestAdmissionBusy(t, server, scopeC, 1, "global overflow")

	cancelMCPTestRequest(t, server, scopeA, json.RawMessage(`1`))
	first := <-results
	if first.response != nil || !errors.Is(first.err, transport.ErrRequestCancelled) {
		t.Fatalf("cancelled client A result=(%+v, %v), want suppressed cancellation", first.response, first.err)
	}

	go invoke(scopeC, 1, "c")
	requireRequestAdmissionEntry(t, serverContext, entered, "c")
	scopeB.Close()
	second := <-results
	if second.response != nil || !errors.Is(second.err, transport.ErrRequestCancelled) {
		t.Fatalf("closed client B result=(%+v, %v), want suppressed cancellation", second.response, second.err)
	}
	cancelMCPTestRequest(t, server, scopeC, json.RawMessage(`1`))
	third := <-results
	if third.response != nil || !errors.Is(third.err, transport.ErrRequestCancelled) {
		t.Fatalf("cancelled client C result=(%+v, %v), want suppressed cancellation", third.response, third.err)
	}

	drained := server.admission.beginDrain()
	select {
	case <-drained:
	case <-serverContext.Done():
		t.Fatalf("request admission did not return to zero: %v", serverContext.Err())
	}
}

func TestMCPServerShutdownWaitsForRequestAdmissionDrain(t *testing.T) {
	serverContext, cancelServer := context.WithCancel(context.Background())
	entered := make(chan struct{})
	cancellationObserved := make(chan struct{})
	release := make(chan struct{})
	server := &MCPServer{
		ctx:            serverContext,
		cancel:         cancelServer,
		admission:      newTestRequestAdmission(t, 1, 1),
		activeRequests: make(map[activeRequestKey]*activeRequest),
		tools: map[string]*Tool{
			"resistant": {
				Name:           "resistant",
				MutationPolicy: mutationPolicyReadOnly,
				InputSchema: map[string]any{
					"type":                 "object",
					"properties":           map[string]any{},
					"additionalProperties": false,
				},
				Handler: func(call *ToolCall) (*ToolResult, error) {
					close(entered)
					<-call.Context.Done()
					close(cancellationObserved)
					<-release
					return textResult("released"), nil
				},
			},
		},
	}
	scope := transport.NewClientScope()
	defer scope.Close()
	requestResult := make(chan error, 1)
	go func() {
		_, err := server.handleHTTPMessage(&transport.Message{
			ClientScope: scope,
			JSONRPC:     "2.0",
			ID:          json.RawMessage(`1`),
			Method:      "tools/call",
			Params:      json.RawMessage(`{"name":"resistant","arguments":{}}`),
		})
		requestResult <- err
	}()
	<-entered

	shutdownResult := make(chan error, 1)
	go func() {
		shutdownResult <- server.Shutdown()
	}()
	<-cancellationObserved
	select {
	case err := <-shutdownResult:
		t.Fatalf("Shutdown returned before resistant admitted request released: %v", err)
	default:
	}
	response, err := server.handleHTTPMessage(&transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`2`),
		Method:  "ping",
	})
	if err != nil || response == nil || response.Error == nil || response.Error.Code != transport.ErrCodeServerBusy {
		t.Fatalf("post-drain admission response=%+v error=%v, want server busy", response, err)
	}

	close(release)
	if err := <-requestResult; err != nil {
		t.Fatalf("resistant admitted request returned error after release: %v", err)
	}
	if err := <-shutdownResult; err != nil {
		t.Fatalf("Shutdown after request drain: %v", err)
	}
}

func assertRequestAdmissionBusy(
	t *testing.T,
	server *MCPServer,
	scope *transport.ClientScope,
	id int,
	label string,
) {
	t.Helper()
	params, err := json.Marshal(map[string]any{
		"name":      "block",
		"arguments": map[string]any{"label": label},
	})
	if err != nil {
		t.Fatalf("marshal %s: %v", label, err)
	}
	response, err := server.handleHTTPMessage(&transport.Message{
		ClientScope: scope,
		JSONRPC:     "2.0",
		ID:          json.RawMessage(strconv.Itoa(id)),
		Method:      "tools/call",
		Params:      params,
	})
	if err != nil || response == nil || response.Error == nil {
		t.Fatalf("%s response=%+v error=%v, want server-busy error", label, response, err)
	}
	if response.Error.Code != transport.ErrCodeServerBusy || response.Error.Message != requestAdmissionBusyMessage {
		t.Fatalf("%s error=%+v, want code %d message %q", label, response.Error, transport.ErrCodeServerBusy, requestAdmissionBusyMessage)
	}
}

func assertRequestAdmissionNotificationDropped(
	t *testing.T,
	server *MCPServer,
	scope *transport.ClientScope,
	label string,
) {
	t.Helper()
	params, err := json.Marshal(map[string]any{
		"name":      "block",
		"arguments": map[string]any{"label": label},
	})
	if err != nil {
		t.Fatalf("marshal %s: %v", label, err)
	}
	response, err := server.handleHTTPMessage(&transport.Message{
		ClientScope: scope,
		JSONRPC:     "2.0",
		Method:      "tools/call",
		Params:      params,
	})
	if err != nil || response != nil {
		t.Fatalf("overloaded notification response=%+v error=%v, want dropped notification", response, err)
	}
}

func requireRequestAdmissionEntry(
	t *testing.T,
	ctx context.Context,
	entered <-chan string,
	want string,
) {
	t.Helper()
	select {
	case got := <-entered:
		if got != want {
			t.Fatalf("handler entry = %q, want %q", got, want)
		}
	case <-ctx.Done():
		t.Fatalf("handler %q did not enter: %v", want, ctx.Err())
	}
}

func newTestRequestAdmission(t *testing.T, globalLimit, clientLimit int) *requestAdmission {
	t.Helper()
	admission, err := newRequestAdmission(globalLimit, clientLimit)
	if err != nil {
		t.Fatalf("new request admission: %v", err)
	}
	return admission
}
