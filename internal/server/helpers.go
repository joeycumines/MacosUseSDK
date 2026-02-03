// Copyright 2025 Joseph Cumines
//
// Helper functions for tool handlers

package server

import (
	"fmt"

	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// maxDisplayTextLen is the maximum length for text shown in result summaries.
// Longer text is truncated with "..." suffix.
const maxDisplayTextLen = 50

// truncateText truncates text to maxDisplayTextLen characters with "..." suffix if needed.
func truncateText(s string) string {
	if len(s) > maxDisplayTextLen {
		return s[:maxDisplayTextLen] + "..."
	}
	return s
}

// errorResult creates a ToolResult with IsError=true and the given message.
// This reduces boilerplate for error responses across handlers.
func errorResult(msg string) *ToolResult {
	return &ToolResult{
		IsError: true,
		Content: []Content{{Type: "text", Text: msg}},
	}
}

// errorResultf creates a ToolResult with IsError=true and a formatted message.
// This is the sprintf version of errorResult.
func errorResultf(format string, args ...any) *ToolResult {
	return errorResult(fmt.Sprintf(format, args...))
}

// textResult creates a ToolResult with a single text content.
// This reduces boilerplate for simple text responses.
func textResult(text string) *ToolResult {
	return &ToolResult{
		Content: []Content{{Type: "text", Text: text}},
	}
}

// textResultf creates a ToolResult with a formatted text content.
func textResultf(format string, args ...any) *ToolResult {
	return textResult(fmt.Sprintf(format, args...))
}

// boundsString returns a formatted string representation of window bounds,
// safely handling nil bounds with a fallback value.
func boundsString(b *pb.Bounds) string {
	if b == nil {
		return "(unknown position and size)"
	}
	return fmt.Sprintf("(%.0f, %.0f) %.0fx%.0f", b.X, b.Y, b.Width, b.Height)
}

// boundsPosition returns a formatted position string from window bounds,
// safely handling nil bounds.
func boundsPosition(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf("(%.0f, %.0f)", b.X, b.Y)
}

// boundsSize returns a formatted size string from window bounds,
// safely handling nil bounds.
func boundsSize(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf("%.0fx%.0f", b.Width, b.Height)
}

// frameString returns a formatted string representation of a display frame,
// safely handling nil frames.
func frameString(f *_type.Region) string {
	if f == nil {
		return "(unknown frame)"
	}
	return fmt.Sprintf("%.0fx%.0f @ (%.0f, %.0f)", f.Width, f.Height, f.X, f.Y)
}
