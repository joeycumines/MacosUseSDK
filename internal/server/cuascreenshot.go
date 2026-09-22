// Copyright 2025 Joseph Cumines
//
// Screenshot tool dispatch and request validation.

package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	statuspb "google.golang.org/genproto/googleapis/rpc/status"
)

// handleScreenshot handles the screenshot tool by selecting exactly one of
// full-display, window, or region capture.
func (s *MCPServer) handleScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Display string   `json:"display"`
		Window  string   `json:"window"`
		X       *float64 `json:"x"`
		Y       *float64 `json:"y"`
		Width   *float64 `json:"width"`
		Height  *float64 `json:"height"`
		Format  string   `json:"format"`
		Quality *int32   `json:"quality"`
		OCR     bool     `json:"ocr"`
		Shadow  *bool    `json:"include_shadow"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.Display != "" && !isCanonicalDisplayResourceName(params.Display) {
		return errorResult("display must be an exact displays/{display} resource name returned by get_display"), nil
	}
	if !isSupportedScreenshotFormat(params.Format) {
		return errorResult("format must be one of: png, jpeg, tiff"), nil
	}
	format := parseImageFormat(params.Format)
	quality, err := screenshotQuality(format, params.Quality)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	hasRegion := params.X != nil || params.Y != nil || params.Width != nil || params.Height != nil
	hasCompleteRegion := params.X != nil && params.Y != nil && params.Width != nil && params.Height != nil

	if params.Window != "" {
		if params.Display != "" || hasRegion {
			return errorResult("window cannot be combined with display or region parameters"), nil
		}
		if _, err := parseCUAWindowResource(params.Window); err != nil {
			return errorResult(err.Error()), nil
		}
		includeShadow := params.Shadow != nil && *params.Shadow
		return s.captureWindowScreenshot(ctx, params.Window, format, quality, includeShadow, params.OCR)
	}
	if params.Shadow != nil {
		return errorResult("include_shadow requires window"), nil
	}
	if hasRegion {
		if !hasCompleteRegion {
			return errorResult("x, y, width, and height must all be provided for a region capture"), nil
		}
		return s.captureRegionScreenshot(
			ctx,
			params.Display,
			*params.X,
			*params.Y,
			*params.Width,
			*params.Height,
			format,
			quality,
			params.OCR,
		)
	}
	return s.captureDisplayScreenshot(ctx, params.Display, format, quality, params.OCR)
}

func (s *MCPServer) captureWindowScreenshot(
	ctx context.Context,
	window string,
	format pb.ImageFormat,
	quality int32,
	includeShadow bool,
	includeOCR bool,
) (*ToolResult, error) {
	resp, err := s.client.CaptureWindowScreenshot(ctx, &pb.CaptureWindowScreenshotRequest{
		Window:         window,
		Format:         format,
		Quality:        quality,
		IncludeShadow:  includeShadow,
		IncludeOcrText: includeOCR,
	})
	if err != nil {
		return grpcErrorResult(err, "screenshot"), nil
	}
	ocr, err := validateWindowScreenshotResponse(
		resp,
		window,
		format,
		includeShadow,
		includeOCR,
	)
	if err != nil {
		return errorResultf("Invalid screenshot response: %v", err), nil
	}
	shadow := "excluded"
	if resp.ShadowIncluded {
		shadow = "included"
	}
	return screenshotResult(
		resp.ImageData,
		resp.Format,
		resp.Width,
		resp.Height,
		fmt.Sprintf(
			"Window screenshot: %dx%d pixels from %s, window %s, logical %s, scale %.15g, shadow %s, clipped %t",
			resp.Width,
			resp.Height,
			resp.Window,
			frameString(resp.WindowFrame),
			frameString(resp.Region),
			resp.Scale,
			shadow,
			resp.Clipped,
		),
		ocr,
	), nil
}

func (s *MCPServer) captureRegionScreenshot(
	ctx context.Context,
	display string,
	x float64,
	y float64,
	width float64,
	height float64,
	format pb.ImageFormat,
	quality int32,
	includeOCR bool,
) (*ToolResult, error) {
	if math.IsNaN(x) || math.IsInf(x, 0) || math.IsNaN(y) || math.IsInf(y, 0) {
		return errorResult("Region coordinates must be finite numbers"), nil
	}
	if width <= 0 || height <= 0 || math.IsNaN(width) || math.IsNaN(height) || math.IsInf(width, 0) || math.IsInf(height, 0) {
		return errorResult("Region width and height must be positive finite numbers"), nil
	}
	maxX := x + width
	maxY := y + height
	if !isFinite(maxX) || !isFinite(maxY) || maxX <= x || maxY <= y {
		return errorResult("Region must have finite, representable endpoints"), nil
	}
	requestedRegion := &typepb.Region{
		X:      x,
		Y:      y,
		Width:  width,
		Height: height,
	}
	resp, err := s.client.CaptureRegionScreenshot(ctx, &pb.CaptureRegionScreenshotRequest{
		Region:         requestedRegion,
		Format:         format,
		Quality:        quality,
		IncludeOcrText: includeOCR,
		Display:        display,
	})
	if err != nil {
		return grpcErrorResult(err, "screenshot"), nil
	}
	ocr, err := validateRegionScreenshotResponse(
		resp,
		display,
		requestedRegion,
		format,
		includeOCR,
	)
	if err != nil {
		return errorResultf("Invalid screenshot response: %v", err), nil
	}
	return screenshotResult(
		resp.ImageData,
		resp.Format,
		resp.Width,
		resp.Height,
		fmt.Sprintf(
			"Region screenshot: %dx%d pixels from %s, logical %s, scale %s",
			resp.Width,
			resp.Height,
			resp.Display,
			frameString(resp.Region),
			strconv.FormatFloat(resp.Scale, 'g', -1, 64),
		),
		ocr,
	), nil
}

func (s *MCPServer) captureDisplayScreenshot(
	ctx context.Context,
	display string,
	format pb.ImageFormat,
	quality int32,
	includeOCR bool,
) (*ToolResult, error) {
	resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
		Format:         format,
		Quality:        quality,
		Display:        display,
		IncludeOcrText: includeOCR,
	})
	if err != nil {
		return grpcErrorResult(err, "screenshot"), nil
	}
	ocr, err := validateDisplayScreenshotResponse(
		resp,
		display,
		format,
		includeOCR,
	)
	if err != nil {
		return errorResultf("Invalid screenshot response: %v", err), nil
	}
	return screenshotResult(
		resp.ImageData,
		resp.Format,
		resp.Width,
		resp.Height,
		fmt.Sprintf(
			"Screenshot: %dx%d pixels from %s, logical %s, scale %s",
			resp.Width,
			resp.Height,
			resp.Display,
			frameString(resp.Region),
			strconv.FormatFloat(resp.Scale, 'g', -1, 64),
		),
		ocr,
	), nil
}

func isCanonicalDisplayResourceName(name string) bool {
	displayIDText, ok := strings.CutPrefix(name, "displays/")
	if !ok || displayIDText == "" || strings.Contains(displayIDText, "/") {
		return false
	}
	displayID, err := strconv.ParseUint(displayIDText, 10, 32)
	return err == nil && displayID > 0 && strconv.FormatUint(displayID, 10) == displayIDText
}

func isSupportedScreenshotFormat(format string) bool {
	switch format {
	case "", "png", "jpeg", "tiff":
		return true
	default:
		return false
	}
}

type screenshotOCRResult struct {
	text      *string
	failure   string
	requested bool
}

// screenshotResult builds a ToolResult with image content and a truthful OCR
// outcome. Successful empty text remains distinct from not-requested and from
// partial OCR failure after image capture succeeds.
func screenshotResult(imageData []byte, format pb.ImageFormat, width, height int32, summary string, ocr screenshotOCRResult) *ToolResult {
	encoded := base64.StdEncoding.EncodeToString(imageData)
	mediaType := imageFormatToMediaType(format)

	result := &ToolResult{
		Content: []Content{
			{Type: "image", Data: encoded, MimeType: mediaType},
			{Type: "text", Text: summary},
		},
	}
	if ocr.requested && ocr.text != nil {
		result.Content = append(result.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("OCR Text:\n%s", *ocr.text),
		})
	} else if ocr.requested {
		warning := ocr.failure
		if warning == "" {
			warning = "OCR result was not returned"
		}
		result.Content = append(result.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("OCR warning: %s", warning),
		})
	}
	return result
}

func displayScreenshotOCR(response *pb.CaptureScreenshotResponse, requested bool) (screenshotOCRResult, error) {
	if response == nil {
		return screenshotOCRResult{}, fmt.Errorf("response is nil")
	}
	switch value := response.OcrResult.(type) {
	case *pb.CaptureScreenshotResponse_OcrText:
		if !requested || value == nil {
			return screenshotOCRResult{}, fmt.Errorf("OCR text does not match the request")
		}
		return screenshotOCRResult{requested: true, text: &value.OcrText}, nil
	case *pb.CaptureScreenshotResponse_OcrError:
		if value == nil {
			return validatedScreenshotOCRFailure(requested, true, nil)
		}
		return validatedScreenshotOCRFailure(requested, false, value.OcrError)
	case nil:
		if requested {
			return screenshotOCRResult{}, fmt.Errorf("requested OCR result is missing")
		}
		return screenshotOCRResult{}, nil
	default:
		return screenshotOCRResult{}, fmt.Errorf("OCR result has an unsupported type")
	}
}

func windowScreenshotOCR(response *pb.CaptureWindowScreenshotResponse, requested bool) (screenshotOCRResult, error) {
	switch value := response.OcrResult.(type) {
	case *pb.CaptureWindowScreenshotResponse_OcrText:
		if !requested || value == nil {
			return screenshotOCRResult{}, fmt.Errorf("OCR text does not match the request")
		}
		return screenshotOCRResult{requested: true, text: &value.OcrText}, nil
	case *pb.CaptureWindowScreenshotResponse_OcrError:
		if value == nil {
			return validatedScreenshotOCRFailure(requested, true, nil)
		}
		return validatedScreenshotOCRFailure(requested, false, value.OcrError)
	case nil:
		if requested {
			return screenshotOCRResult{}, fmt.Errorf("requested OCR result is missing")
		}
		return screenshotOCRResult{}, nil
	default:
		return screenshotOCRResult{}, fmt.Errorf("OCR result has an unsupported type")
	}
}

func regionScreenshotOCR(response *pb.CaptureRegionScreenshotResponse, requested bool) (screenshotOCRResult, error) {
	if response == nil {
		return screenshotOCRResult{}, fmt.Errorf("response is nil")
	}
	switch value := response.OcrResult.(type) {
	case *pb.CaptureRegionScreenshotResponse_OcrText:
		if !requested || value == nil {
			return screenshotOCRResult{}, fmt.Errorf("OCR text does not match the request")
		}
		return screenshotOCRResult{requested: true, text: &value.OcrText}, nil
	case *pb.CaptureRegionScreenshotResponse_OcrError:
		if value == nil {
			return validatedScreenshotOCRFailure(requested, true, nil)
		}
		return validatedScreenshotOCRFailure(requested, false, value.OcrError)
	case nil:
		if requested {
			return screenshotOCRResult{}, fmt.Errorf("requested OCR result is missing")
		}
		return screenshotOCRResult{}, nil
	default:
		return screenshotOCRResult{}, fmt.Errorf("OCR result has an unsupported type")
	}
}

func validatedScreenshotOCRFailure(requested bool, nilWrapper bool, status *statuspb.Status) (screenshotOCRResult, error) {
	if !requested || nilWrapper || status == nil {
		return screenshotOCRResult{}, fmt.Errorf("OCR failure does not match the request")
	}
	if status.Code < 1 || status.Code > 16 {
		return screenshotOCRResult{}, fmt.Errorf("OCR failure status code is not canonical")
	}
	return screenshotOCRResult{
		requested: true,
		failure:   fmt.Sprintf("code %d: %s", status.Code, status.Message),
	}, nil
}

func validateWindowScreenshotResponse(
	response *pb.CaptureWindowScreenshotResponse,
	requestedWindow string,
	requestedFormat pb.ImageFormat,
	requestedShadow bool,
	requestedOCR bool,
) (screenshotOCRResult, error) {
	if response == nil {
		return screenshotOCRResult{}, fmt.Errorf("response is nil")
	}
	if response.Window != requestedWindow {
		return screenshotOCRResult{}, fmt.Errorf("window does not match the request")
	}
	if response.ShadowIncluded != requestedShadow {
		return screenshotOCRResult{}, fmt.Errorf("shadow choice does not match the request")
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
	if !validScreenshotRegion(response.WindowFrame) || !validScreenshotRegion(response.Region) {
		return screenshotOCRResult{}, fmt.Errorf("window geometry is missing or invalid")
	}
	if !isFinitePositiveScreenshot(response.Scale) {
		return screenshotOCRResult{}, fmt.Errorf("scale is not finite and positive")
	}
	if !screenshotRegionsIntersect(response.WindowFrame, response.Region) {
		return screenshotOCRResult{}, fmt.Errorf("captured region does not intersect the window")
	}
	contained := screenshotRegionContains(response.Region, response.WindowFrame, 0.001)
	if response.Clipped == contained {
		return screenshotOCRResult{}, fmt.Errorf("clipped flag contradicts returned geometry")
	}
	if math.Abs(float64(response.Width)-response.Region.Width*response.Scale) >= 1 ||
		math.Abs(float64(response.Height)-response.Region.Height*response.Scale) >= 1 {
		return screenshotOCRResult{}, fmt.Errorf("pixel dimensions contradict returned geometry")
	}
	return windowScreenshotOCR(response, requestedOCR)
}

func validScreenshotRegion(region *typepb.Region) bool {
	if region == nil ||
		!isFinite(region.X) || !isFinite(region.Y) ||
		!isFinitePositiveScreenshot(region.Width) || !isFinitePositiveScreenshot(region.Height) {
		return false
	}
	maxX := region.X + region.Width
	maxY := region.Y + region.Height
	return isFinite(maxX) && isFinite(maxY) &&
		maxX > region.X && maxY > region.Y
}

func screenshotRegionsIntersect(left, right *typepb.Region) bool {
	return left.X < right.X+right.Width && right.X < left.X+left.Width &&
		left.Y < right.Y+right.Height && right.Y < left.Y+left.Height
}

func screenshotRegionContains(outer, inner *typepb.Region, tolerance float64) bool {
	return inner.X >= outer.X-tolerance && inner.Y >= outer.Y-tolerance &&
		inner.X+inner.Width <= outer.X+outer.Width+tolerance &&
		inner.Y+inner.Height <= outer.Y+outer.Height+tolerance
}

func isFinitePositiveScreenshot(value float64) bool {
	return isFinite(value) && value > 0
}
