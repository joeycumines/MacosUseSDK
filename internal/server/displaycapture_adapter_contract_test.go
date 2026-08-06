// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"math"
	"strconv"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"golang.org/x/image/tiff"
	"google.golang.org/protobuf/proto"
)

func TestGetDisplayContractPreservesExactTopologyAndCursorTruth(t *testing.T) {
	displays := validDisplayContractResponse()
	cursor := validDisplayContractCursor()
	server := newTestMCPServerWithDisplayClient(&mockCUADisplayClient{
		listDisplaysFunc: func(context.Context, *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return displays, nil
		},
		captureCursorPositionFunc: func(context.Context, *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return cursor, nil
		},
	})

	result, panicValue, err := invokeGetDisplayContract(server, &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{}`),
	})
	if panicValue != nil {
		t.Fatalf("cuaHandleGetDisplay() panic = %v", panicValue)
	}
	if err != nil {
		t.Fatalf("cuaHandleGetDisplay() error = %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("cuaHandleGetDisplay() tool error = %q", resultText(result))
	}
	text := resultText(result)
	for _, expected := range []string{
		"- displays/17 (id 17, main)",
		"scale 1.234375",
		"Cursor position: (-9.125, 20.875) on displays/17",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("get_display result %q does not contain %q", text, expected)
		}
	}
}

func TestGetDisplayContractRejectsUntruthfulTopologyAndCursor(t *testing.T) {
	tests := []struct {
		name          string
		mutate        func(*pb.ListDisplaysResponse)
		cursor        *pb.CaptureCursorPositionResponse
		cursorFailure error
	}{
		{name: "empty displays", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays = nil
		}},
		{name: "nil display", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0] = nil
		}},
		{name: "zero id", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].DisplayId = 0
		}},
		{name: "id exceeds CGDirectDisplayID", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].DisplayId = 1 << 32
		}},
		{name: "name does not match id", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Name = "displays/18"
		}},
		{name: "duplicate identity", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays = append(response.Displays, proto.Clone(response.Displays[0]).(*pb.Display))
		}},
		{name: "missing frame", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Frame = nil
		}},
		{name: "missing visible frame", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].VisibleFrame = nil
		}},
		{name: "nonfinite frame", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Frame.X = math.NaN()
		}},
		{name: "nonpositive frame", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Frame.Width = 0
		}},
		{name: "visible frame outside frame", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].VisibleFrame.X = response.Displays[0].Frame.X - 1
		}},
		{name: "nonpositive scale", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Scale = 0
		}},
		{name: "nonfinite scale", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].Scale = math.Inf(1)
		}},
		{name: "missing main", mutate: func(response *pb.ListDisplaysResponse) {
			response.Displays[0].IsMain = false
		}},
		{name: "multiple main", mutate: func(response *pb.ListDisplaysResponse) {
			other := proto.Clone(response.Displays[0]).(*pb.Display)
			other.Name = "displays/18"
			other.DisplayId = 18
			response.Displays = append(response.Displays, other)
		}},
		{name: "cursor failure", cursorFailure: errors.New("cursor sentinel")},
		{name: "nil cursor response"},
		{name: "nonfinite cursor", cursor: &pb.CaptureCursorPositionResponse{
			X: math.NaN(), Y: 20, Display: "displays/17",
		}},
		{name: "unknown cursor display", cursor: &pb.CaptureCursorPositionResponse{
			X: -9, Y: 20, Display: "displays/18",
		}},
		{name: "cursor outside claimed display", cursor: &pb.CaptureCursorPositionResponse{
			X: 1000, Y: 1000, Display: "displays/17",
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			displays := validDisplayContractResponse()
			if test.mutate != nil {
				test.mutate(displays)
			}
			cursor := test.cursor
			if cursor == nil && test.name != "nil cursor response" {
				cursor = validDisplayContractCursor()
			}
			server := newTestMCPServerWithDisplayClient(&mockCUADisplayClient{
				listDisplaysFunc: func(context.Context, *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
					return displays, nil
				},
				captureCursorPositionFunc: func(context.Context, *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
					return cursor, test.cursorFailure
				},
			})

			result, panicValue, err := invokeGetDisplayContract(server, &ToolCall{
				Name:      "get_display",
				Arguments: json.RawMessage(`{}`),
			})
			if panicValue != nil {
				t.Errorf("cuaHandleGetDisplay() panic = %v", panicValue)
				return
			}
			if err != nil {
				t.Fatalf("cuaHandleGetDisplay() error = %v", err)
			}
			if !resultIsError(result) {
				t.Fatalf("untruthful display/cursor response became success: %+v", result)
			}
		})
	}
}

func TestGetDisplayContractConsumesEveryPageExactlyOnce(t *testing.T) {
	first := validDisplayContractResponse()
	first.NextPageToken = "second"
	secondDisplay := proto.Clone(first.Displays[0]).(*pb.Display)
	secondDisplay.Name = "displays/18"
	secondDisplay.DisplayId = 18
	secondDisplay.Frame = &typepb.Region{X: 200.25, Y: -50.25, Width: 100, Height: 200.5}
	secondDisplay.VisibleFrame = proto.Clone(secondDisplay.Frame).(*typepb.Region)
	secondDisplay.IsMain = false

	var requests []*pb.ListDisplaysRequest
	server := newTestMCPServerWithDisplayClient(&mockCUADisplayClient{
		listDisplaysFunc: func(_ context.Context, request *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			requests = append(requests, proto.Clone(request).(*pb.ListDisplaysRequest))
			switch request.PageToken {
			case "":
				return first, nil
			case "second":
				return &pb.ListDisplaysResponse{Displays: []*pb.Display{secondDisplay}}, nil
			default:
				return nil, errors.New("unexpected page token")
			}
		},
		captureCursorPositionFunc: func(context.Context, *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{X: 210.5, Y: 20.25, Display: "displays/18"}, nil
		},
	})

	result, panicValue, err := invokeGetDisplayContract(
		server,
		&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)},
	)
	if panicValue != nil {
		t.Fatalf("cuaHandleGetDisplay() panic = %v", panicValue)
	}
	if err != nil {
		t.Fatalf("cuaHandleGetDisplay() error = %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("cuaHandleGetDisplay() tool error = %q", resultText(result))
	}
	if len(requests) != 2 ||
		requests[0].PageSize <= 0 || requests[0].PageToken != "" ||
		requests[1].PageSize != requests[0].PageSize || requests[1].PageToken != "second" {
		t.Fatalf("ListDisplays requests = %+v, want one bounded request per page", requests)
	}
	for _, expected := range []string{"displays/17", "displays/18", "on displays/18"} {
		if !strings.Contains(resultText(result), expected) {
			t.Fatalf("get_display result %q does not contain %q", resultText(result), expected)
		}
	}
}

func TestGetDisplayContractRejectsPaginationCyclesAndCrossPageDuplicates(t *testing.T) {
	tests := []struct {
		name   string
		second *pb.ListDisplaysResponse
	}{
		{
			name: "token cycle",
			second: &pb.ListDisplaysResponse{
				NextPageToken: "second",
			},
		},
		{
			name: "duplicate identity",
			second: &pb.ListDisplaysResponse{
				Displays: []*pb.Display{validDisplayContractResponse().Displays[0]},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			first := validDisplayContractResponse()
			first.NextPageToken = "second"
			server := newTestMCPServerWithDisplayClient(&mockCUADisplayClient{
				listDisplaysFunc: func(_ context.Context, request *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
					if request.PageToken == "" {
						return first, nil
					}
					return test.second, nil
				},
				captureCursorPositionFunc: func(context.Context, *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
					t.Fatal("CaptureCursorPosition must not run for invalid pagination")
					return nil, nil
				},
			})

			result, panicValue, err := invokeGetDisplayContract(
				server,
				&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)},
			)
			if panicValue != nil {
				t.Errorf("cuaHandleGetDisplay() panic = %v", panicValue)
				return
			}
			if err != nil {
				t.Fatalf("cuaHandleGetDisplay() error = %v", err)
			}
			if !resultIsError(result) {
				t.Fatalf("invalid pagination became success: %+v", result)
			}
		})
	}
}

func TestScreenshotContractRejectsQualityIntentOutsideJPEGBeforeBackend(t *testing.T) {
	tests := []string{
		`{"quality":50}`,
		`{"format":"png","quality":50}`,
		`{"format":"tiff","quality":50}`,
	}
	for _, arguments := range tests {
		t.Run(arguments, func(t *testing.T) {
			calls := 0
			server := newTestMCPServer(&screenshotTestClient{
				captureScreenshot: func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					calls++
					return validDisplayScreenshotContractResponse(t), nil
				},
			})
			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(arguments),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if !resultIsError(result) {
				t.Fatalf("non-JPEG quality intent became success: %+v", result)
			}
			if calls != 0 {
				t.Fatalf("backend calls = %d, want 0", calls)
			}
		})
	}
}

func TestScreenshotContractForwardsOnlyCoherentQuality(t *testing.T) {
	tests := []struct {
		arguments   string
		wantFormat  pb.ImageFormat
		wantQuality int32
	}{
		{arguments: `{}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_PNG},
		{arguments: `{"format":"tiff"}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_TIFF},
		{arguments: `{"format":"jpeg"}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: defaultJPEGQuality},
		{arguments: `{"format":"jpeg","quality":73}`, wantFormat: pb.ImageFormat_IMAGE_FORMAT_JPEG, wantQuality: 73},
	}
	for _, test := range tests {
		t.Run(test.arguments, func(t *testing.T) {
			var request *pb.CaptureScreenshotRequest
			server := newTestMCPServer(&screenshotTestClient{
				captureScreenshot: func(_ context.Context, received *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					request = received
					return nil, errors.New("coherent request reached backend")
				},
			})
			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(test.arguments),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if !resultIsError(result) || !strings.Contains(resultText(result), "coherent request reached backend") {
				t.Fatalf("coherent request did not reach backend truthfully: %+v", result)
			}
			if request == nil || request.Format != test.wantFormat || request.Quality != test.wantQuality {
				t.Fatalf("request = %+v, want format=%s quality=%d", request, test.wantFormat, test.wantQuality)
			}
		})
	}
}

func TestScreenshotContractAcceptsValidEncodedFormats(t *testing.T) {
	tests := []pb.ImageFormat{
		pb.ImageFormat_IMAGE_FORMAT_PNG,
		pb.ImageFormat_IMAGE_FORMAT_JPEG,
		pb.ImageFormat_IMAGE_FORMAT_TIFF,
	}
	for _, format := range tests {
		t.Run(format.String(), func(t *testing.T) {
			response := validDisplayScreenshotContractResponse(t)
			response.Format = format
			response.ImageData = encodedScreenshotContractImage(t, format, int(response.Width), int(response.Height))
			server := newTestMCPServer(&screenshotTestClient{
				captureScreenshot: func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					return response, nil
				},
			})
			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(`{"display":"displays/17","format":"` + screenshotFormatArgument(format) + `"}`),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("valid %s response failed: %q", format, resultText(result))
			}
			if len(result.Content) == 0 || result.Content[0].MimeType != imageFormatToMediaType(format) {
				t.Fatalf("valid %s response MIME content = %+v", format, result.Content)
			}
		})
	}
}

func TestDisplayScreenshotContractRejectsInvalidBackendTruth(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*pb.CaptureScreenshotResponse)
	}{
		{name: "nil response"},
		{name: "display mismatch", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Display = "displays/18"
		}},
		{name: "noncanonical display", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Display = "displays/017"
		}},
		{name: "format mismatch", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Format = pb.ImageFormat_IMAGE_FORMAT_JPEG
		}},
		{name: "empty image", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.ImageData = nil
		}},
		{name: "invalid encoded image", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.ImageData = []byte("not a PNG")
		}},
		{name: "zero width", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Width = 0
		}},
		{name: "encoded dimension mismatch", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Width++
		}},
		{name: "missing region", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Region = nil
		}},
		{name: "nonfinite region", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Region.X = math.NaN()
		}},
		{name: "nonpositive scale", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Scale = 0
		}},
		{name: "nonfinite scale", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Scale = math.Inf(1)
		}},
		{name: "pixel geometry mismatch", mutate: func(response *pb.CaptureScreenshotResponse) {
			response.Region.Width--
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var response *pb.CaptureScreenshotResponse
			if test.name != "nil response" {
				response = validDisplayScreenshotContractResponse(t)
				if test.mutate != nil {
					test.mutate(response)
				}
			}
			calls := 0
			server := newTestMCPServer(&screenshotTestClient{
				captureScreenshot: func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					calls++
					return response, nil
				},
			})
			result, err := server.handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(`{"display":"displays/17"}`),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if calls != 1 {
				t.Fatalf("backend calls = %d, want 1", calls)
			}
			assertScreenshotToolErrorWithoutImage(t, result)
		})
	}
}

func TestRegionScreenshotContractRejectsInvalidBackendTruth(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*pb.CaptureRegionScreenshotResponse)
	}{
		{name: "nil response"},
		{name: "display mismatch", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Display = "displays/18"
		}},
		{name: "format mismatch", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Format = pb.ImageFormat_IMAGE_FORMAT_JPEG
		}},
		{name: "invalid encoded image", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.ImageData = []byte("not a PNG")
		}},
		{name: "encoded dimension mismatch", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Height++
		}},
		{name: "missing region", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Region = nil
		}},
		{name: "returned region does not contain request", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Region.X = 11
		}},
		{name: "nonpositive scale", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Scale = 0
		}},
		{name: "pixel geometry mismatch", mutate: func(response *pb.CaptureRegionScreenshotResponse) {
			response.Region.Height--
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var response *pb.CaptureRegionScreenshotResponse
			if test.name != "nil response" {
				response = validRegionScreenshotContractResponse(t)
				if test.mutate != nil {
					test.mutate(response)
				}
			}
			calls := 0
			server := newTestMCPServer(&screenshotTestClient{
				captureRegionScreenshot: func(context.Context, *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
					calls++
					return response, nil
				},
			})
			result, err := server.handleScreenshot(&ToolCall{
				Name: "screenshot",
				Arguments: json.RawMessage(
					`{"display":"displays/17","x":10.25,"y":20.5,"width":3.5,"height":3.5}`,
				),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if calls != 1 {
				t.Fatalf("backend calls = %d, want 1", calls)
			}
			assertScreenshotToolErrorWithoutImage(t, result)
		})
	}
}

func TestDisplayAndRegionScreenshotSummariesPreserveExactReturnedFloats(t *testing.T) {
	tests := []struct {
		name       string
		arguments  string
		client     *screenshotTestClient
		wantValues []float64
	}{
		{
			name:      "display",
			arguments: `{"display":"displays/17"}`,
			client: &screenshotTestClient{
				captureScreenshot: func(context.Context, *pb.CaptureScreenshotRequest) (*pb.CaptureScreenshotResponse, error) {
					return validDisplayScreenshotContractResponse(t), nil
				},
			},
			wantValues: []float64{-100.125, -50.25, 64, 64, 1.234375},
		},
		{
			name:      "region",
			arguments: `{"display":"displays/17","x":10.25,"y":20.5,"width":3.5,"height":3.5}`,
			client: &screenshotTestClient{
				captureRegionScreenshot: func(context.Context, *pb.CaptureRegionScreenshotRequest) (*pb.CaptureRegionScreenshotResponse, error) {
					return validRegionScreenshotContractResponse(t), nil
				},
			},
			wantValues: []float64{10, 20, 4, 4, 1.25},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result, err := newTestMCPServer(test.client).handleScreenshot(&ToolCall{
				Name:      "screenshot",
				Arguments: json.RawMessage(test.arguments),
			})
			if err != nil {
				t.Fatalf("handleScreenshot() error = %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("handleScreenshot() tool error = %q", resultText(result))
			}
			summary := resultText(result)
			for _, value := range test.wantValues {
				expected := strconv.FormatFloat(value, 'g', -1, 64)
				if !strings.Contains(summary, expected) {
					t.Errorf("summary %q does not contain exact value %q", summary, expected)
				}
			}
		})
	}
}

func validDisplayContractResponse() *pb.ListDisplaysResponse {
	return &pb.ListDisplaysResponse{Displays: []*pb.Display{{
		Name:         "displays/17",
		DisplayId:    17,
		Frame:        &typepb.Region{X: -100.5, Y: -50.25, Width: 300.75, Height: 200.5},
		VisibleFrame: &typepb.Region{X: -100.125, Y: -49.75, Width: 299.5, Height: 199.25},
		IsMain:       true,
		Scale:        1.234375,
	}}}
}

func validDisplayContractCursor() *pb.CaptureCursorPositionResponse {
	return &pb.CaptureCursorPositionResponse{
		X:       -9.125,
		Y:       20.875,
		Display: "displays/17",
	}
}

func validDisplayScreenshotContractResponse(t *testing.T) *pb.CaptureScreenshotResponse {
	t.Helper()
	const (
		width  = 79
		height = 79
	)
	return &pb.CaptureScreenshotResponse{
		ImageData: encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, width, height),
		Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
		Width:     width,
		Height:    height,
		Display:   "displays/17",
		Region:    &typepb.Region{X: -100.125, Y: -50.25, Width: 64, Height: 64},
		Scale:     1.234375,
	}
}

func validRegionScreenshotContractResponse(t *testing.T) *pb.CaptureRegionScreenshotResponse {
	t.Helper()
	return &pb.CaptureRegionScreenshotResponse{
		ImageData: encodedScreenshotContractImage(t, pb.ImageFormat_IMAGE_FORMAT_PNG, 5, 5),
		Format:    pb.ImageFormat_IMAGE_FORMAT_PNG,
		Width:     5,
		Height:    5,
		Display:   "displays/17",
		Region:    &typepb.Region{X: 10, Y: 20, Width: 4, Height: 4},
		Scale:     1.25,
	}
}

func encodedScreenshotContractImage(
	t *testing.T,
	format pb.ImageFormat,
	width int,
	height int,
) []byte {
	t.Helper()
	pixels := image.NewRGBA(image.Rect(0, 0, width, height))
	pixels.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
	var encoded bytes.Buffer
	switch format {
	case pb.ImageFormat_IMAGE_FORMAT_PNG:
		if err := png.Encode(&encoded, pixels); err != nil {
			t.Fatalf("encode PNG fixture: %v", err)
		}
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		if err := jpeg.Encode(&encoded, pixels, &jpeg.Options{Quality: 85}); err != nil {
			t.Fatalf("encode JPEG fixture: %v", err)
		}
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		if err := tiff.Encode(&encoded, pixels, nil); err != nil {
			t.Fatalf("encode TIFF fixture: %v", err)
		}
	default:
		t.Fatalf("unsupported fixture image format %s", format)
	}
	return encoded.Bytes()
}

func screenshotFormatArgument(format pb.ImageFormat) string {
	switch format {
	case pb.ImageFormat_IMAGE_FORMAT_PNG:
		return "png"
	case pb.ImageFormat_IMAGE_FORMAT_JPEG:
		return "jpeg"
	case pb.ImageFormat_IMAGE_FORMAT_TIFF:
		return "tiff"
	default:
		return "unsupported"
	}
}

func invokeGetDisplayContract(
	server *MCPServer,
	call *ToolCall,
) (result *ToolResult, panicValue any, err error) {
	defer func() {
		panicValue = recover()
	}()
	result, err = server.cuaHandleGetDisplay(call)
	return result, nil, err
}
