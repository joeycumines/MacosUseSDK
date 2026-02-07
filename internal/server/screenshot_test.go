// Copyright 2025 Joseph Cumines
//
// Screenshot handler unit tests

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

// mockScreenshotClient is a mock implementation of MacosUseClient for screenshot testing.
type mockScreenshotClient struct {
	mockMacosUseClient

	// CaptureScreenshot mock
	captureScreenshotFunc func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error)
	// CaptureWindowScreenshot mock
	captureWindowScreenshotFunc func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error)
	// CaptureElementScreenshot mock
	captureElementScreenshotFunc func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error)
	// CaptureRegionScreenshot mock
	captureRegionScreenshotFunc func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error)
}

func (m *mockScreenshotClient) CaptureScreenshot(ctx context.Context, req *pb.CaptureScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureScreenshotResponse, error) {
	if m.captureScreenshotFunc != nil {
		return m.captureScreenshotFunc(ctx, req)
	}
	return nil, errors.New("CaptureScreenshot not implemented")
}

func (m *mockScreenshotClient) CaptureWindowScreenshot(ctx context.Context, req *pb.CaptureWindowScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureWindowScreenshotResponse, error) {
	if m.captureWindowScreenshotFunc != nil {
		return m.captureWindowScreenshotFunc(ctx, req)
	}
	return nil, errors.New("CaptureWindowScreenshot not implemented")
}

func (m *mockScreenshotClient) CaptureElementScreenshot(ctx context.Context, req *pb.CaptureElementScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureElementScreenshotResponse, error) {
	if m.captureElementScreenshotFunc != nil {
		return m.captureElementScreenshotFunc(ctx, req)
	}
	return nil, errors.New("CaptureElementScreenshot not implemented")
}

func (m *mockScreenshotClient) CaptureRegionScreenshot(ctx context.Context, req *pb.CaptureRegionScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureRegionScreenshotResponse, error) {
	if m.captureRegionScreenshotFunc != nil {
		return m.captureRegionScreenshotFunc(ctx, req)
	}
	return nil, errors.New("CaptureRegionScreenshot not implemented")
}

// ============================================================================
// Helper Function Tests
// ============================================================================

func TestParseImageFormat(t *testing.T) {
	cases := []struct {
		name     string
		input    string
		expected pb.ImageFormat
	}{
		{"empty defaults to PNG", "", pb.ImageFormat_IMAGE_FORMAT_PNG},
		{"png format", "png", pb.ImageFormat_IMAGE_FORMAT_PNG},
		{"jpeg format", "jpeg", pb.ImageFormat_IMAGE_FORMAT_JPEG},
		{"jpg format", "jpg", pb.ImageFormat_IMAGE_FORMAT_JPEG},
		{"tiff format", "tiff", pb.ImageFormat_IMAGE_FORMAT_TIFF},
		{"unknown defaults to PNG", "bmp", pb.ImageFormat_IMAGE_FORMAT_PNG},
		{"case sensitive - uppercase ignored", "JPEG", pb.ImageFormat_IMAGE_FORMAT_PNG},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseImageFormat(tc.input)
			if got != tc.expected {
				t.Errorf("parseImageFormat(%q) = %v, want %v", tc.input, got, tc.expected)
			}
		})
	}
}

func TestImageFormatToMediaType(t *testing.T) {
	cases := []struct {
		name     string
		input    pb.ImageFormat
		expected string
	}{
		{"PNG format", pb.ImageFormat_IMAGE_FORMAT_PNG, "image/png"},
		{"JPEG format", pb.ImageFormat_IMAGE_FORMAT_JPEG, "image/jpeg"},
		{"TIFF format", pb.ImageFormat_IMAGE_FORMAT_TIFF, "image/tiff"},
		{"unspecified defaults to PNG", pb.ImageFormat_IMAGE_FORMAT_UNSPECIFIED, "image/png"},
		{"unknown value defaults to PNG", pb.ImageFormat(999), "image/png"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := imageFormatToMediaType(tc.input)
			if got != tc.expected {
				t.Errorf("imageFormatToMediaType(%v) = %q, want %q", tc.input, got, tc.expected)
			}
		})
	}
}

func TestApplyDefaultQuality(t *testing.T) {
	cases := []struct {
		name     string
		input    int32
		expected int32
	}{
		{"zero gets default", 0, defaultJPEGQuality},
		{"non-zero preserved", 50, 50},
		{"high value preserved", 100, 100},
		{"low value preserved", 1, 1},
		{"negative preserved", -1, -1},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := applyDefaultQuality(tc.input)
			if got != tc.expected {
				t.Errorf("applyDefaultQuality(%d) = %d, want %d", tc.input, got, tc.expected)
			}
		})
	}
}

func TestDefaultJPEGQualityValue(t *testing.T) {
	// Verify the constant has the expected value for documentation purposes
	if defaultJPEGQuality != 85 {
		t.Errorf("defaultJPEGQuality = %d, want 85", defaultJPEGQuality)
	}
}

// ============================================================================
// handleCaptureScreenshot Tests
// ============================================================================

func TestHandleCaptureScreenshot_Success_PNG(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			if req.Format != pb.ImageFormat_IMAGE_FORMAT_PNG {
				t.Errorf("expected PNG format, got %v", req.Format)
			}
			if req.Quality != defaultJPEGQuality {
				t.Errorf("expected default quality %d, got %d", defaultJPEGQuality, req.Quality)
			}
			return &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47}, // PNG header
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     1920,
				Height:    1080,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "capture_screenshot", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	if len(result.Content) != 2 {
		t.Fatalf("expected 2 content items, got %d", len(result.Content))
	}

	// First content should be image
	if result.Content[0].Type != "image" {
		t.Errorf("first content type = %q, want 'image'", result.Content[0].Type)
	}
	if result.Content[0].MimeType != "image/png" {
		t.Errorf("image content MimeType = %q, want 'image/png'", result.Content[0].MimeType)
	}
	if result.Content[0].Data == "" {
		t.Error("image content Data is empty")
	}

	// Second content should be metadata text
	if result.Content[1].Type != "text" {
		t.Errorf("second content type = %q, want 'text'", result.Content[1].Type)
	}
	if !strings.Contains(result.Content[1].Text, "1920x1080") {
		t.Errorf("metadata text does not contain dimensions: %s", result.Content[1].Text)
	}
}

func TestHandleCaptureScreenshot_Success_JPEG(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			if req.Format != pb.ImageFormat_IMAGE_FORMAT_JPEG {
				t.Errorf("expected JPEG format, got %v", req.Format)
			}
			if req.Quality != 90 {
				t.Errorf("expected quality 90, got %d", req.Quality)
			}
			return &pb.CaptureScreenshotResponse{
				ImageData: []byte{0xFF, 0xD8, 0xFF, 0xE0}, // JPEG header
				Format:    pb.ImageFormat_IMAGE_FORMAT_JPEG,
				Width:     2560,
				Height:    1440,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_screenshot",
		Arguments: json.RawMessage(`{"format": "jpeg", "quality": 90}`),
	}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	if result.Content[0].MimeType != "image/jpeg" {
		t.Errorf("image content MimeType = %q, want 'image/jpeg'", result.Content[0].MimeType)
	}
	if result.Content[0].Data == "" {
		t.Error("image content Data is empty")
	}
}

func TestHandleCaptureScreenshot_Success_WithOCR(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			if !req.IncludeOcrText {
				t.Error("expected IncludeOcrText to be true")
			}
			return &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     1920,
				Height:    1080,
				OcrText:   "Detected text on screen",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_screenshot",
		Arguments: json.RawMessage(`{"include_ocr": true}`),
	}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	metadataText := result.Content[1].Text
	if !strings.Contains(metadataText, "OCR Text:") {
		t.Errorf("metadata does not contain OCR text header: %s", metadataText)
	}
	if !strings.Contains(metadataText, "Detected text on screen") {
		t.Errorf("metadata does not contain OCR content: %s", metadataText)
	}
}

func TestHandleCaptureScreenshot_Success_DisplayIndex(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			if req.Display != 2 {
				t.Errorf("expected display 2, got %d", req.Display)
			}
			return &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     1920,
				Height:    1080,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_screenshot",
		Arguments: json.RawMessage(`{"display": 2}`),
	}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCaptureScreenshot_InvalidJSON(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_screenshot",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCaptureScreenshot_GRPCError(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			return nil, errors.New("screen recording permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "capture_screenshot", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to capture screenshot") {
		t.Errorf("error text does not contain 'Failed to capture screenshot': %s", text)
	}
	if !strings.Contains(text, "screen recording permission denied") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// handleCaptureRegionScreenshot Tests
// ============================================================================

func TestHandleCaptureRegionScreenshot_Success(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureRegionScreenshotFunc: func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
			if req.Region == nil {
				t.Error("expected region to be set")
			}
			if req.Region.X != 100 || req.Region.Y != 200 {
				t.Errorf("expected position (100, 200), got (%.0f, %.0f)", req.Region.X, req.Region.Y)
			}
			if req.Region.Width != 300 || req.Region.Height != 400 {
				t.Errorf("expected size (300, 400), got (%.0f, %.0f)", req.Region.Width, req.Region.Height)
			}
			return &pb.CaptureRegionScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     300,
				Height:    400,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "width": 300, "height": 400}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	if len(result.Content) < 2 {
		t.Fatalf("expected at least 2 content items, got %d", len(result.Content))
	}

	// First content should be image
	if result.Content[0].Type != "image" {
		t.Errorf("first content type = %q, want 'image'", result.Content[0].Type)
	}

	// Second content should be metadata
	metadataText := result.Content[1].Text
	if !strings.Contains(metadataText, "300x400") {
		t.Errorf("metadata does not contain dimensions: %s", metadataText)
	}
	if !strings.Contains(metadataText, "(100, 200)") {
		t.Errorf("metadata does not contain position: %s", metadataText)
	}
}

func TestHandleCaptureRegionScreenshot_Success_WithOCR(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureRegionScreenshotFunc: func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
			if !req.IncludeOcrText {
				t.Error("expected IncludeOcrText to be true")
			}
			return &pb.CaptureRegionScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     200,
				Height:    100,
				OcrText:   "Button Label",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{"x": 0, "y": 0, "width": 200, "height": 100, "include_ocr": true}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	// Should have 3 content items: image, metadata, and OCR text
	if len(result.Content) != 3 {
		t.Fatalf("expected 3 content items, got %d", len(result.Content))
	}
	if !strings.Contains(result.Content[2].Text, "Button Label") {
		t.Errorf("OCR content does not contain expected text: %s", result.Content[2].Text)
	}
}

func TestHandleCaptureRegionScreenshot_InvalidDimensions_ZeroWidth(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{"x": 0, "y": 0, "width": 0, "height": 100}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for zero width")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "width and height must be positive") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleCaptureRegionScreenshot_InvalidDimensions_NegativeHeight(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{"x": 0, "y": 0, "width": 100, "height": -50}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for negative height")
	}
}

func TestHandleCaptureRegionScreenshot_InvalidJSON(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCaptureRegionScreenshot_GRPCError(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureRegionScreenshotFunc: func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
			return nil, errors.New("region out of bounds")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_region_screenshot",
		Arguments: json.RawMessage(`{"x": 0, "y": 0, "width": 100, "height": 100}`),
	}

	result, err := server.handleCaptureRegionScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureRegionScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to capture region screenshot") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
	if !strings.Contains(text, "region out of bounds") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// handleCaptureWindowScreenshot Tests
// ============================================================================

func TestHandleCaptureWindowScreenshot_Success(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			if req.Window != "applications/123/windows/456" {
				t.Errorf("expected window 'applications/123/windows/456', got %q", req.Window)
			}
			return &pb.CaptureWindowScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     800,
				Height:    600,
				Window:    "applications/123/windows/456",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{"window": "applications/123/windows/456"}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	if len(result.Content) < 2 {
		t.Fatalf("expected at least 2 content items, got %d", len(result.Content))
	}

	// First content should be image
	if result.Content[0].Type != "image" {
		t.Errorf("first content type = %q, want 'image'", result.Content[0].Type)
	}

	// Second content should be metadata
	metadataText := result.Content[1].Text
	if !strings.Contains(metadataText, "800x600") {
		t.Errorf("metadata does not contain dimensions: %s", metadataText)
	}
	if !strings.Contains(metadataText, "applications/123/windows/456") {
		t.Errorf("metadata does not contain window path: %s", metadataText)
	}
}

func TestHandleCaptureWindowScreenshot_Success_WithShadow(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			if !req.IncludeShadow {
				t.Error("expected IncludeShadow to be true")
			}
			return &pb.CaptureWindowScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     850,
				Height:    650,
				Window:    "applications/1/windows/1",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{"window": "applications/1/windows/1", "include_shadow": true}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCaptureWindowScreenshot_Success_WithOCR(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			if !req.IncludeOcrText {
				t.Error("expected IncludeOcrText to be true")
			}
			return &pb.CaptureWindowScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     800,
				Height:    600,
				Window:    "applications/1/windows/1",
				OcrText:   "Window content text",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{"window": "applications/1/windows/1", "include_ocr": true}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	// Should have 3 content items: image, metadata, and OCR text
	if len(result.Content) != 3 {
		t.Fatalf("expected 3 content items, got %d", len(result.Content))
	}
	if !strings.Contains(result.Content[2].Text, "Window content text") {
		t.Errorf("OCR content does not contain expected text: %s", result.Content[2].Text)
	}
}

func TestHandleCaptureWindowScreenshot_MissingWindow(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing window")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "window parameter is required") {
		t.Errorf("error text does not contain 'window parameter is required': %s", text)
	}
}

func TestHandleCaptureWindowScreenshot_EmptyWindow(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{"window": ""}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty window")
	}
}

func TestHandleCaptureWindowScreenshot_InvalidJSON(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCaptureWindowScreenshot_GRPCError(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			return nil, errors.New("window not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_window_screenshot",
		Arguments: json.RawMessage(`{"window": "applications/1/windows/999"}`),
	}

	result, err := server.handleCaptureWindowScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureWindowScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to capture window screenshot") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
	if !strings.Contains(text, "window not found") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// handleCaptureElementScreenshot Tests
// ============================================================================

func TestHandleCaptureElementScreenshot_Success(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
			if req.Parent != "applications/123" {
				t.Errorf("expected parent 'applications/123', got %q", req.Parent)
			}
			if req.ElementId != "element_42" {
				t.Errorf("expected element_id 'element_42', got %q", req.ElementId)
			}
			return &pb.CaptureElementScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     150,
				Height:    50,
				ElementId: "element_42",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/123", "element_id": "element_42"}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	if len(result.Content) < 2 {
		t.Fatalf("expected at least 2 content items, got %d", len(result.Content))
	}

	// First content should be image
	if result.Content[0].Type != "image" {
		t.Errorf("first content type = %q, want 'image'", result.Content[0].Type)
	}

	// Second content should be metadata
	metadataText := result.Content[1].Text
	if !strings.Contains(metadataText, "150x50") {
		t.Errorf("metadata does not contain dimensions: %s", metadataText)
	}
	if !strings.Contains(metadataText, "element_42") {
		t.Errorf("metadata does not contain element ID: %s", metadataText)
	}
}

func TestHandleCaptureElementScreenshot_Success_WithPadding(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
			if req.Padding != 10 {
				t.Errorf("expected padding 10, got %d", req.Padding)
			}
			return &pb.CaptureElementScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     170,
				Height:    70,
				ElementId: "btn_1",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "btn_1", "padding": 10}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCaptureElementScreenshot_Success_WithOCR(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
			if !req.IncludeOcrText {
				t.Error("expected IncludeOcrText to be true")
			}
			return &pb.CaptureElementScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    30,
				ElementId: "label_1",
				OcrText:   "Submit",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "label_1", "include_ocr": true}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	// Should have 3 content items: image, metadata, and OCR text
	if len(result.Content) != 3 {
		t.Fatalf("expected 3 content items, got %d", len(result.Content))
	}
	if !strings.Contains(result.Content[2].Text, "Submit") {
		t.Errorf("OCR content does not contain expected text: %s", result.Content[2].Text)
	}
}

func TestHandleCaptureElementScreenshot_MissingParent(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"element_id": "element_1"}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing parent")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "parent parameter is required") {
		t.Errorf("error text does not contain 'parent parameter is required': %s", text)
	}
}

func TestHandleCaptureElementScreenshot_MissingElementID(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/1"}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing element_id")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "element_id parameter is required") {
		t.Errorf("error text does not contain 'element_id parameter is required': %s", text)
	}
}

func TestHandleCaptureElementScreenshot_EmptyParent(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "", "element_id": "el1"}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty parent")
	}
}

func TestHandleCaptureElementScreenshot_EmptyElementID(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": ""}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty element_id")
	}
}

func TestHandleCaptureElementScreenshot_InvalidJSON(t *testing.T) {
	mockClient := &mockScreenshotClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCaptureElementScreenshot_GRPCError(t *testing.T) {
	mockClient := &mockScreenshotClient{
		captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
			return nil, errors.New("element not visible")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "capture_element_screenshot",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "hidden_element"}`),
	}

	result, err := server.handleCaptureElementScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to capture element screenshot") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
	if !strings.Contains(text, "element not visible") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestHandleCaptureScreenshot_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		response     *pb.CaptureScreenshotResponse
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "default PNG format",
			args: `{}`,
			response: &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x89, 0x50},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     1920,
				Height:    1080,
			},
			wantIsError:  false,
			wantContains: []string{"image/png", "1920x1080"},
		},
		{
			name: "JPEG format",
			args: `{"format": "jpeg"}`,
			response: &pb.CaptureScreenshotResponse{
				ImageData: []byte{0xFF, 0xD8},
				Format:    pb.ImageFormat_IMAGE_FORMAT_JPEG,
				Width:     1920,
				Height:    1080,
			},
			wantIsError:  false,
			wantContains: []string{"image/jpeg"},
		},
		{
			name: "TIFF format",
			args: `{"format": "tiff"}`,
			response: &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x49, 0x49},
				Format:    pb.ImageFormat_IMAGE_FORMAT_TIFF,
				Width:     1920,
				Height:    1080,
			},
			wantIsError:  false,
			wantContains: []string{"image/tiff"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{}`,
			grpcErr:      errors.New("permission denied"),
			wantIsError:  true,
			wantContains: []string{"Failed to capture screenshot", "permission denied"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockScreenshotClient{
				captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.response, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "capture_screenshot", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleCaptureScreenshot(call)

			if err != nil {
				t.Fatalf("handleCaptureScreenshot returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			// Check content
			var foundText string
			for _, c := range result.Content {
				foundText += c.Text + "\n"
				if c.MimeType != "" {
					foundText += c.MimeType + "\n"
				}
			}
			for _, want := range tt.wantContains {
				if !strings.Contains(foundText, want) {
					t.Errorf("result does not contain %q: %s", want, foundText)
				}
			}
		})
	}
}

func TestHandleCaptureWindowScreenshot_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		response     *pb.CaptureWindowScreenshotResponse
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "success",
			args: `{"window": "applications/1/windows/1"}`,
			response: &pb.CaptureWindowScreenshotResponse{
				ImageData: []byte{0x89, 0x50},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     800,
				Height:    600,
				Window:    "applications/1/windows/1",
			},
			wantIsError:  false,
			wantContains: []string{"800x600", "applications/1/windows/1"},
		},
		{
			name:         "missing window",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"window parameter is required"},
		},
		{
			name:         "empty window",
			args:         `{"window": ""}`,
			wantIsError:  true,
			wantContains: []string{"window parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"window": "applications/1/windows/1"}`,
			grpcErr:      errors.New("window minimized"),
			wantIsError:  true,
			wantContains: []string{"Failed to capture window screenshot", "window minimized"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockScreenshotClient{
				captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.response, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "capture_window_screenshot", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleCaptureWindowScreenshot(call)

			if err != nil {
				t.Fatalf("handleCaptureWindowScreenshot returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			var foundText string
			for _, c := range result.Content {
				foundText += c.Text + "\n"
			}
			for _, want := range tt.wantContains {
				if !strings.Contains(foundText, want) {
					t.Errorf("result does not contain %q: %s", want, foundText)
				}
			}
		})
	}
}

func TestHandleCaptureElementScreenshot_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		response     *pb.CaptureElementScreenshotResponse
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "success",
			args: `{"parent": "applications/1", "element_id": "btn_1"}`,
			response: &pb.CaptureElementScreenshotResponse{
				ImageData: []byte{0x89, 0x50},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     120,
				Height:    40,
				ElementId: "btn_1",
			},
			wantIsError:  false,
			wantContains: []string{"120x40", "btn_1"},
		},
		{
			name:         "missing parent",
			args:         `{"element_id": "btn_1"}`,
			wantIsError:  true,
			wantContains: []string{"parent parameter is required"},
		},
		{
			name:         "missing element_id",
			args:         `{"parent": "applications/1"}`,
			wantIsError:  true,
			wantContains: []string{"element_id parameter is required"},
		},
		{
			name:         "empty parent",
			args:         `{"parent": "", "element_id": "btn_1"}`,
			wantIsError:  true,
			wantContains: []string{"parent parameter is required"},
		},
		{
			name:         "empty element_id",
			args:         `{"parent": "applications/1", "element_id": ""}`,
			wantIsError:  true,
			wantContains: []string{"element_id parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"parent": "applications/1", "element_id": "btn_1"}`,
			grpcErr:      errors.New("element offscreen"),
			wantIsError:  true,
			wantContains: []string{"Failed to capture element screenshot", "element offscreen"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockScreenshotClient{
				captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.response, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "capture_element_screenshot", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleCaptureElementScreenshot(call)

			if err != nil {
				t.Fatalf("handleCaptureElementScreenshot returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			var foundText string
			for _, c := range result.Content {
				foundText += c.Text + "\n"
			}
			for _, want := range tt.wantContains {
				if !strings.Contains(foundText, want) {
					t.Errorf("result does not contain %q: %s", want, foundText)
				}
			}
		})
	}
}

func TestHandleCaptureRegionScreenshot_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		response     *pb.CaptureRegionScreenshotResponse
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "success",
			args: `{"x": 100, "y": 200, "width": 300, "height": 400}`,
			response: &pb.CaptureRegionScreenshotResponse{
				ImageData: []byte{0x89, 0x50},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     300,
				Height:    400,
			},
			wantIsError:  false,
			wantContains: []string{"300x400", "(100, 200)"},
		},
		{
			name:         "zero width",
			args:         `{"x": 0, "y": 0, "width": 0, "height": 100}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "zero height",
			args:         `{"x": 0, "y": 0, "width": 100, "height": 0}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "negative width",
			args:         `{"x": 0, "y": 0, "width": -100, "height": 100}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "negative height",
			args:         `{"x": 0, "y": 0, "width": 100, "height": -100}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"x": 0, "y": 0, "width": 100, "height": 100}`,
			grpcErr:      errors.New("region outside display bounds"),
			wantIsError:  true,
			wantContains: []string{"Failed to capture region screenshot", "region outside display bounds"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockScreenshotClient{
				captureRegionScreenshotFunc: func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.response, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "capture_region_screenshot", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleCaptureRegionScreenshot(call)

			if err != nil {
				t.Fatalf("handleCaptureRegionScreenshot returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			var foundText string
			for _, c := range result.Content {
				foundText += c.Text + "\n"
			}
			for _, want := range tt.wantContains {
				if !strings.Contains(foundText, want) {
					t.Errorf("result does not contain %q: %s", want, foundText)
				}
			}
		})
	}
}

// ============================================================================
// Content Type and Structure Tests
// ============================================================================

func TestScreenshotHandlers_ImageContentReturned(t *testing.T) {
	// Verify all screenshot handlers return image content when successful
	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			return &pb.CaptureScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    100,
			}, nil
		},
		captureWindowScreenshotFunc: func(ctx context.Context, req *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			return &pb.CaptureWindowScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    100,
				Window:    "applications/1/windows/1",
			}, nil
		},
		captureElementScreenshotFunc: func(ctx context.Context, req *pb.CaptureElementScreenshotRequest) (*pb.CaptureElementScreenshotResponse, error) {
			return &pb.CaptureElementScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    100,
				ElementId: "el_1",
			}, nil
		},
		captureRegionScreenshotFunc: func(ctx context.Context, req *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
			return &pb.CaptureRegionScreenshotResponse{
				ImageData: []byte{0x89, 0x50, 0x4E, 0x47},
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    100,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"capture_screenshot":         {server.handleCaptureScreenshot, `{}`},
		"capture_window_screenshot":  {server.handleCaptureWindowScreenshot, `{"window": "applications/1/windows/1"}`},
		"capture_element_screenshot": {server.handleCaptureElementScreenshot, `{"parent": "applications/1", "element_id": "el_1"}`},
		"capture_region_screenshot":  {server.handleCaptureRegionScreenshot, `{"x": 0, "y": 0, "width": 100, "height": 100}`},
	}

	for name, h := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(h.args)}
			result, err := h.fn(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if result.IsError {
				t.Fatalf("%s returned error result: %s", name, result.Content[0].Text)
			}
			if len(result.Content) < 2 {
				t.Fatalf("%s returned fewer than 2 content items", name)
			}
			if result.Content[0].Type != "image" {
				t.Errorf("%s first content type = %q, want 'image'", name, result.Content[0].Type)
			}
			if result.Content[1].Type != "text" {
				t.Errorf("%s second content type = %q, want 'text' (metadata)", name, result.Content[1].Type)
			}
		})
	}
}

func TestScreenshotHandlers_Base64Encoding(t *testing.T) {
	// Verify image data is properly base64 encoded
	imageData := []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A} // PNG header

	mockClient := &mockScreenshotClient{
		captureScreenshotFunc: func(ctx context.Context, req *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			return &pb.CaptureScreenshotResponse{
				ImageData: imageData,
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     100,
				Height:    100,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "capture_screenshot", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCaptureScreenshot(call)

	if err != nil {
		t.Fatalf("handleCaptureScreenshot returned error: %v", err)
	}
	if result.IsError {
		t.Fatalf("result.IsError = true: %s", result.Content[0].Text)
	}

	// Verify MimeType field
	if result.Content[0].MimeType != "image/png" {
		t.Errorf("image content MimeType = %q, want 'image/png'", result.Content[0].MimeType)
	}

	// Verify base64 encoding in Data field contains expected content
	data := result.Content[0].Data
	if data == "" {
		t.Fatal("image content Data is empty")
	}
	if !strings.Contains(data, "iVBORw0KGgo") { // Base64 of PNG header
		t.Errorf("image content Data does not contain expected base64 encoded PNG header: %s", data)
	}
}
