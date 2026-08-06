// Copyright 2025 Joseph Cumines
//
// Screenshot tool contract and dispatch tests.

package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"image"
	"math"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	statuspb "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
)

type screenshotTestClient struct {
	pb.MacosUseClient
	captureScreenshot       func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error)
	captureWindowScreenshot func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error)
	captureRegionScreenshot func(context.Context, *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error)
}

func (c *screenshotTestClient) CaptureScreenshot(
	ctx context.Context,
	request *pb.CaptureScreenshotRequest,
	_ ...grpc.CallOption,
) (*pb.CaptureScreenshotResponse, error) {
	if c.captureScreenshot == nil {
		panic("unexpected CaptureScreenshot call")
	}
	return c.captureScreenshot(ctx, request)
}

func (c *screenshotTestClient) CaptureWindowScreenshot(
	ctx context.Context,
	request *pb.CaptureWindowScreenshotRequest,
	_ ...grpc.CallOption,
) (*pb.CaptureWindowScreenshotResponse, error) {
	if c.captureWindowScreenshot == nil {
		panic("unexpected CaptureWindowScreenshot call")
	}
	return c.captureWindowScreenshot(ctx, request)
}

func (c *screenshotTestClient) CaptureRegionScreenshot(
	ctx context.Context,
	request *pb.CaptureRegionScreenshotRequest,
	_ ...grpc.CallOption,
) (*pb.CaptureRegionScreenshotResponse, error) {
	if c.captureRegionScreenshot == nil {
		panic("unexpected CaptureRegionScreenshot call")
	}
	return c.captureRegionScreenshot(ctx, request)
}

func TestCUAHandleScreenshotForwardsExactDisplayResource(t *testing.T) {
	t.Run("full display", func(t *testing.T) {
		var captured *pb.CaptureScreenshotRequest
		client := &screenshotTestClient{
			captureScreenshot: func(_ context.Context, request *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
				captured = request
				return &pb.CaptureScreenshotResponse{
					ImageData: encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, 20, 10),
					Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
					Width:     20,
					Height:    10,
					Display:   "displays/42",
					Region:    &typepb.Region{X: -1920, Y: 0, Width: 10, Height: 5},
					Scale:     2,
				}, nil
			},
		}
		server := newTestMCPServer(client)

		result, err := server.handleScreenshot(&ToolCall{
			Name:      "screenshot",
			Arguments: json.RawMessage(`{"display":"displays/42"}`),
		})
		if err != nil {
			t.Fatalf("handleScreenshot returned error: %v", err)
		}
		if resultIsError(result) {
			t.Fatalf("handleScreenshot returned tool error: %s", resultText(result))
		}
		if captured == nil {
			t.Fatal("CaptureScreenshot was not called")
		}
		if captured.Display != "displays/42" {
			t.Fatalf("display = %q, want exact resource name", captured.Display)
		}
		if captured.Quality != 0 {
			t.Fatalf("PNG quality = %d, want omitted zero", captured.Quality)
		}
		if summary := resultText(result); !strings.Contains(summary, "displays/42") ||
			!strings.Contains(summary, "logical 10x5 @ (-1920, 0), scale 2") {
			t.Fatalf("summary does not use returned source metadata: %q", summary)
		}
	})

	t.Run("region", func(t *testing.T) {
		var captured *pb.CaptureRegionScreenshotRequest
		client := &screenshotTestClient{
			captureRegionScreenshot: func(_ context.Context, request *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
				captured = request
				return &pb.CaptureRegionScreenshotResponse{
					ImageData: encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, 152, 122),
					Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
					Width:     152,
					Height:    122,
					Display:   "displays/7",
					Region:    &typepb.Region{X: 9.5, Y: 19.5, Width: 101, Height: 81},
					Scale:     1.5,
				}, nil
			},
		}
		server := newTestMCPServer(client)

		result, err := server.handleScreenshot(&ToolCall{
			Name:      "screenshot",
			Arguments: json.RawMessage(`{"display":"displays/7","x":10,"y":20,"width":100,"height":80}`),
		})
		if err != nil {
			t.Fatalf("handleScreenshot returned error: %v", err)
		}
		if resultIsError(result) {
			t.Fatalf("handleScreenshot returned tool error: %s", resultText(result))
		}
		if captured == nil {
			t.Fatal("CaptureRegionScreenshot was not called")
		}
		if captured.Display != "displays/7" {
			t.Fatalf("display = %q, want exact resource name", captured.Display)
		}
		if captured.Region == nil || captured.Region.X != 10 || captured.Region.Y != 20 || captured.Region.Width != 100 || captured.Region.Height != 80 {
			t.Fatalf("region was not forwarded exactly: %+v", captured.Region)
		}
		if summary := resultText(result); !strings.Contains(summary, "displays/7") ||
			!strings.Contains(summary, "logical 101x81 @ (9.5, 19.5), scale 1.5") {
			t.Fatalf("summary does not use returned quantized metadata: %q", summary)
		}
	})
}

func TestCUAHandleScreenshotRejectsInvalidOrAmbiguousParameters(t *testing.T) {
	tests := []struct {
		name       string
		arguments  string
		wantSubstr string
	}{
		{name: "invalid JSON", arguments: `{bad`, wantSubstr: "Invalid parameters"},
		{name: "numeric display compatibility removed", arguments: `{"display":1}`, wantSubstr: "Invalid parameters"},
		{name: "wrong display collection", arguments: `{"display":"display/1"}`, wantSubstr: "exact displays/{display}"},
		{name: "zero display identifier", arguments: `{"display":"displays/0"}`, wantSubstr: "exact displays/{display}"},
		{name: "leading-zero display identifier", arguments: `{"display":"displays/01"}`, wantSubstr: "exact displays/{display}"},
		{name: "overflow display identifier", arguments: `{"display":"displays/4294967296"}`, wantSubstr: "exact displays/{display}"},
		{name: "format alias removed", arguments: `{"format":"jpg"}`, wantSubstr: "format must be one of"},
		{name: "negative quality", arguments: `{"quality":-1}`, wantSubstr: "quality must be between"},
		{name: "excessive quality", arguments: `{"quality":101}`, wantSubstr: "quality must be between"},
		{name: "quality without JPEG", arguments: `{"format":"png","quality":50}`, wantSubstr: "quality requires JPEG"},
		{name: "malformed window", arguments: `{"window":"applications/opaque/windows"}`, wantSubstr: "canonical applications/{application}/windows/{window}"},
		{name: "partial region", arguments: `{"x":10}`, wantSubstr: "must all be provided"},
		{name: "window and display", arguments: `{"window":"applications/1/windows/2","display":"displays/1"}`, wantSubstr: "cannot be combined"},
		{name: "window and region", arguments: `{"window":"applications/1/windows/2","x":0,"y":0,"width":10,"height":10}`, wantSubstr: "cannot be combined"},
		{name: "shadow true without window", arguments: `{"include_shadow":true}`, wantSubstr: "include_shadow requires window"},
		{name: "shadow false without window", arguments: `{"include_shadow":false}`, wantSubstr: "include_shadow requires window"},
		{name: "zero region width", arguments: `{"x":0,"y":0,"width":0,"height":10}`, wantSubstr: "positive finite numbers"},
		{name: "collapsed region x endpoint", arguments: `{"x":1.7976931348623157e308,"y":0,"width":1,"height":10}`, wantSubstr: "representable endpoints"},
		{name: "collapsed region y endpoint", arguments: `{"x":0,"y":1.7976931348623157e308,"width":10,"height":1}`, wantSubstr: "representable endpoints"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			client := &screenshotTestClient{
				captureScreenshot: func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					calls++
					return nil, errors.New("unexpected display capture")
				},
				captureWindowScreenshot: func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
					calls++
					return nil, errors.New("unexpected window capture")
				},
				captureRegionScreenshot: func(context.Context, *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
					calls++
					return nil, errors.New("unexpected region capture")
				},
			}
			server := newTestMCPServer(client)
			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(test.arguments),
			})
			if err != nil {
				t.Fatalf("handleScreenshot returned error: %v", err)
			}
			if !resultIsError(result) {
				t.Fatalf("expected tool error, got: %+v", result)
			}
			if !resultContains(result, test.wantSubstr) {
				t.Fatalf("result %q does not contain %q", resultText(result), test.wantSubstr)
			}
			if calls != 0 {
				t.Fatalf("invalid arguments reached backend %d times", calls)
			}
		})
	}
}

func TestCUAHandleScreenshotForwardsCanonicalQuality(t *testing.T) {
	tests := []struct {
		name        string
		arguments   string
		wantFormat  pb.ImageFormat
		wantQuality int32
	}{
		{name: "omitted format is PNG", arguments: `{}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_PNG},
		{name: "explicit PNG zero", arguments: `{"format":"png","quality":0}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_PNG},
		{name: "explicit TIFF zero", arguments: `{"format":"tiff","quality":0}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_TIFF},
		{name: "omitted JPEG quality defaults", arguments: `{"format":"jpeg"}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: 85},
		{name: "zero JPEG quality defaults", arguments: `{"format":"jpeg","quality":0}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: 85},
		{name: "minimum JPEG quality preserved", arguments: `{"format":"jpeg","quality":1}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: 1},
		{name: "maximum JPEG quality preserved", arguments: `{"format":"jpeg","quality":100}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: 100},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var captured *pb.CaptureScreenshotRequest
			server := newTestMCPServer(&screenshotTestClient{
				captureScreenshot: func(_ context.Context, request *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					captured = request
					return &pb.CaptureScreenshotResponse{
						ImageData: encodedScreenshotContractImage(t, test.wantFormat, 1, 1),
						Format:    test.wantFormat,
						Width:     1,
						Height:    1,
						Display:   "displays/1",
						Region:    &typepb.Region{Width: 1, Height: 1},
						Scale:     1,
					}, nil
				},
			})

			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(test.arguments),
			})
			if err != nil {
				t.Fatalf("handleScreenshot returned error: %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("handleScreenshot returned tool error: %s", resultText(result))
			}
			if captured == nil {
				t.Fatal("CaptureScreenshot was not called")
			}
			if captured.Format != test.wantFormat || captured.Quality != test.wantQuality {
				t.Fatalf(
					"forwarded format/quality = %s/%d, want %s/%d",
					captured.Format,
					captured.Quality,
					test.wantFormat,
					test.wantQuality,
				)
			}
		})
	}
}

func TestCUAHandleWindowScreenshotForwardsShadowAndUsesReturnedMetadata(t *testing.T) {
	var captured *pb.CaptureWindowScreenshotRequest
	client := &screenshotTestClient{
		captureWindowScreenshot: func(_ context.Context, request *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			captured = request
			return &pb.CaptureWindowScreenshotResponse{
				ImageData:      encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, 208, 168),
				Format:         pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:          208,
				Height:         168,
				Window:         "applications/opaque/windows/exact",
				WindowFrame:    &typepb.Region{X: -30.25, Y: -20.5, Width: 100.5, Height: 80.25},
				Region:         &typepb.Region{X: -32.25, Y: -22.5, Width: 104, Height: 84},
				Scale:          2,
				ShadowIncluded: true,
				Clipped:        false,
				OcrResult: &pb.CaptureWindowScreenshotResponse_OcrError{
					OcrError: &statuspb.Status{Code: 13, Message: "OCR extraction failed"},
				},
			}, nil
		},
	}
	server := newTestMCPServer(client)

	result, err := server.handleScreenshot(&ToolCall{
		Name:      "screenshot",
		Arguments: json.RawMessage(`{"window":"applications/opaque/windows/exact","include_shadow":true,"ocr":true}`),
	})
	if err != nil {
		t.Fatalf("handleScreenshot returned error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("handleScreenshot returned tool error: %s", resultText(result))
	}
	if captured == nil || !captured.IncludeShadow {
		t.Fatalf("include_shadow was not forwarded exactly: %+v", captured)
	}
	text := resultText(result)
	for _, want := range []string{
		"applications/opaque/windows/exact",
		"-30.25",
		"-20.5",
		"-32.25",
		"-22.5",
		"scale 2",
		"shadow included",
		"OCR warning",
		"OCR extraction failed",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("returned metadata summary %q does not contain %q", text, want)
		}
	}
}

func TestCUAHandleWindowScreenshotRejectsInvalidBackendMetadata(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*pb.CaptureWindowScreenshotResponse)
	}{
		{name: "window", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.Window = "applications/other/windows/other"
		}},
		{name: "format", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Format = pb.ImageFormat_IMAGE_FORMAT_JPEG }},
		{name: "shadow", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.ShadowIncluded = false }},
		{name: "empty image", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.ImageData = nil }},
		{name: "zero width", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Width = 0 }},
		{name: "negative height", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Height = -1 }},
		{name: "missing window frame", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.WindowFrame = nil }},
		{name: "missing region", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Region = nil }},
		{name: "nonfinite origin", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Region.X = math.NaN() }},
		{name: "overflowing endpoint", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.Region.X = math.MaxFloat64
			response.Region.Width = math.MaxFloat64
		}},
		{name: "collapsed finite endpoint", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.Region.X = math.MaxFloat64
			response.Region.Width = 1
		}},
		{name: "nonpositive scale", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Scale = 0 }},
		{name: "nonfinite scale", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Scale = math.Inf(1) }},
		{name: "disjoint region", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Region.X = 1000 }},
		{name: "one pixel mismatch", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Width = 207 }},
		{name: "false clipped", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.Region.X = -29
			response.Clipped = false
		}},
		{name: "false unclipped", mutate: func(response *pb.CaptureWindowScreenshotResponse) { response.Clipped = true }},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := validWindowScreenshotResponse(t, pb.ImageFormat_IMAGE_FORMAT_PNG)
			test.mutate(response)
			calls := 0
			server := newTestMCPServer(&screenshotTestClient{
				captureWindowScreenshot: func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
					calls++
					return response, nil
				},
			})

			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(`{"window":"applications/opaque/windows/exact","include_shadow":true}`),
			})
			if err != nil {
				t.Fatalf("handleScreenshot returned error: %v", err)
			}
			if calls != 1 {
				t.Fatalf("backend calls = %d, want 1", calls)
			}
			assertScreenshotToolErrorWithoutImage(t, result)
		})
	}
}

func TestCUAHandleWindowScreenshotRejectsInconsistentOCR(t *testing.T) {
	tests := []struct {
		name      string
		requested bool
		mutate    func(*pb.CaptureWindowScreenshotResponse)
	}{
		{name: "unrequested text", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrText{OcrText: "unexpected"}
		}},
		{name: "unrequested error", mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrError{OcrError: &statuspb.Status{Code: 13}}
		}},
		{name: "requested missing", requested: true},
		{name: "requested typed nil text", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = (*pb.CaptureWindowScreenshotResponse_OcrText)(nil)
		}},
		{name: "requested typed nil error", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = (*pb.CaptureWindowScreenshotResponse_OcrError)(nil)
		}},
		{name: "requested nil status", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrError{}
		}},
		{name: "requested negative status", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrError{OcrError: &statuspb.Status{Code: -1}}
		}},
		{name: "requested OK status", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrError{OcrError: &statuspb.Status{Code: 0}}
		}},
		{name: "requested noncanonical status", requested: true, mutate: func(response *pb.CaptureWindowScreenshotResponse) {
			response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrError{OcrError: &statuspb.Status{Code: 17}}
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := validWindowScreenshotResponse(t, pb.ImageFormat_IMAGE_FORMAT_PNG)
			if test.mutate != nil {
				test.mutate(response)
			}
			server := newTestMCPServer(&screenshotTestClient{
				captureWindowScreenshot: func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
					return response, nil
				},
			})
			arguments := `{"window":"applications/opaque/windows/exact","include_shadow":true}`
			if test.requested {
				arguments = `{"window":"applications/opaque/windows/exact","include_shadow":true,"ocr":true}`
			}

			result, err := server.handleScreenshot(&ToolCall{Name: "screenshot", Arguments: json.RawMessage(arguments)})
			if err != nil {
				t.Fatalf("handleScreenshot returned error: %v", err)
			}
			assertScreenshotToolErrorWithoutImage(t, result)
		})
	}
}

func TestCUAHandleWindowScreenshotPreservesSuccessfulEmptyOCR(t *testing.T) {
	response := validWindowScreenshotResponse(t, pb.ImageFormat_IMAGE_FORMAT_PNG)
	response.OcrResult = &pb.CaptureWindowScreenshotResponse_OcrText{OcrText: ""}
	server := newTestMCPServer(&screenshotTestClient{
		captureWindowScreenshot: func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
			return response, nil
		},
	})
	result, err := server.handleScreenshot(&ToolCall{
		Name:      "screenshot",
		Arguments: json.RawMessage(`{"window":"applications/opaque/windows/exact","include_shadow":true,"ocr":true}`),
	})
	if err != nil {
		t.Fatalf("handleScreenshot returned error: %v", err)
	}
	if resultIsError(result) || !strings.Contains(resultText(result), "OCR Text:\n") {
		t.Fatalf("successful empty OCR result was not preserved: %+v", result)
	}
}

func TestCUAHandleWindowScreenshotRejectsMalformedImagesAndRecovers(t *testing.T) {
	for _, format := range []pb.ImageFormat{
		pb.ImageFormat_IMAGE_FORMAT_PNG,
		pb.ImageFormat_IMAGE_FORMAT_JPEG,
		pb.ImageFormat_IMAGE_FORMAT_TIFF,
	} {
		t.Run(format.String(), func(t *testing.T) {
			valid := validWindowScreenshotResponse(t, format)
			truncated := validWindowScreenshotResponse(t, format)
			truncated.ImageData = malformedScreenshotPassingConfig(t, format, truncated.ImageData)
			calls := 0
			server := newTestMCPServer(&screenshotTestClient{
				captureWindowScreenshot: func(context.Context, *pb.CaptureWindowScreenshotRequest) (*pb.CaptureWindowScreenshotResponse, error) {
					calls++
					if calls == 1 {
						return truncated, nil
					}
					return valid, nil
				},
			})
			arguments := `{"window":"applications/opaque/windows/exact","include_shadow":true,"format":"` +
				screenshotFormatArgument(format) + `"}`

			first, err := server.handleScreenshot(&ToolCall{Name: "screenshot", Arguments: json.RawMessage(arguments)})
			if err != nil {
				t.Fatalf("first handleScreenshot returned error: %v", err)
			}
			assertScreenshotToolErrorWithoutImage(t, first)

			second, err := server.handleScreenshot(&ToolCall{Name: "screenshot", Arguments: json.RawMessage(arguments)})
			if err != nil {
				t.Fatalf("second handleScreenshot returned error: %v", err)
			}
			if resultIsError(second) {
				t.Fatalf("subsequent valid request failed: %s", resultText(second))
			}
			if calls != 2 {
				t.Fatalf("backend calls = %d, want 2", calls)
			}
		})
	}
}

func validWindowScreenshotResponse(t *testing.T, format pb.ImageFormat) *pb.CaptureWindowScreenshotResponse {
	t.Helper()
	return &pb.CaptureWindowScreenshotResponse{
		ImageData:      encodedScreenshotContractImage(t, format, 208, 168),
		Format:         format,
		Width:          208,
		Height:         168,
		Window:         "applications/opaque/windows/exact",
		WindowFrame:    &typepb.Region{X: -30, Y: -20, Width: 100, Height: 80},
		Region:         &typepb.Region{X: -32, Y: -22, Width: 104, Height: 84},
		Scale:          2,
		ShadowIncluded: true,
		Clipped:        false,
	}
}

func malformedScreenshotPassingConfig(t *testing.T, format pb.ImageFormat, encoded []byte) []byte {
	t.Helper()
	if format == pb.ImageFormat_IMAGE_FORMAT_TIFF {
		candidate := append([]byte(nil), encoded...)
		if len(candidate) < 10 {
			t.Fatal("TIFF fixture is shorter than its header")
		}
		ifdOffset := int(binary.LittleEndian.Uint32(candidate[4:8]))
		if ifdOffset < 8 || ifdOffset+2 > len(candidate) {
			t.Fatalf("TIFF fixture has invalid IFD offset %d", ifdOffset)
		}
		entryCount := int(binary.LittleEndian.Uint16(candidate[ifdOffset : ifdOffset+2]))
		for index := range entryCount {
			entryOffset := ifdOffset + 2 + index*12
			if entryOffset+12 > len(candidate) {
				t.Fatal("TIFF fixture has a truncated IFD entry")
			}
			if binary.LittleEndian.Uint16(candidate[entryOffset:entryOffset+2]) != 273 {
				continue
			}
			binary.LittleEndian.PutUint32(candidate[entryOffset+8:entryOffset+12], uint32(len(candidate)+1))
			assertConfigOnlyImageFailure(t, candidate)
			return candidate
		}
		t.Fatal("TIFF fixture has no strip-offset entry")
	}
	for cut := len(encoded) - 1; cut > 0; cut-- {
		candidate := encoded[:cut]
		if _, _, err := image.DecodeConfig(bytes.NewReader(candidate)); err != nil {
			continue
		}
		if _, _, err := image.Decode(bytes.NewReader(candidate)); err != nil {
			return append([]byte(nil), candidate...)
		}
	}
	t.Fatal("fixture has no prefix with a decodable header and invalid full image")
	return nil
}

func assertConfigOnlyImageFailure(t *testing.T, encoded []byte) {
	t.Helper()
	if _, _, err := image.DecodeConfig(bytes.NewReader(encoded)); err != nil {
		t.Fatalf("malformed fixture must retain a decodable header: %v", err)
	}
	if _, _, err := image.Decode(bytes.NewReader(encoded)); err == nil {
		t.Fatal("malformed fixture unexpectedly decoded completely")
	}
}

func assertScreenshotToolErrorWithoutImage(t *testing.T, result *ToolResult) {
	t.Helper()
	if !resultIsError(result) {
		t.Fatalf("expected tool error, got: %+v", result)
	}
	for _, content := range result.Content {
		if content.Type == "image" {
			t.Fatalf("invalid backend response leaked image content: %+v", result)
		}
	}
}

func TestScreenshotResultPreservesExplicitEmptyOCRSuccess(t *testing.T) {
	client := &screenshotTestClient{
		captureScreenshot: func(_ context.Context, _ *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
			return &pb.CaptureScreenshotResponse{
				ImageData: encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, 1, 1),
				Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
				Width:     1,
				Height:    1,
				Display:   "displays/1",
				Region:    &typepb.Region{Width: 1, Height: 1},
				Scale:     1,
				OcrResult: &pb.CaptureScreenshotResponse_OcrText{OcrText: ""},
			}, nil
		},
	}
	server := newTestMCPServer(client)
	result, err := server.handleScreenshot(&ToolCall{
		Name:      "screenshot",
		Arguments: json.RawMessage(`{"ocr":true}`),
	})
	if err != nil {
		t.Fatalf("handleScreenshot returned error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("handleScreenshot returned tool error: %s", resultText(result))
	}
	if !strings.Contains(resultText(result), "OCR Text:\n") {
		t.Fatalf("explicit successful empty OCR was suppressed: %q", resultText(result))
	}
}

func TestScreenshotToolSchemaUsesExactDisplayResource(t *testing.T) {
	server := newTestServer()
	server.tools = make(map[string]*Tool)
	server.registerTools()

	tool := server.tools["screenshot"]
	if tool == nil {
		t.Fatal("screenshot tool is not registered")
	}
	properties, ok := tool.InputSchema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("properties schema has type %T", tool.InputSchema["properties"])
	}
	display, ok := properties["display"].(map[string]any)
	if !ok {
		t.Fatalf("display schema has type %T", properties["display"])
	}
	if display["type"] != "string" {
		t.Fatalf("display type = %v, want string", display["type"])
	}
	if display["pattern"] != "^displays/[1-9][0-9]*$" {
		t.Fatalf("display pattern = %v, want exact resource-name pattern", display["pattern"])
	}
	window, ok := properties["window"].(map[string]any)
	if !ok {
		t.Fatalf("window schema has type %T", properties["window"])
	}
	wantWindowPattern := `^applications/` + cuaOpaqueInputTargetIDPattern +
		`/windows/` + cuaOpaqueInputTargetIDPattern + `$`
	if window["pattern"] != wantWindowPattern {
		t.Fatalf("window pattern = %v, want %q", window["pattern"], wantWindowPattern)
	}

	quality, ok := properties["quality"].(map[string]any)
	if !ok {
		t.Fatalf("quality schema has type %T", properties["quality"])
	}
	if quality["minimum"] != 0 || quality["maximum"] != 100 {
		t.Fatalf("quality range = [%v, %v], want [0, 100]", quality["minimum"], quality["maximum"])
	}
	shadow, ok := properties["include_shadow"].(map[string]any)
	if !ok {
		t.Fatalf("include_shadow schema has type %T", properties["include_shadow"])
	}
	if shadow["type"] != "boolean" {
		t.Fatalf("include_shadow type = %v, want boolean", shadow["type"])
	}
	for _, name := range []string{"width", "height"} {
		property, ok := properties[name].(map[string]any)
		if !ok {
			t.Fatalf("%s schema has type %T", name, properties[name])
		}
		description, _ := property["description"].(string)
		if !strings.Contains(description, "logical display points") {
			t.Fatalf("%s description = %q, want logical display points", name, description)
		}
	}
}

func TestCanonicalDisplayResourceName(t *testing.T) {
	tests := []struct {
		name string
		want bool
	}{
		{name: "displays/1", want: true},
		{name: "displays/4294967295", want: true},
		{name: "", want: false},
		{name: "displays/0", want: false},
		{name: "displays/01", want: false},
		{name: "displays/4294967296", want: false},
		{name: "displays/1/extra", want: false},
		{name: "display/1", want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isCanonicalDisplayResourceName(test.name); got != test.want {
				t.Fatalf("isCanonicalDisplayResourceName(%q) = %t, want %t", test.name, got, test.want)
			}
		})
	}
}
