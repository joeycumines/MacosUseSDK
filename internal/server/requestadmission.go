// Copyright 2026 Joseph Cumines

package server

import (
	"encoding/json"
	"fmt"
	"sync"

	"github.com/joeycumines/ExactMac/internal/transport"
)

const (
	defaultMaxConcurrentMCPRequests          = 512
	defaultMaxConcurrentMCPRequestsPerClient = 256
	requestAdmissionBusyMessage              = "server request capacity reached"
)

type requestAdmission struct {
	drained     chan struct{}
	clients     map[*transport.ClientScope]int
	globalLimit int
	clientLimit int
	active      int
	draining    bool
	drainClosed bool
	mu          sync.Mutex
}

type requestAdmissionLease struct {
	admission *requestAdmission
	scope     *transport.ClientScope
	once      sync.Once
}

type preparedMCPMessage struct {
	message    *transport.Message
	complete   func() bool
	lease      *requestAdmissionLease
	finishOnce sync.Once
	cancelled  bool
}

func newRequestAdmission(globalLimit, clientLimit int) (*requestAdmission, error) {
	if globalLimit <= 0 {
		return nil, fmt.Errorf("global request limit must be positive")
	}
	if clientLimit <= 0 {
		return nil, fmt.Errorf("per-client request limit must be positive")
	}
	if clientLimit > globalLimit {
		return nil, fmt.Errorf("per-client request limit must not exceed global request limit")
	}
	return &requestAdmission{
		drained:     make(chan struct{}),
		clients:     make(map[*transport.ClientScope]int),
		globalLimit: globalLimit,
		clientLimit: clientLimit,
	}, nil
}

func (a *requestAdmission) tryAcquire(scope *transport.ClientScope) (*requestAdmissionLease, bool) {
	if a == nil {
		return nil, false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.draining || a.active >= a.globalLimit {
		return nil, false
	}
	if scope != nil && a.clients[scope] >= a.clientLimit {
		return nil, false
	}
	a.active++
	if scope != nil {
		a.clients[scope]++
	}
	return &requestAdmissionLease{admission: a, scope: scope}, true
}

func (a *requestAdmission) beginDrain() <-chan struct{} {
	if a == nil {
		closed := make(chan struct{})
		close(closed)
		return closed
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.draining = true
	a.closeDrainedLocked()
	return a.drained
}

func (a *requestAdmission) release(scope *transport.ClientScope) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.active <= 0 {
		panic("request admission lease released without active request")
	}
	a.active--
	if scope != nil {
		count := a.clients[scope]
		if count <= 0 {
			panic("request admission client lease released without active request")
		}
		if count == 1 {
			delete(a.clients, scope)
		} else {
			a.clients[scope] = count - 1
		}
	}
	a.closeDrainedLocked()
}

func (a *requestAdmission) closeDrainedLocked() {
	if a.draining && a.active == 0 && !a.drainClosed {
		a.drainClosed = true
		close(a.drained)
	}
}

func (l *requestAdmissionLease) release() {
	if l == nil || l.admission == nil {
		return
	}
	l.once.Do(func() {
		l.admission.release(l.scope)
	})
}

func (s *MCPServer) requestAdmissionController() *requestAdmission {
	s.admissionOnce.Do(func() {
		if s.admission != nil {
			return
		}
		admission, err := newRequestAdmission(
			defaultMaxConcurrentMCPRequests,
			defaultMaxConcurrentMCPRequestsPerClient,
		)
		if err != nil {
			panic(err)
		}
		s.admission = admission
	})
	return s.admission
}

func (s *MCPServer) prepareMCPMessage(msg *transport.Message) (*preparedMCPMessage, *transport.Message) {
	if requestErr := transport.ValidateRequest(msg); requestErr != nil {
		return nil, &transport.Message{
			JSONRPC: "2.0",
			ID:      json.RawMessage("null"),
			Error: &transport.ErrorObj{
				Code:    requestErr.Code,
				Message: requestErr.Message,
			},
		}
	}
	if msg.Method == "notifications/cancelled" {
		if !isJSONRPCNotification(msg) {
			return nil, invalidRequestResponse(msg.ID, "notifications/cancelled must not have an id")
		}
		var params struct {
			RequestID json.RawMessage `json:"requestId"`
		}
		if err := json.Unmarshal(msg.Params, &params); err == nil {
			s.cancelMCPRequest(msg.ClientScope, params.RequestID)
		}
		return nil, nil
	}

	lease, admitted := s.requestAdmissionController().tryAcquire(msg.ClientScope)
	if !admitted {
		if isJSONRPCNotification(msg) {
			return nil, nil
		}
		return nil, &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &transport.ErrorObj{
				Code:    transport.ErrCodeServerBusy,
				Message: requestAdmissionBusyMessage,
			},
		}
	}

	requestContext, complete, admissionError := s.beginMCPRequest(msg)
	if admissionError != nil {
		lease.release()
		return nil, admissionError
	}
	msg.Context = requestContext
	return &preparedMCPMessage{message: msg, complete: complete, lease: lease}, nil
}

func (s *MCPServer) executePreparedMCPMessage(prepared *preparedMCPMessage) (*transport.Message, error) {
	if prepared == nil || prepared.message == nil {
		return nil, fmt.Errorf("prepared MCP message is required")
	}
	defer prepared.finish()
	response, err := s.dispatchMCPMessage(prepared.message)
	if prepared.finish() {
		return nil, transport.ErrRequestCancelled
	}
	if isJSONRPCNotification(prepared.message) {
		return nil, nil
	}
	return response, err
}

func (p *preparedMCPMessage) finish() bool {
	if p == nil {
		return false
	}
	p.finishOnce.Do(func() {
		if p.complete != nil {
			p.cancelled = p.complete()
		}
		p.lease.release()
	})
	return p.cancelled
}
