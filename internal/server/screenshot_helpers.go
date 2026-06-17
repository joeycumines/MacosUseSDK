// Copyright 2025 Joseph Cumines
//
// Screenshot helper functions shared between CUA tool handlers.

package server

import pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"

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
	if quality <= 0 {
		return defaultJPEGQuality
	}
	if quality > 100 {
		return 100
	}
	return quality
}
