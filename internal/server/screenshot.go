// Copyright 2025 Joseph Cumines
//
// Screenshot tool handlers

package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleCaptureScreenshot handles the capture_screenshot tool
func (s *MCPServer) handleCaptureScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Image format: png, jpeg, tiff. Default: png
		Format string `json:"format"`
		// JPEG quality (1-100). Only used for jpeg format.
		Quality int32 `json:"quality"`
		// Display index for multi-monitor setups. Default: 0 (main)
		Display int32 `json:"display"`
		// Whether to include OCR text extraction
		IncludeOCR bool `json:"include_ocr"`
		// Maximum width to resize the image to (for token efficiency)
		MaxWidth int32 `json:"max_width"`
		// Maximum height to resize the image to (for token efficiency)
		MaxHeight int32 `json:"max_height"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	// Map format string to proto enum
	format := pb.ImageFormat_IMAGE_FORMAT_PNG
	switch params.Format {
	case "jpeg", "jpg":
		format = pb.ImageFormat_IMAGE_FORMAT_JPEG
	case "tiff":
		format = pb.ImageFormat_IMAGE_FORMAT_TIFF
	}

	quality := params.Quality
	if quality == 0 {
		quality = 85 // Default JPEG quality
	}

	resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
		Format:         format,
		Quality:        quality,
		Display:        params.Display,
		IncludeOcrText: params.IncludeOCR,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to capture screenshot: %v", err)}},
		}, nil
	}

	// Encode image data as base64
	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)

	// Determine media type based on format
	mediaType := "image/png"
	switch resp.Format {
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		mediaType = "image/jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		mediaType = "image/tiff"
	}

	result := &ToolResult{
		Content: []Content{
			{
				Type: "image",
				Text: fmt.Sprintf("data:%s;base64,%s", mediaType, imageData),
			},
		},
	}

	// Add metadata as text content
	metadataText := fmt.Sprintf("Screenshot captured: %dx%d pixels", resp.Width, resp.Height)
	if params.IncludeOCR && resp.OcrText != "" {
		metadataText += fmt.Sprintf("\n\nOCR Text:\n%s", resp.OcrText)
	}
	result.Content = append(result.Content, Content{
		Type: "text",
		Text: metadataText,
	})

	return result, nil
}

// handleCaptureRegionScreenshot handles the capture_region_screenshot tool
func (s *MCPServer) handleCaptureRegionScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	// Fields ordered for optimal memory alignment: string (16 bytes) first, then 8-byte fields, then 4-byte, then 1-byte
	var params struct {
		Format     string  `json:"format"`
		X          float64 `json:"x"`
		Y          float64 `json:"y"`
		Width      float64 `json:"width"`
		Height     float64 `json:"height"`
		Quality    int32   `json:"quality"`
		IncludeOCR bool    `json:"include_ocr"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	// Validate region
	if params.Width <= 0 || params.Height <= 0 {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Region width and height must be positive"}},
		}, nil
	}

	format := pb.ImageFormat_IMAGE_FORMAT_PNG
	switch params.Format {
	case "jpeg", "jpg":
		format = pb.ImageFormat_IMAGE_FORMAT_JPEG
	case "tiff":
		format = pb.ImageFormat_IMAGE_FORMAT_TIFF
	}

	quality := params.Quality
	if quality == 0 {
		quality = 85
	}

	resp, err := s.client.CaptureRegionScreenshot(ctx, &pb.CaptureRegionScreenshotRequest{
		Region: &typepb.Region{
			X:      params.X,
			Y:      params.Y,
			Width:  params.Width,
			Height: params.Height,
		},
		Format:         format,
		Quality:        quality,
		IncludeOcrText: params.IncludeOCR,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to capture region screenshot: %v", err)}},
		}, nil
	}

	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)
	mediaType := "image/png"
	switch resp.Format {
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		mediaType = "image/jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		mediaType = "image/tiff"
	}

	result := &ToolResult{
		Content: []Content{
			{
				Type: "image",
				Text: fmt.Sprintf("data:%s;base64,%s", mediaType, imageData),
			},
			{
				Type: "text",
				Text: fmt.Sprintf("Region screenshot captured: %dx%d pixels at (%.0f, %.0f)", resp.Width, resp.Height, params.X, params.Y),
			},
		},
	}

	if params.IncludeOCR && resp.OcrText != "" {
		result.Content = append(result.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("OCR Text:\n%s", resp.OcrText),
		})
	}

	return result, nil
}
