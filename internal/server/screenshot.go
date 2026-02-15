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

// defaultJPEGQuality is the default quality setting for JPEG screenshots (1-100).
const defaultJPEGQuality = 85

// parseImageFormat converts a string format name to ImageFormat enum.
// Returns PNG as default for empty or unknown formats.
func parseImageFormat(format string) pb.ImageFormat {
	switch format {
	case "jpeg", "jpg":
		return pb.ImageFormat_IMAGE_FORMAT_JPEG
	case "tiff":
		return pb.ImageFormat_IMAGE_FORMAT_TIFF
	default:
		return pb.ImageFormat_IMAGE_FORMAT_PNG
	}
}

// imageFormatToMediaType returns the MIME type for the given image format.
func imageFormatToMediaType(f pb.ImageFormat) string {
	switch f {
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		return "image/jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		return "image/tiff"
	default:
		return "image/png"
	}
}

// applyDefaultQuality returns the quality value, applying the default if zero.
func applyDefaultQuality(quality int32) int32 {
	if quality == 0 {
		return defaultJPEGQuality
	}
	return quality
}

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
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	format := parseImageFormat(params.Format)
	quality := applyDefaultQuality(params.Quality)

	resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
		Format:         format,
		Quality:        quality,
		Display:        params.Display,
		IncludeOcrText: params.IncludeOCR,
	})
	if err != nil {
		return grpcErrorResult(err, "capture_screenshot"), nil
	}

	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)
	mediaType := imageFormatToMediaType(resp.Format)

	result := &ToolResult{
		Content: []Content{
			{
				Type:     "image",
				Data:     imageData,
				MimeType: mediaType,
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

	format := parseImageFormat(params.Format)
	quality := applyDefaultQuality(params.Quality)

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
		return grpcErrorResult(err, "capture_region_screenshot"), nil
	}

	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)
	mediaType := imageFormatToMediaType(resp.Format)

	result := &ToolResult{
		Content: []Content{
			{
				Type:     "image",
				Data:     imageData,
				MimeType: mediaType,
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

// handleCaptureWindowScreenshot handles the capture_window_screenshot tool
func (s *MCPServer) handleCaptureWindowScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Window        string `json:"window"`
		Format        string `json:"format"`
		Quality       int32  `json:"quality"`
		IncludeShadow bool   `json:"include_shadow"`
		IncludeOCR    bool   `json:"include_ocr"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Window == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "window parameter is required (e.g., applications/123/windows/456)"}},
		}, nil
	}

	format := parseImageFormat(params.Format)
	quality := applyDefaultQuality(params.Quality)

	resp, err := s.client.CaptureWindowScreenshot(ctx, &pb.CaptureWindowScreenshotRequest{
		Window:         params.Window,
		Format:         format,
		Quality:        quality,
		IncludeShadow:  params.IncludeShadow,
		IncludeOcrText: params.IncludeOCR,
	})
	if err != nil {
		return grpcErrorResult(err, "capture_window_screenshot"), nil
	}

	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)
	mediaType := imageFormatToMediaType(resp.Format)

	result := &ToolResult{
		Content: []Content{
			{
				Type:     "image",
				Data:     imageData,
				MimeType: mediaType,
			},
			{
				Type: "text",
				Text: fmt.Sprintf("Window screenshot captured: %dx%d pixels - Window: %s", resp.Width, resp.Height, resp.Window),
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

// handleCaptureElementScreenshot handles the capture_element_screenshot tool
func (s *MCPServer) handleCaptureElementScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent     string `json:"parent"`
		ElementID  string `json:"element_id"`
		Format     string `json:"format"`
		Quality    int32  `json:"quality"`
		Padding    int32  `json:"padding"`
		IncludeOCR bool   `json:"include_ocr"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent parameter is required (e.g., applications/123)"}},
		}, nil
	}

	if params.ElementID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "element_id parameter is required"}},
		}, nil
	}

	format := parseImageFormat(params.Format)
	quality := applyDefaultQuality(params.Quality)

	resp, err := s.client.CaptureElementScreenshot(ctx, &pb.CaptureElementScreenshotRequest{
		Parent:         params.Parent,
		ElementId:      params.ElementID,
		Format:         format,
		Quality:        quality,
		Padding:        params.Padding,
		IncludeOcrText: params.IncludeOCR,
	})
	if err != nil {
		return grpcErrorResult(err, "capture_element_screenshot"), nil
	}

	imageData := base64.StdEncoding.EncodeToString(resp.ImageData)
	mediaType := imageFormatToMediaType(resp.Format)

	elemResult := &ToolResult{
		Content: []Content{
			{
				Type:     "image",
				Data:     imageData,
				MimeType: mediaType,
			},
			{
				Type: "text",
				Text: fmt.Sprintf("Element screenshot captured: %dx%d pixels - Element: %s", resp.Width, resp.Height, resp.ElementId),
			},
		},
	}

	if params.IncludeOCR && resp.OcrText != "" {
		elemResult.Content = append(elemResult.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("OCR Text:\n%s", resp.OcrText),
		})
	}

	return elemResult, nil
}
