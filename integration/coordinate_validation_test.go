// Copyright 2025 Joseph Cumines
//
// Coordinate validation integration tests for Global Display Coordinates
// (top-left origin). Physical input is intentionally exercised only by tests
// that own and observe a golden-application target.

package integration

import (
	"context"
	"math"
	"testing"
	"time"

	pbtype "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func TestCoordinateValidation_DisplayFramesRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	response, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	if len(response.Displays) == 0 {
		t.Fatal("ListDisplays returned no displays")
	}

	var observedNegativeOrigin bool
	for _, display := range response.Displays {
		frame := display.GetFrame()
		if frame == nil || !finiteRegion(frame) || frame.GetWidth() <= 0 || frame.GetHeight() <= 0 {
			t.Fatalf("display %q returned invalid Global Display Coordinates frame: %+v", display.GetName(), frame)
		}
		if frame.GetX() < 0 || frame.GetY() < 0 {
			observedNegativeOrigin = true
		}
		roundTrip, err := client.GetDisplay(ctx, &pb.GetDisplayRequest{Name: display.GetName()})
		if err != nil {
			t.Fatalf("GetDisplay(%q) failed: %v", display.GetName(), err)
		}
		if roundTrip.GetDisplayId() != display.GetDisplayId() || !equalRegion(roundTrip.GetFrame(), frame) {
			t.Fatalf("display coordinate round trip changed identity or frame: listed=%+v fetched=%+v", display, roundTrip)
		}
	}
	if !observedNegativeOrigin {
		t.Log("current display topology has no left/above secondary display; no negative origin was fabricated")
	}
}

func TestCoordinateValidation_VisibleFrameRegionScreenshots(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	mainDisplay := requireMainDisplay(t, displays.Displays)
	frame := mainDisplay.GetVisibleFrame()
	if frame == nil {
		frame = mainDisplay.GetFrame()
	}
	if frame == nil || frame.GetWidth() < 4 || frame.GetHeight() < 4 {
		t.Fatalf("main display has no capturable visible frame: %+v", frame)
	}

	const sampleSize = 2.0
	samples := []struct {
		name string
		x    float64
		y    float64
	}{
		{name: "top_left", x: frame.GetX(), y: frame.GetY()},
		{name: "center", x: frame.GetX() + frame.GetWidth()/2 - 1, y: frame.GetY() + frame.GetHeight()/2 - 1},
		{name: "bottom_right", x: frame.GetX() + frame.GetWidth() - sampleSize, y: frame.GetY() + frame.GetHeight() - sampleSize},
	}
	for _, sample := range samples {
		t.Run(sample.name, func(t *testing.T) {
			requested := &pbtype.Region{X: sample.x, Y: sample.y, Width: sampleSize, Height: sampleSize}
			captured, err := client.CaptureRegionScreenshot(ctx, &pb.CaptureRegionScreenshotRequest{
				Region:  requested,
				Format:  pb.ImageFormat_IMAGE_FORMAT_PNG,
				Display: mainDisplay.GetName(),
			})
			if err != nil {
				t.Fatalf("CaptureRegionScreenshot(%s) failed: %v", sample.name, err)
			}
			if len(captured.GetImageData()) == 0 || captured.GetWidth() <= 0 || captured.GetHeight() <= 0 {
				t.Fatalf("CaptureRegionScreenshot(%s) returned empty image metadata: width=%d height=%d bytes=%d", sample.name, captured.GetWidth(), captured.GetHeight(), len(captured.GetImageData()))
			}
			if !equalRegion(captured.GetRegion(), requested) {
				t.Fatalf("CaptureRegionScreenshot(%s) changed Global Display Coordinates: got=%+v want=%+v", sample.name, captured.GetRegion(), requested)
			}
		})
	}
}

func TestCoordinateValidation_MCPRegionScreenshotViaHTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	mainDisplay := requireMainDisplay(t, displays.Displays)
	frame := mainDisplay.GetVisibleFrame()
	if frame == nil {
		frame = mainDisplay.GetFrame()
	}
	if frame == nil || frame.GetWidth() < 8 || frame.GetHeight() < 8 {
		t.Fatalf("main display has no MCP-capturable visible frame: %+v", frame)
	}

	_, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()
	requireMCPInitialize(t, baseURL)
	result := callProductionMCPTool(t, baseURL, 2, "screenshot", map[string]any{
		"display": mainDisplay.GetName(),
		"x":       frame.GetX() + 2,
		"y":       frame.GetY() + 2,
		"width":   4,
		"height":  4,
		"format":  "png",
	})
	var foundImage bool
	for _, content := range result.Content {
		if content.Type != "image" {
			continue
		}
		foundImage = true
		if content.Data == "" || content.MimeType != "image/png" {
			t.Fatalf("MCP region screenshot returned invalid image content: mime=%q bytes=%d", content.MimeType, len(content.Data))
		}
	}
	if !foundImage {
		t.Fatal("MCP region screenshot returned no image content")
	}
}

func TestCoordinateValidation_DisplayOrigins(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	mainDisplay := requireMainDisplay(t, displays.Displays)
	if mainDisplay.GetFrame().GetX() != 0 || mainDisplay.GetFrame().GetY() != 0 {
		t.Fatalf("main display Global Display Coordinates origin = (%v,%v), want (0,0)", mainDisplay.GetFrame().GetX(), mainDisplay.GetFrame().GetY())
	}
	for _, display := range displays.Displays {
		if display.GetScale() <= 0 {
			t.Fatalf("display %q returned invalid scale %v", display.GetName(), display.GetScale())
		}
		if !finiteRegion(display.GetFrame()) {
			t.Fatalf("display %q returned non-finite frame %+v", display.GetName(), display.GetFrame())
		}
	}
}

func requireMainDisplay(t *testing.T, displays []*pb.Display) *pb.Display {
	t.Helper()
	if len(displays) == 0 {
		t.Fatal("ListDisplays returned no displays")
	}
	mainIndex := -1
	for index, display := range displays {
		if display.GetIsMain() {
			if mainIndex != -1 {
				t.Fatalf("ListDisplays returned multiple main displays: %q and %q", displays[mainIndex].GetName(), display.GetName())
			}
			mainIndex = index
		}
	}
	if mainIndex == -1 {
		t.Fatal("ListDisplays returned no display marked main")
	}
	return displays[mainIndex]
}

func finiteRegion(region *pbtype.Region) bool {
	return region != nil &&
		!math.IsNaN(region.GetX()) && !math.IsInf(region.GetX(), 0) &&
		!math.IsNaN(region.GetY()) && !math.IsInf(region.GetY(), 0) &&
		!math.IsNaN(region.GetWidth()) && !math.IsInf(region.GetWidth(), 0) &&
		!math.IsNaN(region.GetHeight()) && !math.IsInf(region.GetHeight(), 0)
}

func equalRegion(left, right *pbtype.Region) bool {
	if left == nil || right == nil {
		return left == right
	}
	const epsilon = 0.000_001
	return math.Abs(left.GetX()-right.GetX()) <= epsilon &&
		math.Abs(left.GetY()-right.GetY()) <= epsilon &&
		math.Abs(left.GetWidth()-right.GetWidth()) <= epsilon &&
		math.Abs(left.GetHeight()-right.GetHeight()) <= epsilon
}
