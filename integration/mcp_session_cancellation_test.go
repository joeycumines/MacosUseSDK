package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

func TestMCPSessionCancellation_HTTPClientIsolation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	client := &http.Client{Timeout: 15 * time.Second}
	sessionA := initializeHTTPSession(t, ctx, client, baseURL, 1)
	sessionB := initializeHTTPSession(t, ctx, client, baseURL, 2)
	if sessionA == sessionB {
		t.Fatalf("independent HTTP clients received the same session ID %q", sessionA)
	}

	missing := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, "", `{"jsonrpc":"2.0","id":3,"method":"ping"}`)
	if missing.Status != http.StatusBadRequest {
		t.Fatalf("sessionless post-initialize request status=%d body=%q, want 400", missing.Status, missing.Body)
	}
	unknown := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, "unknown-session", `{"jsonrpc":"2.0","id":4,"method":"ping"}`)
	if unknown.Status != http.StatusNotFound {
		t.Fatalf("unknown-session request status=%d body=%q, want 404", unknown.Status, unknown.Body)
	}

	const sharedRequestID = 77
	waitAPayload := `{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"wait","arguments":{"duration":10}}}`
	waitBPayload := `{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"wait","arguments":{"duration":1.5}}}`
	waitA := make(chan sessionHTTPResult, 1)
	waitB := make(chan sessionHTTPResult, 1)
	go func() {
		waitA <- sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionA, waitAPayload)
	}()
	go func() {
		waitB <- sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionB, waitBPayload)
	}()

	resultA := cancelSessionRequestUntilDone(t, ctx, client, baseURL, sessionA, sharedRequestID, waitA)
	if resultA.Status != http.StatusNoContent || len(resultA.Body) != 0 {
		t.Fatalf("cancelled session A request status=%d body=%q, want 204 empty", resultA.Status, resultA.Body)
	}
	var resultB sessionHTTPResult
	select {
	case resultB = <-waitB:
	case <-ctx.Done():
		t.Fatalf("session B did not finish independently: %v", ctx.Err())
	}
	if resultB.Err != nil || resultB.Status != http.StatusOK || !bytes.Contains(resultB.Body, []byte("Waited 1.5s")) {
		t.Fatalf("session A cancellation affected session B: status=%d body=%q error=%v", resultB.Status, resultB.Body, resultB.Err)
	}
	if !resultB.Completed.After(resultA.Completed) {
		t.Fatalf("session B completed before session A cancellation; overlap was not proved: a=%s b=%s", resultA.Completed, resultB.Completed)
	}

	waitBIndependent := make(chan sessionHTTPResult, 1)
	go func() {
		waitBIndependent <- sendSessionMCP(
			t,
			ctx,
			client,
			baseURL,
			http.MethodPost,
			sessionB,
			`{"jsonrpc":"2.0","id":78,"method":"tools/call","params":{"name":"wait","arguments":{"duration":10}}}`,
		)
	}()
	resultB = cancelSessionRequestUntilDone(t, ctx, client, baseURL, sessionB, 78, waitBIndependent)
	if resultB.Status != http.StatusNoContent || len(resultB.Body) != 0 {
		t.Fatalf("independently cancelled session B request status=%d body=%q, want 204 empty", resultB.Status, resultB.Body)
	}

	for _, sessionID := range []string{sessionA, sessionB} {
		terminated := sendSessionMCP(t, ctx, client, baseURL, http.MethodDelete, sessionID, "")
		if terminated.Status != http.StatusNoContent || len(terminated.Body) != 0 {
			t.Fatalf("terminate session %q status=%d body=%q, want 204 empty", sessionID, terminated.Status, terminated.Body)
		}
		stale := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, `{"jsonrpc":"2.0","id":99,"method":"ping"}`)
		if stale.Status != http.StatusNotFound {
			t.Fatalf("terminated session %q status=%d body=%q, want 404", sessionID, stale.Status, stale.Body)
		}
	}
}

type sessionHTTPResult struct {
	Completed time.Time
	Header    http.Header
	Body      []byte
	Err       error
	Status    int
}

func initializeHTTPSession(t *testing.T, ctx context.Context, client *http.Client, baseURL string, id int) string {
	t.Helper()
	result := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, "", validMCPInitializePayload(id))
	if result.Err != nil || result.Status != http.StatusOK {
		t.Fatalf("initialize HTTP session %d status=%d body=%q error=%v", id, result.Status, result.Body, result.Err)
	}
	var response mcpResponse
	if err := json.Unmarshal(result.Body, &response); err != nil || response.Error != nil {
		t.Fatalf("decode initialize HTTP session %d response=%+v error=%v body=%q", id, response, err, result.Body)
	}
	sessionID := result.Header.Get("MCP-Session-Id")
	if sessionID == "" {
		t.Fatalf("initialize HTTP session %d omitted MCP-Session-Id", id)
	}
	return sessionID
}

func cancelSessionRequestUntilDone(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	done <-chan sessionHTTPResult,
) sessionHTTPResult {
	t.Helper()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case result := <-done:
			if result.Err != nil {
				t.Fatalf("cancelled session request returned transport error: %v", result.Err)
			}
			return result
		case <-ticker.C:
			payload, err := json.Marshal(map[string]any{
				"jsonrpc": "2.0",
				"method":  "notifications/cancelled",
				"params": map[string]any{
					"requestId": requestID,
					"reason":    "integration cancellation",
				},
			})
			if err != nil {
				t.Fatalf("marshal cancellation notification: %v", err)
			}
			cancelResult := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, string(payload))
			if cancelResult.Err != nil || cancelResult.Status != http.StatusAccepted || len(cancelResult.Body) != 0 {
				t.Fatalf(
					"cancellation notification status=%d body=%q error=%v, want 202 empty",
					cancelResult.Status,
					cancelResult.Body,
					cancelResult.Err,
				)
			}
		case <-ctx.Done():
			t.Fatalf("session cancellation did not complete: %v", ctx.Err())
		}
	}
}

func sendSessionMCP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	method string,
	sessionID string,
	payload string,
) sessionHTTPResult {
	t.Helper()
	var body io.Reader
	if payload != "" {
		body = bytes.NewBufferString(payload)
	}
	request, err := newProductionMCPRequest(ctx, method, baseURL, body)
	if err != nil {
		return sessionHTTPResult{Completed: time.Now(), Err: err}
	}
	if sessionID != "" {
		request.Header.Set("MCP-Session-Id", sessionID)
	}
	response, err := client.Do(request)
	if err != nil {
		return sessionHTTPResult{Completed: time.Now(), Err: err}
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return sessionHTTPResult{Completed: time.Now(), Err: err}
	}
	return sessionHTTPResult{
		Completed: time.Now(),
		Status:    response.StatusCode,
		Header:    response.Header.Clone(),
		Body:      responseBody,
	}
}
