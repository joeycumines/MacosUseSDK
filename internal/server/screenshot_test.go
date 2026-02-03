// Copyright 2025 Joseph Cumines
//
// Screenshot helper tests

package server

import (
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

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
