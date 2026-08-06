// Copyright 2025 Joseph Cumines
//
// Screenshot image-format conversion shared by tool handlers.

package server

import (
	"fmt"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// defaultJPEGQuality is the default quality setting for JPEG screenshots (1-100).
const defaultJPEGQuality = 85

// parseImageFormat converts a validated string format name to ImageFormat.
func parseImageFormat(format string) pb.ImageFormat {
	switch format {
	case "jpeg":
		return pb.ImageFormat_IMAGE_FORMAT_JPEG
	case "tiff":
		return pb.ImageFormat_IMAGE_FORMAT_TIFF
	default:
		return pb.ImageFormat_IMAGE_FORMAT_PNG
	}
}

// imageFormatToMediaType returns the MIME type for the given image format.
func imageFormatToMediaType(format pb.ImageFormat) string {
	switch format {
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		return "image/jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		return "image/tiff"
	default:
		return "image/png"
	}
}

// screenshotQuality implements the generated contract's exact zero-value
// semantics: JPEG zero selects 85, while PNG and TIFF require zero.
func screenshotQuality(
	format pb.ImageFormat,
	quality *int32,
) (int32, error) {
	if quality != nil && (*quality < 0 || *quality > 100) {
		return 0, fmt.Errorf("quality must be between 0 and 100 when provided")
	}
	if format != pb.ImageFormat_IMAGE_FORMAT_JPEG {
		if quality != nil && *quality != 0 {
			return 0, fmt.Errorf("quality requires JPEG format")
		}
		return 0, nil
	}
	if quality == nil || *quality == 0 {
		return defaultJPEGQuality, nil
	}
	return *quality, nil
}
