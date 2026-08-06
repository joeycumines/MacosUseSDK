// Copyright 2026 Joseph Cumines

package transport

import (
	"context"
	"errors"
	"sync"
)

// ErrClientScopeClosed is the cancellation cause for work owned by a client
// whose transport session has ended.
var ErrClientScopeClosed = errors.New("MCP client scope closed")

// ClientScope is opaque transport-owned client identity and lifetime state.
// Server code keys active requests by pointer identity, so an untrusted session
// string can never alias another client's requests.
type ClientScope struct {
	ctx    context.Context
	cancel context.CancelCauseFunc
	once   sync.Once
}

// NewClientScope creates an independent client lifetime.
func NewClientScope() *ClientScope {
	ctx, cancel := context.WithCancelCause(context.Background())
	return &ClientScope{ctx: ctx, cancel: cancel}
}

// Context is cancelled when the owning transport session ends.
func (s *ClientScope) Context() context.Context {
	if s == nil || s.ctx == nil {
		return context.Background()
	}
	return s.ctx
}

// Close permanently ends this client lifetime. It is idempotent.
func (s *ClientScope) Close() {
	if s == nil {
		return
	}
	s.once.Do(func() {
		s.cancel(ErrClientScopeClosed)
	})
}
