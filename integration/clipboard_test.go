package integration

import (
	"context"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// Tests basic Write/Get/Clear clipboard using text content and verifies history.
func TestClipboardTextFlow(t *testing.T) {
	ctx := context.Background()

	// Start server
	cmd, addr := startServer(t, ctx)
	defer cleanupServer(t, cmd, addr)

	conn := connectToServer(t, ctx, addr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	// Ensure we start in a clean state by clearing clipboard
	_, err := client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		t.Fatalf("ClearClipboard failed: %v", err)
	}

	// Write a text value
	writeResp, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content:       &pb.ClipboardContent{Content: &pb.ClipboardContent_Text{Text: "integration-text-123"}},
		ClearExisting: true,
	})
	if err != nil {
		t.Fatalf("WriteClipboard failed: %v", err)
	}
	if !writeResp.Success {
		t.Fatalf("WriteClipboard returned success=false")
	}
	if writeResp.Type != pb.ContentType_CONTENT_TYPE_TEXT {
		t.Fatalf("WriteClipboard response reported wrong type: %v", writeResp.Type)
	}

	// Read back
	got, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Fatalf("GetClipboard failed: %v", err)
	}

	if got.Content.Type != pb.ContentType_CONTENT_TYPE_TEXT {
		t.Fatalf("expected content type TEXT got %v", got.Content.Type)
	}
	// Extract text
	if got.Content.GetText() != "integration-text-123" {
		t.Fatalf("clipboard text mismatch: %v", got.Content.GetText())
	}

	// Now clear and confirm content is cleared
	_, err = client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		t.Fatalf("ClearClipboard failed: %v", err)
	}

	// Poll until clipboard is cleared (avoid time.Sleep).
	verifyCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	err = PollUntilContext(verifyCtx, 50*time.Millisecond, func() (bool, error) {
		got2, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
		if err != nil {
			return false, nil
		}
		return len(got2.AvailableTypes) == 0, nil
	})
	if err != nil {
		t.Fatalf("clipboard not cleared within timeout: %v", err)
	}
}

// Tests that GetClipboardHistory returns recent entries after writes.
func TestClipboardHistory(t *testing.T) {
	ctx := context.Background()

	cmd, addr := startServer(t, ctx)
	defer cleanupServer(t, cmd, addr)

	conn := connectToServer(t, ctx, addr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	// Clear clipboard to start fresh
	_, _ = client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})

	// Write two distinct values
	_, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content:       &pb.ClipboardContent{Content: &pb.ClipboardContent_Text{Text: "history-one"}},
		ClearExisting: true,
	})
	if err != nil {
		t.Fatalf("WriteClipboard failed: %v", err)
	}

	_, err = client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content:       &pb.ClipboardContent{Content: &pb.ClipboardContent_Text{Text: "history-two"}},
		ClearExisting: true,
	})
	if err != nil {
		t.Fatalf("WriteClipboard second failed: %v", err)
	}

	// Poll until history has at least two entries (avoid time.Sleep).
	histCtx, histCancel := context.WithTimeout(ctx, 5*time.Second)
	defer histCancel()

	err = PollUntilContext(histCtx, 50*time.Millisecond, func() (bool, error) {
		hist, err := client.GetClipboardHistory(ctx, &pb.GetClipboardHistoryRequest{Name: "clipboard/history"})
		if err != nil {
			return false, nil
		}
		return len(hist.Entries) >= 2, nil
	})
	if err != nil {
		t.Fatalf("GetClipboardHistory did not contain expected entries within timeout: %v", err)
	}

	// Fetch final history for assertions
	hist, err := client.GetClipboardHistory(ctx, &pb.GetClipboardHistoryRequest{Name: "clipboard/history"})
	if err != nil {
		t.Fatalf("GetClipboardHistory failed: %v", err)
	}

	// Most recent should be the last write: history-two
	if h := hist.Entries[0].Content; h == nil {
		t.Fatalf("history entry 0 content is nil")
	} else {
		if h.GetText() != "history-two" {
			t.Fatalf("unexpected recent history entry: %v", h.GetText())
		}
	}
}
