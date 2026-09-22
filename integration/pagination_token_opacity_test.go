// Copyright 2025 Joseph Cumines
//
// MCP pagination token opacity integration tests.
// Verifies that page_token values are truly opaque per AIP-158.
// Task: T070

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// TestMCPPaginationTokenOpacity_ListApplications verifies that page_token values
// returned by ListApplications are opaque and cannot be parsed by clients.
// Per AIP-158, clients must treat page tokens as opaque strings.
func TestMCPPaginationTokenOpacity_ListApplications(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	calculatorCtx, cancelCalculator := context.WithTimeout(ctx, 30*time.Second)
	app1 := openCalculator(t, calculatorCtx, client)
	cancelCalculator()
	defer cleanupPaginationApplication(t, client, app1)

	// This test needs a second tracked application, not a TextEdit document or
	// window. Avoid the openTextEdit helper's unrelated AppleScript mutation.
	killTextEdit(t)
	textEditCtx, cancelTextEdit := context.WithTimeout(ctx, 30*time.Second)
	app2 := OpenApplicationObserved(t, textEditCtx, client, "com.apple.TextEdit")
	cancelTextEdit()
	defer cleanupPaginationApplication(t, client, app2)

	queryCtx, cancelQuery := context.WithTimeout(ctx, 15*time.Second)
	defer cancelQuery()
	resp, err := client.ListApplications(queryCtx, &pb.ListApplicationsRequest{
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
	var jsonTest any
	if json.Unmarshal([]byte(token), &jsonTest) == nil {
		t.Error("Token appears to be valid JSON - not opaque enough")
	}

	// 4. Using the token should work correctly
	resp2, err := client.ListApplications(queryCtx, &pb.ListApplicationsRequest{
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
	_, err = client.ListApplications(queryCtx, &pb.ListApplicationsRequest{
		PageToken: corruptedToken,
	})
	if err == nil {
		t.Error("Expected error for corrupted token, got success")
	}

	t.Logf("Pagination token opacity verified. Token format: %d chars, first 10=%q",
		len(token), token[:min(10, len(token))])
}

func cleanupPaginationApplication(t *testing.T, client pb.ExactMacClient, app *pb.Application) {
	t.Helper()
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cleanupApplication(t, cleanupCtx, client, app)
}

// TestMCPPaginationTokenOpacity_ListWindows verifies page token opacity for windows.
func TestMCPPaginationTokenOpacity_ListWindows(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)
	app := openTextEdit(t, ctx, client)
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

	client := pb.NewExactMacClient(conn)
	// list_windows pagination requires at least two windows in one application.
	// Own two uniquely named non-empty files instead of depending on TextEdit's
	// global front document or an unbounded AppleScript mutation.
	killTextEdit(t)
	fixtureDir := t.TempDir()
	fixtureID := time.Now().UnixNano()
	fileNames := []string{
		fmt.Sprintf("pagination-http-%d-a.txt", fixtureID),
		fmt.Sprintf("pagination-http-%d-b.txt", fixtureID),
	}
	filePaths := make([]string, 0, len(fileNames))
	for index, fileName := range fileNames {
		filePath := filepath.Join(fixtureDir, fileName)
		if err := os.WriteFile(filePath, fmt.Appendf(nil, "owned pagination fixture %d", index), 0o600); err != nil {
			t.Fatalf("create owned TextEdit file %q: %v", fileName, err)
		}
		filePaths = append(filePaths, filePath)
	}
	openCtx, cancelOpen := context.WithTimeout(ctx, 10*time.Second)
	openCommand := exec.CommandContext(openCtx, "open", append([]string{"-a", "TextEdit"}, filePaths...)...)
	output, err := openCommand.CombinedOutput()
	cancelOpen()
	if err != nil {
		t.Fatalf("open owned TextEdit files: %v output=%q", err, output)
	}

	trackCtx, cancelTrack := context.WithTimeout(ctx, 30*time.Second)
	app := OpenApplicationObserved(t, trackCtx, client, "com.apple.TextEdit")
	cancelTrack()
	defer cleanupPaginationApplication(t, client, app)

	windowCtx, cancelWindows := context.WithTimeout(ctx, 15*time.Second)
	defer cancelWindows()
	if err := PollUntilContext(windowCtx, 100*time.Millisecond, func() (bool, error) {
		response, err := client.ListWindows(windowCtx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		seen := make(map[string]bool, len(fileNames))
		for _, window := range response.Windows {
			for _, fileName := range fileNames {
				if window != nil && window.Bounds != nil && window.Bounds.Width > 0 && window.Bounds.Height > 0 &&
					strings.Contains(window.Title, fileName) {
					seen[fileName] = true
				}
			}
		}
		return len(seen) == len(fileNames), nil
	}); err != nil {
		t.Fatalf("owned TextEdit windows did not appear: %v", err)
	}

	preconditionCtx, cancelPrecondition := context.WithTimeout(ctx, 10*time.Second)
	precondition, err := client.ListWindows(preconditionCtx, &pb.ListWindowsRequest{Parent: app.Name, PageSize: 1})
	cancelPrecondition()
	if err != nil {
		t.Fatalf("verify list_windows pagination precondition: %v", err)
	}
	if len(precondition.Windows) != 1 || precondition.NextPageToken == "" {
		t.Fatalf("owned TextEdit fixture did not produce a page split: windows=%d token=%q", len(precondition.Windows), precondition.NextPageToken)
	}

	mcpCtx, cancelMCP := context.WithTimeout(ctx, 30*time.Second)
	defer cancelMCP()
	_, baseURL, cleanup := startMCPTestServer(t, mcpCtx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize production MCP process: %+v", initialize.Error)
	}

	// list_windows accepts page_size/page_token and returns the signed page token in text.
	request := fmt.Sprintf(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_windows","arguments":{"app":%q,"page_size":1}}}`, app.Name)
	response := postMCPRequest(t, baseURL, request)
	if response.Error != nil {
		t.Fatalf("first list_windows page returned JSON-RPC error: %+v", response.Error)
	}

	var toolResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(response.Result, &toolResult); err != nil {
		t.Fatalf("parse first list_windows result: %v", err)
	}
	if toolResult.IsError || len(toolResult.Content) == 0 {
		t.Fatalf("first list_windows result is not successful content: %+v", toolResult)
	}
	firstText := toolResult.Content[0].Text
	if strings.HasPrefix(firstText, "offset:") {
		t.Fatal("Token is NOT opaque - has recognizable 'offset:' prefix")
	}
	const marker = "Use page_token: "
	_, after, ok := strings.Cut(firstText, marker)
	if !ok {
		t.Fatalf("expected page token in list_windows result, got: %s", firstText)
	}
	token := strings.TrimSpace(after)
	if token == "" {
		t.Fatalf("empty page token in result: %s", firstText)
	}

	secondRequest := fmt.Sprintf(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_windows","arguments":{"app":%q,"page_size":1,"page_token":%q}}}`, app.Name, token)
	secondResponse := postMCPRequest(t, baseURL, secondRequest)
	if secondResponse.Error != nil {
		t.Fatalf("second list_windows page returned JSON-RPC error: %+v", secondResponse.Error)
	}
	var secondResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(secondResponse.Result, &secondResult); err != nil {
		t.Fatalf("parse second list_windows result: %v", err)
	}
	if secondResult.IsError || len(secondResult.Content) == 0 || secondResult.Content[0].Text == firstText {
		t.Fatalf("second page did not return distinct successful content: %+v", secondResult)
	}

	corruptedRequest := fmt.Sprintf(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_windows","arguments":{"app":%q,"page_size":1,"page_token":%q}}}`, app.Name, token+"CORRUPTED")
	corruptedResponse := postMCPRequest(t, baseURL, corruptedRequest)
	if corruptedResponse.Error != nil {
		t.Fatalf("corrupted page token returned transport error instead of tool result: %+v", corruptedResponse.Error)
	}
	var corruptedResult struct {
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(corruptedResponse.Result, &corruptedResult); err != nil {
		t.Fatalf("parse corrupted-token result: %v", err)
	}
	if !corruptedResult.IsError {
		t.Fatal("corrupted list_windows page token was accepted")
	}

	t.Logf("Pagination opacity test via HTTP transport completed. Token format: %d chars, first 10=%q", len(token), token[:min(10, len(token))])
}

// TestMCPPaginationTokenOpacity_FabricatedToken tests that fabricated tokens are rejected.
func TestMCPPaginationTokenOpacity_FabricatedToken(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewExactMacClient(conn)

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
