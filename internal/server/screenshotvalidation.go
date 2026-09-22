// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"math"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	_ "golang.org/x/image/tiff"
)

const (
	screenshotRegionTolerance = 0.001

	// A decoded screenshot may require four bytes per pixel. This ceiling keeps
	// fail-closed adapter validation bounded while admitting an image nearly
	// twice the area of an 8K display.
	maxDecodedScreenshotPixels int64 = 64 * 1024 * 1024
)

func validateDisplayScreenshotResponse(
	response *pb.CaptureScreenshotResponse,
	requestedDisplay string,
	requestedFormat pb.ImageFormat,
	requestedOCR bool,
) (screenshotOCRResult, error) {
	if response == nil {
		return screenshotOCRResult{}, fmt.Errorf("response is nil")
	}
	if err := validateScreenshotDisplay(
		response.Display,
		requestedDisplay,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	if err := validateEncodedScreenshot(
		response.ImageData,
		response.Format,
		response.Width,
		response.Height,
		requestedFormat,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	if err := validateScreenshotGeometry(
		response.Region,
		response.Scale,
		response.Width,
		response.Height,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	return displayScreenshotOCR(response, requestedOCR)
}

func validateRegionScreenshotResponse(
	response *pb.CaptureRegionScreenshotResponse,
	requestedDisplay string,
	requestedRegion *typepb.Region,
	requestedFormat pb.ImageFormat,
	requestedOCR bool,
) (screenshotOCRResult, error) {
	if response == nil {
		return screenshotOCRResult{}, fmt.Errorf("response is nil")
	}
	if err := validateScreenshotDisplay(
		response.Display,
		requestedDisplay,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	if err := validateEncodedScreenshot(
		response.ImageData,
		response.Format,
		response.Width,
		response.Height,
		requestedFormat,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	if err := validateScreenshotGeometry(
		response.Region,
		response.Scale,
		response.Width,
		response.Height,
	); err != nil {
		return screenshotOCRResult{}, err
	}
	if requestedRegion == nil ||
		!screenshotRegionContains(
			response.Region,
			requestedRegion,
			screenshotRegionTolerance,
		) {
		return screenshotOCRResult{}, fmt.Errorf(
			"returned region does not contain the requested region",
		)
	}
	return regionScreenshotOCR(response, requestedOCR)
}

func validateScreenshotDisplay(returnedDisplay, requestedDisplay string) error {
	if !isCanonicalDisplayResourceName(returnedDisplay) {
		return fmt.Errorf("display is not a canonical resource name")
	}
	if requestedDisplay != "" && returnedDisplay != requestedDisplay {
		return fmt.Errorf("display does not match the request")
	}
	return nil
}

func validateEncodedScreenshot(
	imageData []byte,
	returnedFormat pb.ImageFormat,
	width int32,
	height int32,
	requestedFormat pb.ImageFormat,
) error {
	if returnedFormat != requestedFormat {
		return fmt.Errorf("format does not match the request")
	}
	if len(imageData) == 0 || width <= 0 || height <= 0 {
		return fmt.Errorf("encoded image metadata is empty or non-positive")
	}
	if int64(width)*int64(height) > maxDecodedScreenshotPixels {
		return fmt.Errorf("encoded image dimensions exceed the adapter decode limit")
	}

	configuration, decodedFormat, err := image.DecodeConfig(bytes.NewReader(imageData))
	if err != nil {
		return fmt.Errorf("encoded image is invalid: %w", err)
	}
	if decodedFormat != imageFormatDecoderName(returnedFormat) {
		return fmt.Errorf("encoded image format contradicts returned format")
	}
	if configuration.Width != int(width) || configuration.Height != int(height) {
		return fmt.Errorf("encoded image dimensions contradict returned dimensions")
	}
	decoded, fullyDecodedFormat, err := image.Decode(bytes.NewReader(imageData))
	if err != nil {
		return fmt.Errorf("encoded image is not fully decodable: %w", err)
	}
	if fullyDecodedFormat != decodedFormat {
		return fmt.Errorf("encoded image format changed during full decoding")
	}
	decodedBounds := decoded.Bounds()
	if decodedBounds.Dx() != int(width) || decodedBounds.Dy() != int(height) {
		return fmt.Errorf("fully decoded image dimensions contradict returned dimensions")
	}
	return nil
}

func validateScreenshotGeometry(
	region *typepb.Region,
	scale float64,
	width int32,
	height int32,
) error {
	if !validScreenshotRegion(region) {
		return fmt.Errorf("captured region is missing or invalid")
	}
	if !isFinitePositiveScreenshot(scale) {
		return fmt.Errorf("scale is not finite and positive")
	}
	if math.Abs(float64(width)-region.Width*scale) >= 1 ||
		math.Abs(float64(height)-region.Height*scale) >= 1 {
		return fmt.Errorf("pixel dimensions contradict returned geometry")
	}
	return nil
}

func imageFormatDecoderName(format pb.ImageFormat) string {
	switch format {
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		return "jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		return "tiff"
	case pb.ImageFormat_IMAGE_FORMAT_PNG:
		return "png"
	default:
		return ""
	}
}
