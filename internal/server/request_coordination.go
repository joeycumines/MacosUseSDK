// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"

	"github.com/joeycumines/ExactMac/internal/transport"
)

const maxMCPRequestIDBytes = 1024

var errMCPNotificationCancelled = errors.New("cancelled by MCP notification")

type activeRequestKey struct {
	scope *transport.ClientScope
	id    string
}

type activeRequest struct {
	cancel    context.CancelCauseFunc
	cancelled bool
}

// beginMCPRequest creates the execution lifetime and, for cancellable
// transport-owned clients, atomically reserves the request ID. Its completion
// function reports whether cancellation won the completion race.
func (s *MCPServer) beginMCPRequest(msg *transport.Message) (
	context.Context,
	func() bool,
	*transport.Message,
) {
	requestCtx, cleanup := s.newRequestContext(msg.Context, msg.ClientScope)
	noRegistryCompletion := func() bool {
		clientClosed := msg.ClientScope != nil && errors.Is(context.Cause(msg.ClientScope.Context()), transport.ErrClientScopeClosed)
		cleanup()
		return clientClosed
	}
	if msg.ClientScope == nil || isJSONRPCNotification(msg) || msg.Method == "initialize" {
		return requestCtx, noRegistryCompletion, nil
	}

	requestID, err := canonicalMCPRequestID(msg.ID)
	if err != nil {
		cleanup()
		return nil, nil, invalidRequestResponse(msg.ID, err.Error())
	}
	key := activeRequestKey{scope: msg.ClientScope, id: requestID}
	active := &activeRequest{}
	requestCtx, active.cancel = context.WithCancelCause(requestCtx)

	s.activeMu.Lock()
	if s.activeRequests == nil {
		s.activeRequests = make(map[activeRequestKey]*activeRequest)
	}
	if _, exists := s.activeRequests[key]; exists {
		s.activeMu.Unlock()
		active.cancel(context.Canceled)
		cleanup()
		return nil, nil, invalidRequestResponse(msg.ID, "request ID is already active for this client")
	}
	s.activeRequests[key] = active
	s.activeMu.Unlock()

	complete := func() bool {
		s.activeMu.Lock()
		current, exists := s.activeRequests[key]
		cancelled := exists && current == active && active.cancelled
		if exists && current == active {
			delete(s.activeRequests, key)
		}
		s.activeMu.Unlock()
		clientClosed := errors.Is(context.Cause(msg.ClientScope.Context()), transport.ErrClientScopeClosed)
		active.cancel(context.Canceled)
		cleanup()
		return cancelled || clientClosed
	}
	return requestCtx, complete, nil
}

func (s *MCPServer) newRequestContext(requestCtx context.Context, scope *transport.ClientScope) (context.Context, context.CancelFunc) {
	serverCtx := s.ctx
	if serverCtx == nil {
		serverCtx = context.Background()
	}
	ctx, cancel := context.WithCancelCause(serverCtx)
	stops := make([]func() bool, 0, 2)
	link := func(parent context.Context) {
		if parent == nil {
			return
		}
		stops = append(stops, context.AfterFunc(parent, func() {
			cancel(context.Cause(parent))
		}))
		if parent.Err() != nil {
			cancel(context.Cause(parent))
		}
	}
	link(requestCtx)
	if scope != nil {
		link(scope.Context())
	}
	return ctx, func() {
		for _, stop := range stops {
			stop()
		}
		cancel(context.Canceled)
	}
}

func (s *MCPServer) cancelMCPRequest(scope *transport.ClientScope, rawID json.RawMessage) {
	if scope == nil {
		return
	}
	requestID, err := canonicalMCPRequestID(rawID)
	if err != nil {
		return
	}
	key := activeRequestKey{scope: scope, id: requestID}
	s.activeMu.Lock()
	active, ok := s.activeRequests[key]
	if ok && !active.cancelled {
		active.cancelled = true
		active.cancel(errMCPNotificationCancelled)
	}
	s.activeMu.Unlock()
}

func canonicalMCPRequestID(raw json.RawMessage) (string, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || len(trimmed) > maxMCPRequestIDBytes {
		return "", fmt.Errorf("request ID is missing or too large")
	}
	if trimmed[0] == '"' {
		var value string
		if err := json.Unmarshal(trimmed, &value); err != nil {
			return "", fmt.Errorf("request ID is not a valid string")
		}
		canonical, err := json.Marshal(value)
		if err != nil {
			return "", fmt.Errorf("canonicalize request ID: %w", err)
		}
		return "s:" + string(canonical), nil
	}
	var value big.Rat
	if _, ok := value.SetString(string(trimmed)); !ok {
		return "", fmt.Errorf("request ID is not a valid number")
	}
	return "n:" + value.RatString(), nil
}

func invalidRequestResponse(id json.RawMessage, message string) *transport.Message {
	return &transport.Message{
		JSONRPC: "2.0",
		ID:      id,
		Error: &transport.ErrorObj{
			Code:    transport.ErrCodeInvalidRequest,
			Message: message,
		},
	}
}
