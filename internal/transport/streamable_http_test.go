package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testMCPProtocolVersion = "2025-11-25"

func TestStreamableHTTP_SingleEndpointLifecycle(t *testing.T) {
	var calls atomic.Int64
	transport := NewHTTPTransport(&HTTPTransportConfig{})
	transport.handler = func(message *Message) (*Message, error) {
		calls.Add(1)
		if len(bytes.TrimSpace(message.ID)) == 0 {
			return nil, nil
		}
		return &Message{JSONRPC: "2.0", ID: message.ID, Result: json.RawMessage(`{"ok":true}`)}, nil
	}

	request := newStreamableHTTPTestRequest(http.MethodPost, `/mcp`, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	response := httptest.NewRecorder()
	transport.server.Handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("POST /mcp status=%d body=%q, want 200", response.Code, response.Body.String())
	}
	if contentType := response.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "application/json") {
		t.Fatalf("POST /mcp Content-Type=%q, want application/json", contentType)
	}
	sessionID := response.Header().Get("MCP-Session-Id")
	if sessionID == "" {
		t.Fatal("initialize omitted MCP-Session-Id")
	}

	notification := newStreamableHTTPTestRequest(http.MethodPost, `/mcp`, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	notification.Header.Set("MCP-Session-Id", sessionID)
	notificationResponse := httptest.NewRecorder()
	transport.server.Handler.ServeHTTP(notificationResponse, notification)
	if notificationResponse.Code != http.StatusAccepted || notificationResponse.Body.Len() != 0 {
		t.Fatalf("notification status=%d body=%q, want 202 with empty body", notificationResponse.Code, notificationResponse.Body.String())
	}

	getRequest := httptest.NewRequest(http.MethodGet, "/mcp", nil)
	getRequest.Header.Set("Accept", "text/event-stream")
	getRequest.Header.Set("MCP-Session-Id", sessionID)
	getResponse := httptest.NewRecorder()
	transport.server.Handler.ServeHTTP(getResponse, getRequest)
	if getResponse.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /mcp status=%d, want 405 for server without standalone SSE", getResponse.Code)
	}

	deleteRequest := httptest.NewRequest(http.MethodDelete, "/mcp", nil)
	deleteRequest.Header.Set("MCP-Session-Id", sessionID)
	deleteResponse := httptest.NewRecorder()
	transport.server.Handler.ServeHTTP(deleteResponse, deleteRequest)
	if deleteResponse.Code != http.StatusNoContent {
		t.Fatalf("DELETE /mcp status=%d, want 204", deleteResponse.Code)
	}

	for _, legacy := range []struct {
		method string
		path   string
	}{
		{method: http.MethodPost, path: "/message"},
		{method: http.MethodGet, path: "/events"},
	} {
		legacyRequest := httptest.NewRequest(legacy.method, legacy.path, nil)
		legacyResponse := httptest.NewRecorder()
		transport.server.Handler.ServeHTTP(legacyResponse, legacyRequest)
		if legacyResponse.Code != http.StatusNotFound {
			t.Errorf("legacy %s %s status=%d, want 404", legacy.method, legacy.path, legacyResponse.Code)
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("handler calls=%d, want exactly request plus notification", got)
	}
}

func TestStreamableHTTP_ValidatesRequiredHeaders(t *testing.T) {
	var calls atomic.Int64
	transport := NewHTTPTransport(&HTTPTransportConfig{})
	transport.handler = func(message *Message) (*Message, error) {
		calls.Add(1)
		return &Message{JSONRPC: "2.0", ID: message.ID, Result: json.RawMessage(`{}`)}, nil
	}
	body := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`

	tests := []struct {
		mutate     func(*http.Request)
		name       string
		wantStatus int
	}{
		{
			name: "missing Accept",
			mutate: func(request *http.Request) {
				request.Header.Del("Accept")
			},
			wantStatus: http.StatusNotAcceptable,
		},
		{
			name: "Accept omits event stream",
			mutate: func(request *http.Request) {
				request.Header.Set("Accept", "application/json")
			},
			wantStatus: http.StatusNotAcceptable,
		},
		{
			name: "missing content type",
			mutate: func(request *http.Request) {
				request.Header.Del("Content-Type")
			},
			wantStatus: http.StatusUnsupportedMediaType,
		},
		{
			name: "non-JSON content type",
			mutate: func(request *http.Request) {
				request.Header.Set("Content-Type", "text/plain")
			},
			wantStatus: http.StatusUnsupportedMediaType,
		},
		{
			name: "unsupported protocol version",
			mutate: func(request *http.Request) {
				request.Header.Set("MCP-Protocol-Version", "2099-01-01")
			},
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "current protocol version",
			mutate: func(request *http.Request) {
				request.Header.Set("MCP-Protocol-Version", testMCPProtocolVersion)
			},
			wantStatus: http.StatusOK,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := newStreamableHTTPTestRequest(http.MethodPost, "/mcp", body)
			test.mutate(request)
			response := httptest.NewRecorder()
			before := calls.Load()
			transport.server.Handler.ServeHTTP(response, request)
			if response.Code != test.wantStatus {
				t.Fatalf("status=%d body=%q, want %d", response.Code, response.Body.String(), test.wantStatus)
			}
			if test.wantStatus == http.StatusOK {
				if calls.Load() != before+1 {
					t.Fatal("valid request did not reach handler")
				}
			} else if calls.Load() != before {
				t.Fatal("invalid transport headers reached handler")
			}
		})
	}
}

func TestStreamableHTTP_DisconnectDoesNotCancelAdmittedRequest(t *testing.T) {
	testCtx, cancelTest := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelTest()
	transport := NewHTTPTransport(&HTTPTransportConfig{})
	sessionID, err := transport.createHTTPSession()
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	entered := make(chan context.Context, 1)
	release := make(chan struct{})
	handlerResult := make(chan error, 1)
	transport.handler = func(message *Message) (*Message, error) {
		entered <- message.Context
		select {
		case <-message.Context.Done():
			handlerResult <- message.Context.Err()
			return nil, message.Context.Err()
		case <-release:
			handlerResult <- nil
			return &Message{JSONRPC: "2.0", ID: message.ID, Result: json.RawMessage(`{}`)}, nil
		}
	}
	server := httptest.NewServer(transport.server.Handler)
	defer server.Close()

	requestCtx, cancelRequest := context.WithCancel(testCtx)
	request, err := http.NewRequestWithContext(
		requestCtx,
		http.MethodPost,
		server.URL+`/mcp`,
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`),
	)
	if err != nil {
		t.Fatalf("create disconnect request: %v", err)
	}
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("MCP-Session-Id", sessionID)
	clientResult := make(chan error, 1)
	go func() {
		response, err := server.Client().Do(request)
		if response != nil {
			_ = response.Body.Close()
		}
		clientResult <- err
	}()

	select {
	case <-entered:
	case <-testCtx.Done():
		t.Fatalf("request did not enter handler: %v", testCtx.Err())
	}
	cancelRequest()
	select {
	case err := <-clientResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("disconnected client error=%v, want context canceled", err)
		}
	case <-testCtx.Done():
		t.Fatalf("disconnected client did not return: %v", testCtx.Err())
	}
	close(release)
	select {
	case err := <-handlerResult:
		if err != nil {
			t.Fatalf("HTTP disconnect cancelled admitted MCP work: %v", err)
		}
	case <-testCtx.Done():
		t.Fatalf("handler did not finish after release: %v", testCtx.Err())
	}
}

func TestHTTPTransportClose_ForcesStalledNewConnectionAndPreservesFailure(t *testing.T) {
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve address: %v", err)
	}
	address := reserved.Addr().String()
	if err := reserved.Close(); err != nil {
		t.Fatalf("release reserved address: %v", err)
	}

	transport := NewHTTPTransport(&HTTPTransportConfig{
		Address:      address,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	})
	transport.shutdownTimeout = 25 * time.Millisecond
	accepted := make(chan struct{}, 1)
	transport.server.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			select {
			case accepted <- struct{}{}:
			default:
			}
		}
	}
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- transport.Serve(func(*Message) (*Message, error) { return nil, nil })
	}()

	dialCtx, cancelDial := context.WithTimeout(context.Background(), time.Second)
	defer cancelDial()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	var connection net.Conn
	for connection == nil {
		connection, err = (&net.Dialer{}).DialContext(dialCtx, "tcp", address)
		if err == nil {
			break
		}
		select {
		case <-dialCtx.Done():
			t.Fatalf("dial transport: %v", err)
		case <-ticker.C:
		}
	}
	defer connection.Close()

	select {
	case <-accepted:
	case <-dialCtx.Done():
		t.Fatal("transport never accepted stalled connection")
	}

	closeErr := transport.Close()
	if closeErr == nil || !strings.Contains(closeErr.Error(), "context deadline exceeded") {
		t.Fatalf("Close() error=%v, want truthful graceful-timeout failure", closeErr)
	}
	if err := connection.SetReadDeadline(time.Now().Add(250 * time.Millisecond)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	buffer := make([]byte, 1)
	if _, err := connection.Read(buffer); err == nil {
		t.Fatal("stalled connection remained readable after Close")
	} else if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		t.Fatalf("Close left stalled connection open until client deadline: %v", err)
	}

	select {
	case err := <-serveResult:
		if err != nil {
			t.Fatalf("Serve() error after forced shutdown: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Serve did not return after Close")
	}

	secondErr := transport.Close()
	if secondErr == nil || secondErr.Error() != closeErr.Error() {
		t.Fatalf("second Close() error=%v, want preserved %q", secondErr, closeErr)
	}
}

func TestHTTPTransportClose_BeforeServeRegistrationPreventsLateBind(t *testing.T) {
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve address: %v", err)
	}
	address := reserved.Addr().String()
	if err := reserved.Close(); err != nil {
		t.Fatalf("release reserved address: %v", err)
	}

	transport := NewHTTPTransport(&HTTPTransportConfig{
		Address:      address,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	})
	if err := transport.Close(); err != nil {
		t.Fatalf("close before Serve: %v", err)
	}

	serveResult := make(chan error, 1)
	go func() {
		serveResult <- transport.Serve(func(*Message) (*Message, error) { return nil, nil })
	}()

	select {
	case err := <-serveResult:
		if err == nil || !strings.Contains(err.Error(), "closed") {
			t.Fatalf("Serve() error=%v, want closed transport failure", err)
		}
	case <-time.After(250 * time.Millisecond):
		// Current deficient behavior binds after the only Close call has already
		// completed. Force cleanup so the failing test does not leak a listener.
		_ = transport.server.Close()
		<-serveResult
		t.Fatal("Serve remained active after transport was already closed")
	}

	dialer := net.Dialer{Timeout: 100 * time.Millisecond}
	connection, err := dialer.Dial("tcp", address)
	if err == nil {
		_ = connection.Close()
		t.Fatal("transport bound a listener after Close completed")
	}
}

func newStreamableHTTPTestRequest(method, path, body string) *http.Request {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Content-Type", "application/json")
	return request
}
