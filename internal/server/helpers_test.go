// Copyright 2025 Joseph Cumines

package server

import (
	"testing"

	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

func TestErrorResult(t *testing.T) {
	result := errorResult("test error")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Type != "text" {
		t.Errorf("expected type 'text', got %q", result.Content[0].Type)
	}
	if result.Content[0].Text != "test error" {
		t.Errorf("expected text 'test error', got %q", result.Content[0].Text)
	}
}

func TestErrorResultf(t *testing.T) {
	result := errorResultf("error %d: %s", 42, "details")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if result.Content[0].Text != "error 42: details" {
		t.Errorf("expected 'error 42: details', got %q", result.Content[0].Text)
	}
}

func TestTextResult(t *testing.T) {
	result := textResult("success message")
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Text != "success message" {
		t.Errorf("expected 'success message', got %q", result.Content[0].Text)
	}
}

func TestTextResultf(t *testing.T) {
	result := textResultf("count: %d", 99)
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if result.Content[0].Text != "count: 99" {
		t.Errorf("expected 'count: 99', got %q", result.Content[0].Text)
	}
}

func TestBoundsString(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown position and size)",
		},
		{
			name:     "origin bounds",
			bounds:   &pb.Bounds{X: 0, Y: 0, Width: 100, Height: 100},
			expected: "(0, 0) 100x100",
		},
		{
			name:     "positioned bounds",
			bounds:   &pb.Bounds{X: 100.5, Y: 200.7, Width: 800, Height: 600},
			expected: "(100, 201) 800x600",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsString(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsString(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsPosition(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "origin",
			bounds:   &pb.Bounds{X: 0, Y: 0},
			expected: "(0, 0)",
		},
		{
			name:     "positioned",
			bounds:   &pb.Bounds{X: 100, Y: 200},
			expected: "(100, 200)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsPosition(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsPosition(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsSize(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "zero size",
			bounds:   &pb.Bounds{Width: 0, Height: 0},
			expected: "0x0",
		},
		{
			name:     "sized",
			bounds:   &pb.Bounds{Width: 1920, Height: 1080},
			expected: "1920x1080",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsSize(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsSize(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestFrameString(t *testing.T) {
	tests := []struct {
		name     string
		frame    *_type.Region
		expected string
	}{
		{
			name:     "nil frame",
			frame:    nil,
			expected: "(unknown frame)",
		},
		{
			name:     "origin frame",
			frame:    &_type.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (0, 0)",
		},
		{
			name:     "offset frame",
			frame:    &_type.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (-1920, 0)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := frameString(tt.frame)
			if got != tt.expected {
				t.Errorf("frameString(%v) = %q, want %q", tt.frame, got, tt.expected)
			}
		})
	}
}
