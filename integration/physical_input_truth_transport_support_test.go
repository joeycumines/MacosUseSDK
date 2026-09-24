// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func callPhysicalHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	session string,
	requestID int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	response := callNonApplicationMatrixHTTP(
		t,
		ctx,
		client,
		baseURL,
		session,
		requestID,
		name,
		arguments,
	)
	if response.Error != nil || string(response.ID) != strconv.Itoa(requestID) {
		t.Fatalf("HTTP %s response=%+v", name, response)
	}
	return decodePhysicalToolResult(t, name, response.Result)
}

func cancelAdmittedPhysicalRequestOnce(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	done <-chan sessionHTTPResult,
) sessionHTTPResult {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/cancelled",
		"params": map[string]any{
			"requestId": requestID,
			"reason":    "physical truth cancellation",
		},
	})
	if err != nil {
		t.Fatalf("marshal physical cancellation notification: %v", err)
	}
	cancelResult := sendSessionMCP(
		t,
		ctx,
		client,
		baseURL,
		http.MethodPost,
		sessionID,
		string(payload),
	)
	if cancelResult.Err != nil ||
		cancelResult.Status != http.StatusAccepted ||
		len(cancelResult.Body) != 0 {
		t.Fatalf(
			"physical cancellation notification status=%d body=%q error=%v, want 202 empty",
			cancelResult.Status,
			cancelResult.Body,
			cancelResult.Err,
		)
	}
	select {
	case result := <-done:
		if result.Err != nil {
			t.Fatalf("cancelled physical request returned transport error: %v", result.Err)
		}
		return result
	case <-ctx.Done():
		t.Fatalf("admitted physical request did not settle after one cancellation: %v", ctx.Err())
		return sessionHTTPResult{}
	}
}

func callPhysicalStdio(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
	requestID int,
	name string,
	arguments map[string]any,
) productionMCPToolResult {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      name,
			"arguments": arguments,
		},
	})
	if err != nil || response == nil || response.Error != nil ||
		string(response.ID) != strconv.Itoa(requestID) {
		t.Fatalf("stdio %s response=%+v error=%v", name, response, err)
	}
	return decodePhysicalToolResult(t, name, response.Result)
}

func decodePhysicalToolResult(
	t *testing.T,
	name string,
	raw json.RawMessage,
) productionMCPToolResult {
	t.Helper()
	var result productionMCPToolResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("decode %s result: %v raw=%s", name, err, raw)
	}
	if result.IsError || len(result.Content) == 0 || result.Content[0].Text == "" {
		t.Fatalf("%s returned false or empty MCP success: %+v", name, result)
	}
	return result
}

func requireCompletedMCPInput(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
	expectedPosts int32,
	result productionMCPToolResult,
) *pb.Input {
	t.Helper()
	after := listInputSnapshot(t, ctx, client, parent)
	input := requireOneNewInput(t, before, after, target, action)
	requireInputTerminalEvidence(
		t,
		input,
		pb.Input_STATE_COMPLETED,
		pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
		expectedPosts,
		expectedPosts,
	)
	if !strings.Contains(result.Content[0].Text, input.GetName()) {
		t.Fatalf("MCP result %q omits exact Input %q", result.Content[0].Text, input.GetName())
	}
	requireInputRoundTrip(t, ctx, client, parent, input)
	return input
}

func waitForMCPInputExecution(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
) {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		after := listInputSnapshot(t, waitCtx, client, parent)
		if len(after) != len(before)+1 {
			return false, nil
		}
		input := requireOneNewInput(t, before, after, target, action)
		return input.GetState() == pb.Input_STATE_EXECUTING, nil
	}); err != nil {
		t.Fatalf("MCP Input did not enter EXECUTING: %v", err)
	}
}

func requireCancelledMCPInput(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	parent string,
	before map[string]*pb.Input,
	target *pb.InputTarget,
	action *pb.InputAction,
	maximumPosts int32,
) *pb.Input {
	t.Helper()
	waitCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	var terminal *pb.Input
	if err := PollUntilContext(waitCtx, 20*time.Millisecond, func() (bool, error) {
		after := listInputSnapshot(t, waitCtx, client, parent)
		if len(after) != len(before)+1 {
			return false, nil
		}
		input := requireOneNewInput(t, before, after, target, action)
		if input.GetState() != pb.Input_STATE_CANCELLED {
			return false, nil
		}
		terminal = input
		return true, nil
	}); err != nil {
		t.Fatalf("MCP Input did not settle CANCELLED: %v", err)
	}
	requireInputTerminalEvidence(
		t,
		terminal,
		pb.Input_STATE_CANCELLED,
		pb.InputDeliveryResult_COMMITMENT_POSSIBLY_COMMITTED,
		1,
		maximumPosts,
	)
	requireInputRoundTrip(t, ctx, client, parent, terminal)
	return terminal
}
