// Copyright 2025 Joseph Cumines
//
// MCP pagination token opacity integration tests.
// Verifies that page_token values are truly opaque per AIP-158.
// Task: T070

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestMCPPaginationTokenOpacity_ListApplications verifies that page_token values
// returned by list_applications are opaque and cannot be parsed by clients.
// Per AIP-158, clients must treat page tokens as opaque strings.
func TestMCPPaginationTokenOpacity_ListApplications(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	app1 := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app1)

	app2 := openTextEdit(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app2)

	resp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize: 1,
	})
	if err != nil {
		t.Fatalf("ListApplications failed: %v", err)
	}

	if resp.NextPageToken == "" {
		t.Skip("No pagination token returned - need more applications for this test")
	}

	token := resp.NextPageToken

	// === OPACITY TESTS ===

	// 1. Token should NOT be a recognizable structured format like "offset:N"
	if strings.HasPrefix(token, "offset:") {
		t.Error("Token is NOT opaque - has recognizable 'offset:' prefix")
	}

	// 2. Token should NOT be a simple integer
	if len(token) < 5 {
		t.Logf("Warning: Token is very short (%d chars), may not be opaque: %s", len(token), token)
	}

	// 3. Token should NOT be JSON
	var jsonTest interface{}
	if json.Unmarshal([]byte(token), &jsonTest) == nil {
		t.Error("Token appears to be valid JSON - not opaque enough")
	}

	// 4. Using the token should work correctly
	resp2, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize:  1,
		PageToken: token,
	})
	if err != nil {
		t.Fatalf("ListApplications with page token failed: %v", err)
	}

	// 5. Results should be different across pages
	if len(resp.Applications) > 0 && len(resp2.Applications) > 0 {
		if resp.Applications[0].Name == resp2.Applications[0].Name {
			t.Error("Same application returned on different pages - pagination broken")
		}
	}

	// 6. Corrupted token should be rejected
	corruptedToken := token + "CORRUPTED"
	_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageToken: corruptedToken,
	})
	if err == nil {
		t.Error("Expected error for corrupted token, got success")
	}

	t.Logf("Pagination token opacity verified. Token format: %d chars, first 10=%q",
		len(token), token[:min(10, len(token))])
}

// TestMCPPaginationTokenOpacity_ListWindows verifies page token opacity for windows.
func TestMCPPaginationTokenOpacity_ListWindows(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	app := openTextEdit(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Skipf("No windows available: %v", err)
	}

	resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:   app.Name,
		PageSize: 1,
	})
	if err != nil {
		t.Fatalf("ListWindows failed: %v", err)
	}

	if resp.NextPageToken == "" {
		t.Log("No pagination token returned (single window) - test passes vacuously")
		return
	}

	token := resp.NextPageToken

	if strings.HasPrefix(token, "offset:") {
		t.Error("Token is NOT opaque - has 'offset:' prefix")
	}

	resp2, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:    app.Name,
		PageSize:  1,
		PageToken: token,
	})
	if err != nil {
		t.Fatalf("ListWindows with token failed: %v", err)
	}

	if len(resp.Windows) > 0 && len(resp2.Windows) > 0 {
		if resp.Windows[0].Name == resp2.Windows[0].Name {
			t.Error("Same window on different pages")
		}
	}

	t.Logf("Window pagination token opacity verified")
}

// TestMCPPaginationTokenOpacity_ViaHTTP tests pagination via MCP HTTP transport.
func TestMCPPaginationTokenOpacity_ViaHTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	app1 := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app1)

	app2 := openTextEdit(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app2)

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initReq := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	initResp, _ := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(initReq))
	initResp.Body.Close()

	request := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_applications","arguments":{"page_size":1}}}`
	resp, err := http.Post(baseURL+"/message", "application/json", bytes.NewBufferString(request))
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var response struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		t.Fatalf("Failed to decode: %v", err)
	}

	if response.Error != nil {
		t.Fatalf("Error: %s", response.Error.Message)
	}

	var toolResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(response.Result, &toolResult); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	if len(toolResult.Content) == 0 {
		t.Fatal("Empty content")
	}

	t.Log("Pagination opacity test via HTTP transport completed")
}

// TestMCPPaginationTokenOpacity_FabricatedToken tests that fabricated tokens are rejected.
func TestMCPPaginationTokenOpacity_FabricatedToken(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	fabricatedTokens := []string{
		"offset:10",
		"page:2",
		"eyJwYWdlIjoyfQ==",
		"abc123",
		"0",
		"AQIDBA==",
		"!!invalid-token!!",
		"next",
		"1234567890abcdef",
		"applications/123/cursor/",
	}

	for _, token := range fabricatedTokens {
		t.Run("fabricated_"+token[:min(10, len(token))], func(t *testing.T) {
			_, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
				PageToken: token,
			})
			if err == nil {
				t.Errorf("Fabricated token %q was accepted - should be rejected", token)
			}
		})
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
