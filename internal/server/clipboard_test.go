// Copyright 2025 Joseph Cumines
//
// Clipboard handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
)

// mockClipboardClient is a mock implementation of MacosUseClient for clipboard testing.
type mockClipboardClient struct {
	mockMacosUseClient

	// GetClipboard mock
	getClipboardFunc func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error)
	// WriteClipboard mock
	writeClipboardFunc func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error)
	// ClearClipboard mock
	clearClipboardFunc func(ctx context.Context, req *pb.ClearClipboardRequest) (*pb.ClearClipboardResponse, error)
	// GetClipboardHistory mock
	getClipboardHistoryFunc func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error)
}

func (m *mockClipboardClient) GetClipboard(ctx context.Context, req *pb.GetClipboardRequest, opts ...grpc.CallOption) (*pb.Clipboard, error) {
	if m.getClipboardFunc != nil {
		return m.getClipboardFunc(ctx, req)
	}
	return nil, errors.New("GetClipboard not implemented")
}

func (m *mockClipboardClient) WriteClipboard(ctx context.Context, req *pb.WriteClipboardRequest, opts ...grpc.CallOption) (*pb.WriteClipboardResponse, error) {
	if m.writeClipboardFunc != nil {
		return m.writeClipboardFunc(ctx, req)
	}
	return nil, errors.New("WriteClipboard not implemented")
}

func (m *mockClipboardClient) ClearClipboard(ctx context.Context, req *pb.ClearClipboardRequest, opts ...grpc.CallOption) (*pb.ClearClipboardResponse, error) {
	if m.clearClipboardFunc != nil {
		return m.clearClipboardFunc(ctx, req)
	}
	return nil, errors.New("ClearClipboard not implemented")
}

func (m *mockClipboardClient) GetClipboardHistory(ctx context.Context, req *pb.GetClipboardHistoryRequest, opts ...grpc.CallOption) (*pb.ClipboardHistory, error) {
	if m.getClipboardHistoryFunc != nil {
		return m.getClipboardHistoryFunc(ctx, req)
	}
	return nil, errors.New("GetClipboardHistory not implemented")
}

// ============================================================================
// handleGetClipboard Tests
// ============================================================================

func TestHandleGetClipboard_Success_TextContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			if req.Name != "clipboard" {
				t.Errorf("expected name 'clipboard', got %q", req.Name)
			}
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_TEXT,
					Content: &pb.ClipboardContent_Text{
						Text: "Hello, World!",
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Clipboard content:") {
		t.Errorf("result text does not contain 'Clipboard content:': %s", text)
	}
	if !strings.Contains(text, "Hello, World!") {
		t.Errorf("result text does not contain 'Hello, World!': %s", text)
	}
}

func TestHandleGetClipboard_Success_URLContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_URL,
					Content: &pb.ClipboardContent_Url{
						Url: "https://example.com",
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "https://example.com") {
		t.Errorf("result text does not contain URL: %s", text)
	}
}

func TestHandleGetClipboard_Success_HTMLContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_HTML,
					Content: &pb.ClipboardContent_Html{
						Html: "<p>Hello</p>",
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "<p>Hello</p>") {
		t.Errorf("result text does not contain HTML: %s", text)
	}
}

func TestHandleGetClipboard_Success_RTFContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_RTF,
					Content: &pb.ClipboardContent_Rtf{
						Rtf: []byte("\\rtf1 some rtf data"),
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "[RTF data]") {
		t.Errorf("result text does not contain '[RTF data]': %s", text)
	}
}

func TestHandleGetClipboard_Success_ImageContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_IMAGE,
					Content: &pb.ClipboardContent_Image{
						Image: []byte{0x89, 0x50, 0x4E, 0x47}, // PNG header
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "[Image data]") {
		t.Errorf("result text does not contain '[Image data]': %s", text)
	}
}

func TestHandleGetClipboard_Success_FilesContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_FILES,
					Content: &pb.ClipboardContent_Files{
						Files: &pb.FilePaths{
							Paths: []string{"/path/to/file1.txt", "/path/to/file2.txt"},
						},
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "[Files:") {
		t.Errorf("result text does not contain '[Files:': %s", text)
	}
	if !strings.Contains(text, "file1.txt") {
		t.Errorf("result text does not contain 'file1.txt': %s", text)
	}
}

func TestHandleGetClipboard_Success_EmptyClipboard(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{
				Content: nil,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "(empty)") {
		t.Errorf("result text does not contain '(empty)': %s", text)
	}
}

func TestHandleGetClipboard_GRPCError(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return nil, errors.New("pasteboard unavailable")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboard(call)

	if err != nil {
		t.Fatalf("handleGetClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get clipboard") {
		t.Errorf("error text does not contain 'Failed to get clipboard': %s", text)
	}
	if !strings.Contains(text, "pasteboard unavailable") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// handleWriteClipboard Tests
// ============================================================================

func TestHandleWriteClipboard_Success(t *testing.T) {
	mockClient := &mockClipboardClient{
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			if req.Content == nil {
				t.Error("expected content to be set")
			}
			if req.Content.GetText() != "Test content" {
				t.Errorf("expected text 'Test content', got %q", req.Content.GetText())
			}
			if req.Content.Type != pb.ContentType_CONTENT_TYPE_TEXT {
				t.Errorf("expected content type TEXT, got %v", req.Content.Type)
			}
			if !req.ClearExisting {
				t.Error("expected ClearExisting to be true")
			}
			return &pb.WriteClipboardResponse{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{"text": "Test content"}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Clipboard updated with 12 characters") {
		t.Errorf("result text does not contain expected message: %s", text)
	}
}

func TestHandleWriteClipboard_Success_LongTextTruncated(t *testing.T) {
	longText := strings.Repeat("a", 100)

	mockClient := &mockClipboardClient{
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			if req.Content.GetText() != longText {
				t.Error("expected full text to be sent to clipboard")
			}
			return &pb.WriteClipboardResponse{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{"text": "` + longText + `"}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "100 characters") {
		t.Errorf("result text does not contain correct character count: %s", text)
	}
	// Should contain truncated version with ellipsis
	if !strings.Contains(text, "...") {
		t.Errorf("result text should contain ellipsis for truncated content: %s", text)
	}
}

func TestHandleWriteClipboard_MissingText(t *testing.T) {
	mockClient := &mockClipboardClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing text")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "text parameter is required") {
		t.Errorf("error text does not contain 'text parameter is required': %s", text)
	}
}

func TestHandleWriteClipboard_EmptyText(t *testing.T) {
	mockClient := &mockClipboardClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{"text": ""}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty text")
	}
}

func TestHandleWriteClipboard_InvalidJSON(t *testing.T) {
	mockClient := &mockClipboardClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleWriteClipboard_GRPCError(t *testing.T) {
	mockClient := &mockClipboardClient{
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			return nil, errors.New("write permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{"text": "test"}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to write clipboard") {
		t.Errorf("error text does not contain 'Failed to write clipboard': %s", text)
	}
}

// TestHandleWriteClipboard_WhitespaceOnlyText verifies that whitespace-only
// text is valid (not rejected as empty). The validator only checks for empty
// string, so "   " should pass validation and be sent to the server.
func TestHandleWriteClipboard_WhitespaceOnlyText(t *testing.T) {
	var writtenText string
	mockClient := &mockClipboardClient{
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			writtenText = req.GetContent().GetText()
			return &pb.WriteClipboardResponse{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_clipboard",
		Arguments: json.RawMessage(`{"text": "   "}`),
	}

	result, err := server.handleWriteClipboard(call)

	if err != nil {
		t.Fatalf("handleWriteClipboard returned Go error: %v", err)
	}
	// Whitespace-only text should be accepted (not an error)
	if result.IsError {
		t.Errorf("result.IsError = true, want false for whitespace-only text: %s", result.Content[0].Text)
	}
	if writtenText != "   " {
		t.Errorf("written text = %q, want %q", writtenText, "   ")
	}
}

// ============================================================================
// handleClearClipboard Tests
// ============================================================================

func TestHandleClearClipboard_Success(t *testing.T) {
	mockClient := &mockClipboardClient{
		clearClipboardFunc: func(ctx context.Context, req *pb.ClearClipboardRequest) (*pb.ClearClipboardResponse, error) {
			return &pb.ClearClipboardResponse{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "clear_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleClearClipboard(call)

	if err != nil {
		t.Fatalf("handleClearClipboard returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "Clipboard cleared" {
		t.Errorf("result text = %q, want 'Clipboard cleared'", text)
	}
}

func TestHandleClearClipboard_GRPCError(t *testing.T) {
	mockClient := &mockClipboardClient{
		clearClipboardFunc: func(ctx context.Context, req *pb.ClearClipboardRequest) (*pb.ClearClipboardResponse, error) {
			return nil, errors.New("clear failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "clear_clipboard", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleClearClipboard(call)

	if err != nil {
		t.Fatalf("handleClearClipboard returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to clear clipboard") {
		t.Errorf("error text does not contain 'Failed to clear clipboard': %s", text)
	}
}

// ============================================================================
// handleGetClipboardHistory Tests
// ============================================================================

func TestHandleGetClipboardHistory_Success(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			if req.Name != "clipboard/history" {
				t.Errorf("expected name 'clipboard/history', got %q", req.Name)
			}
			return &pb.ClipboardHistory{
				Entries: []*pb.ClipboardHistoryEntry{
					{
						Content: &pb.ClipboardContent{
							Type:    pb.ContentType_CONTENT_TYPE_TEXT,
							Content: &pb.ClipboardContent_Text{Text: "First entry"},
						},
					},
					{
						Content: &pb.ClipboardContent{
							Type:    pb.ContentType_CONTENT_TYPE_TEXT,
							Content: &pb.ClipboardContent_Text{Text: "Second entry"},
						},
					},
					{
						Content: &pb.ClipboardContent{
							Type:    pb.ContentType_CONTENT_TYPE_URL,
							Content: &pb.ClipboardContent_Url{Url: "https://example.com"},
						},
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard_history", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboardHistory(call)

	if err != nil {
		t.Fatalf("handleGetClipboardHistory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Clipboard history (3 entries)") {
		t.Errorf("result text does not contain 'Clipboard history (3 entries)': %s", text)
	}
	if !strings.Contains(text, "1. First entry") {
		t.Errorf("result text does not contain '1. First entry': %s", text)
	}
	if !strings.Contains(text, "2. Second entry") {
		t.Errorf("result text does not contain '2. Second entry': %s", text)
	}
	if !strings.Contains(text, "3. https://example.com") {
		t.Errorf("result text does not contain '3. https://example.com': %s", text)
	}
}

func TestHandleGetClipboardHistory_EmptyHistory(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return &pb.ClipboardHistory{
				Entries: []*pb.ClipboardHistoryEntry{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard_history", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboardHistory(call)

	if err != nil {
		t.Fatalf("handleGetClipboardHistory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No clipboard history available" {
		t.Errorf("result text = %q, want 'No clipboard history available'", text)
	}
}

func TestHandleGetClipboardHistory_ImageContent(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return &pb.ClipboardHistory{
				Entries: []*pb.ClipboardHistoryEntry{
					{
						Content: &pb.ClipboardContent{
							Type:    pb.ContentType_CONTENT_TYPE_IMAGE,
							Content: &pb.ClipboardContent_Image{Image: []byte{0x89}},
						},
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard_history", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboardHistory(call)

	if err != nil {
		t.Fatalf("handleGetClipboardHistory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "[Image]") {
		t.Errorf("result text does not contain '[Image]': %s", text)
	}
}

func TestHandleGetClipboardHistory_TruncatesLongText(t *testing.T) {
	longText := strings.Repeat("x", 100)

	mockClient := &mockClipboardClient{
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return &pb.ClipboardHistory{
				Entries: []*pb.ClipboardHistoryEntry{
					{
						Content: &pb.ClipboardContent{
							Type:    pb.ContentType_CONTENT_TYPE_TEXT,
							Content: &pb.ClipboardContent_Text{Text: longText},
						},
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard_history", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboardHistory(call)

	if err != nil {
		t.Fatalf("handleGetClipboardHistory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	// Should contain ellipsis for truncated content
	if !strings.Contains(text, "...") {
		t.Errorf("result text should contain ellipsis for truncated content: %s", text)
	}
	// Should NOT contain the full 100-char string
	if strings.Contains(text, longText) {
		t.Errorf("result text should not contain full long text: %s", text)
	}
}

func TestHandleGetClipboardHistory_GRPCError(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return nil, errors.New("history not available")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_clipboard_history", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetClipboardHistory(call)

	if err != nil {
		t.Fatalf("handleGetClipboardHistory returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get clipboard history") {
		t.Errorf("error text does not contain 'Failed to get clipboard history': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestHandleGetClipboard_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		clipboard    *pb.Clipboard
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "text content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type:    pb.ContentType_CONTENT_TYPE_TEXT,
					Content: &pb.ClipboardContent_Text{Text: "Hello"},
				},
			},
			wantIsError:  false,
			wantContains: []string{"Clipboard content:", "Hello"},
		},
		{
			name: "url content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type:    pb.ContentType_CONTENT_TYPE_URL,
					Content: &pb.ClipboardContent_Url{Url: "https://test.com"},
				},
			},
			wantIsError:  false,
			wantContains: []string{"https://test.com"},
		},
		{
			name: "html content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type:    pb.ContentType_CONTENT_TYPE_HTML,
					Content: &pb.ClipboardContent_Html{Html: "<b>Bold</b>"},
				},
			},
			wantIsError:  false,
			wantContains: []string{"<b>Bold</b>"},
		},
		{
			name: "rtf content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type:    pb.ContentType_CONTENT_TYPE_RTF,
					Content: &pb.ClipboardContent_Rtf{Rtf: []byte("\\rtf1")},
				},
			},
			wantIsError:  false,
			wantContains: []string{"[RTF data]"},
		},
		{
			name: "image content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type:    pb.ContentType_CONTENT_TYPE_IMAGE,
					Content: &pb.ClipboardContent_Image{Image: []byte{0x89}},
				},
			},
			wantIsError:  false,
			wantContains: []string{"[Image data]"},
		},
		{
			name: "files content",
			clipboard: &pb.Clipboard{
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_FILES,
					Content: &pb.ClipboardContent_Files{
						Files: &pb.FilePaths{Paths: []string{"/tmp/file.txt"}},
					},
				},
			},
			wantIsError:  false,
			wantContains: []string{"[Files:", "file.txt"},
		},
		{
			name:         "empty clipboard",
			clipboard:    &pb.Clipboard{Content: nil},
			wantIsError:  false,
			wantContains: []string{"(empty)"},
		},
		{
			name:         "gRPC error",
			grpcErr:      errors.New("connection failed"),
			wantIsError:  true,
			wantContains: []string{"Failed to get clipboard", "connection failed"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockClipboardClient{
				getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.clipboard, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "get_clipboard", Arguments: json.RawMessage(`{}`)}

			result, err := server.handleGetClipboard(call)

			if err != nil {
				t.Fatalf("handleGetClipboard returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			text := result.Content[0].Text
			for _, want := range tt.wantContains {
				if !strings.Contains(text, want) {
					t.Errorf("result text does not contain %q: %s", want, text)
				}
			}
		})
	}
}

func TestHandleWriteClipboard_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "short text",
			args:         `{"text": "Hello"}`,
			wantIsError:  false,
			wantContains: []string{"Clipboard updated with 5 characters"},
		},
		{
			name:         "multiline text",
			args:         `{"text": "Line1\nLine2"}`,
			wantIsError:  false,
			wantContains: []string{"Clipboard updated with 11 characters"},
		},
		{
			name:         "missing text",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"text parameter is required"},
		},
		{
			name:         "empty text",
			args:         `{"text": ""}`,
			wantIsError:  true,
			wantContains: []string{"text parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"text": "test"}`,
			grpcErr:      errors.New("denied"),
			wantIsError:  true,
			wantContains: []string{"Failed to write clipboard", "denied"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockClipboardClient{
				writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.WriteClipboardResponse{}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "write_clipboard", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleWriteClipboard(call)

			if err != nil {
				t.Fatalf("handleWriteClipboard returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			text := result.Content[0].Text
			for _, want := range tt.wantContains {
				if !strings.Contains(text, want) {
					t.Errorf("result text does not contain %q: %s", want, text)
				}
			}
		})
	}
}

// ============================================================================
// Content Type and Structure Tests
// ============================================================================

func TestClipboardHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{Content: &pb.ClipboardContent{Type: pb.ContentType_CONTENT_TYPE_TEXT, Content: &pb.ClipboardContent_Text{Text: "test"}}}, nil
		},
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			return &pb.WriteClipboardResponse{}, nil
		},
		clearClipboardFunc: func(ctx context.Context, req *pb.ClearClipboardRequest) (*pb.ClearClipboardResponse, error) {
			return &pb.ClearClipboardResponse{}, nil
		},
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return &pb.ClipboardHistory{Entries: []*pb.ClipboardHistoryEntry{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"get_clipboard":         {server.handleGetClipboard, `{}`},
		"write_clipboard":       {server.handleWriteClipboard, `{"text": "test"}`},
		"clear_clipboard":       {server.handleClearClipboard, `{}`},
		"get_clipboard_history": {server.handleGetClipboardHistory, `{}`},
	}

	for name, h := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(h.args)}
			result, err := h.fn(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if len(result.Content) == 0 {
				t.Fatalf("%s returned empty content", name)
			}
			if result.Content[0].Type != "text" {
				t.Errorf("%s content type = %q, want 'text'", name, result.Content[0].Type)
			}
		})
	}
}

func TestClipboardHandlers_SingleContentItem(t *testing.T) {
	mockClient := &mockClipboardClient{
		getClipboardFunc: func(ctx context.Context, req *pb.GetClipboardRequest) (*pb.Clipboard, error) {
			return &pb.Clipboard{}, nil
		},
		writeClipboardFunc: func(ctx context.Context, req *pb.WriteClipboardRequest) (*pb.WriteClipboardResponse, error) {
			return &pb.WriteClipboardResponse{}, nil
		},
		clearClipboardFunc: func(ctx context.Context, req *pb.ClearClipboardRequest) (*pb.ClearClipboardResponse, error) {
			return &pb.ClearClipboardResponse{}, nil
		},
		getClipboardHistoryFunc: func(ctx context.Context, req *pb.GetClipboardHistoryRequest) (*pb.ClipboardHistory, error) {
			return &pb.ClipboardHistory{}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"get_clipboard":         {server.handleGetClipboard, `{}`},
		"write_clipboard":       {server.handleWriteClipboard, `{"text": "test"}`},
		"clear_clipboard":       {server.handleClearClipboard, `{}`},
		"get_clipboard_history": {server.handleGetClipboardHistory, `{}`},
	}

	for name, h := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(h.args)}
			result, err := h.fn(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if len(result.Content) != 1 {
				t.Errorf("%s returned %d content items, want 1", name, len(result.Content))
			}
		})
	}
}
