package integration

import (
	"bytes"
	"context"
	"fmt"
	"image/png"
	"math"
	"strconv"
	"testing"
	"time"

	pbtype "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

func TestWindowScreenshot_OwnedFinderExactTruth(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewExactMacClient(conn)

	finder := requireRunningApplicationByBundleID(t, ctx, client, "com.apple.finder")
	owned, cleanupOwned := createOwnedFinderWindow(t, ctx, client, finder)
	defer cleanupOwned()
	window := requireStableOwnedFinderWindow(t, ctx, client, finder.Name, owned.title)

	displays, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	mainDisplay := requireMainDisplay(t, displays.GetDisplays())
	if !regionContainsBounds(mainDisplay.GetFrame(), window.GetBounds(), 0.001) {
		t.Fatalf(
			"owned Finder window is not wholly on the main display: display=%+v window=%+v",
			mainDisplay.GetFrame(),
			window.GetBounds(),
		)
	}

	requests := []struct {
		name          string
		includeShadow bool
		includeOCR    bool
	}{
		{name: "without_shadow_or_ocr"},
		{name: "with_shadow_and_ocr", includeShadow: true, includeOCR: true},
	}
	for _, testCase := range requests {
		t.Run(testCase.name, func(t *testing.T) {
			response, err := client.CaptureWindowScreenshot(ctx, &pb.CaptureWindowScreenshotRequest{
				Window:         window.GetName(),
				Format:         pb.ImageFormat_IMAGE_FORMAT_PNG,
				IncludeShadow:  testCase.includeShadow,
				IncludeOcrText: testCase.includeOCR,
			})
			if err != nil {
				t.Fatalf("CaptureWindowScreenshot failed: %v", err)
			}
			assertOwnedFinderWindowCapture(
				t,
				response,
				window,
				mainDisplay,
				testCase.includeShadow,
				testCase.includeOCR,
			)
		})
	}

	closed, err := client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: window.GetName()})
	if err != nil {
		listResponse, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: finder.GetName()})
		exactNamePresent := false
		exactTitlePresent := false
		if listErr == nil {
			for _, candidate := range listResponse.GetWindows() {
				exactNamePresent = exactNamePresent || candidate.GetName() == window.GetName()
				exactTitlePresent = exactTitlePresent || candidate.GetTitle() == owned.title
			}
		}
		t.Fatalf(
			"CloseWindow(%q) failed: %v; post-failure ListWindows error=%v exact_name_present=%t exact_title_present=%t",
			window.GetName(),
			err,
			listErr,
			exactNamePresent,
			exactTitlePresent,
		)
	}
	if !closed.GetSuccess() {
		t.Fatalf("CloseWindow(%q) returned success=false", window.GetName())
	}

	// Prove the owned window is genuinely gone via AX-authoritative truth.
	// Listing-only checks over-report presence because CGWindowList can retain a
	// stale ghost entry (same title, regenerated name) after CloseWindow returns
	// success — the AX tree has already confirmed absence, but CG lags.
	// GetWindow is AX-backed, so waitForOwnedWindowsAbsent ignores CG ghosts that
	// have no live AX window and proves the owned fixture is really closed.
	closeCtx, cancelClose := context.WithTimeout(ctx, 10*time.Second)
	defer cancelClose()
	err = waitForOwnedWindowsAbsent(closeCtx, client, finder.GetName(), owned.title)
	if err != nil {
		t.Fatalf("owned Finder window remained after exact CloseWindow: %v", err)
	}
}

func requireRunningApplicationByBundleID(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	bundleID string,
) *pb.Application {
	t.Helper()
	response, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize: 100,
		OrderBy:  "name",
		Filter:   fmt.Sprintf("bundle_id = %s", strconv.Quote(bundleID)),
	})
	if err != nil {
		t.Fatalf("ListApplications(%q) failed: %v", bundleID, err)
	}
	var matches []*pb.Application
	for _, application := range response.GetApplications() {
		if application.GetBundleId() == bundleID {
			matches = append(matches, application)
		}
	}
	if len(matches) != 1 {
		t.Fatalf("ListApplications(%q) returned %d exact running processes", bundleID, len(matches))
	}
	application := matches[0]
	if !isOpaqueApplicationResourceName(application.GetName()) || application.GetPid() <= 1 {
		t.Fatalf("ListApplications(%q) returned invalid identity: %+v", bundleID, application)
	}
	return application
}

func requireStableOwnedFinderWindow(
	t *testing.T,
	ctx context.Context,
	client pb.ExactMacClient,
	parent string,
	title string,
) *pb.Window {
	t.Helper()
	stableCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	var previous *pb.Window
	var stable *pb.Window
	err := PollUntilContext(stableCtx, 100*time.Millisecond, func() (bool, error) {
		response, listErr := client.ListWindows(stableCtx, &pb.ListWindowsRequest{Parent: parent})
		if listErr != nil {
			return false, nil
		}
		var current *pb.Window
		for _, candidate := range response.GetWindows() {
			if candidate.GetTitle() == title {
				current = candidate
				break
			}
		}
		if current == nil || !finiteBounds(current.GetBounds()) {
			previous = nil
			return false, nil
		}
		if previous != nil &&
			previous.GetName() == current.GetName() &&
			equalBounds(previous.GetBounds(), current.GetBounds(), 0.001) {
			stable = current
			return true, nil
		}
		previous = current
		return false, nil
	})
	if err != nil {
		t.Fatalf("owned Finder window %q did not reach stable identity and bounds: %v", title, err)
	}
	return stable
}

func assertOwnedFinderWindowCapture(
	t *testing.T,
	response *pb.CaptureWindowScreenshotResponse,
	window *pb.Window,
	display *pb.Display,
	includeShadow bool,
	includeOCR bool,
) {
	t.Helper()
	if response == nil {
		t.Fatal("CaptureWindowScreenshot returned nil")
	}
	if response.GetWindow() != window.GetName() {
		t.Fatalf("captured window = %q, want %q", response.GetWindow(), window.GetName())
	}
	if response.GetFormat() != pb.ImageFormat_IMAGE_FORMAT_PNG {
		t.Fatalf("capture format = %v, want PNG", response.GetFormat())
	}
	decoded, err := png.Decode(bytes.NewReader(response.GetImageData()))
	if err != nil {
		t.Fatalf("capture is not valid PNG: %v", err)
	}
	decodedBounds := decoded.Bounds()
	if int32(decodedBounds.Dx()) != response.GetWidth() || int32(decodedBounds.Dy()) != response.GetHeight() {
		t.Fatalf(
			"decoded image dimensions %dx%d disagree with response %dx%d",
			decodedBounds.Dx(),
			decodedBounds.Dy(),
			response.GetWidth(),
			response.GetHeight(),
		)
	}

	windowFrame := response.GetWindowFrame()
	region := response.GetRegion()
	if !finitePositiveRegion(windowFrame) || !finitePositiveRegion(region) {
		t.Fatalf("capture returned invalid Global Display Coordinates: window=%+v region=%+v", windowFrame, region)
	}
	if !regionEqualsBounds(windowFrame, window.GetBounds(), 0.001) {
		t.Fatalf("captured frame changed exact listed bounds: got=%+v want=%+v", windowFrame, window.GetBounds())
	}
	if !regionContainsRegion(region, windowFrame, 0.001) || response.GetClipped() {
		t.Fatalf("capture clipped the source window: region=%+v frame=%+v clipped=%v", region, windowFrame, response.GetClipped())
	}
	if response.GetShadowIncluded() != includeShadow {
		t.Fatalf("shadow_included = %v, want %v", response.GetShadowIncluded(), includeShadow)
	}
	scale := response.GetScale()
	if math.IsNaN(scale) || math.IsInf(scale, 0) || scale <= 0 || math.Abs(scale-display.GetScale()) > 0.001 {
		t.Fatalf("capture scale = %v, main display scale = %v", scale, display.GetScale())
	}
	if math.Abs(float64(response.GetWidth())-region.GetWidth()*scale) >= 1 ||
		math.Abs(float64(response.GetHeight())-region.GetHeight()*scale) >= 1 {
		t.Fatalf(
			"capture pixel geometry is inconsistent: pixels=%dx%d region=%+v scale=%v",
			response.GetWidth(),
			response.GetHeight(),
			region,
			scale,
		)
	}

	if !includeOCR {
		if response.GetOcrResult() != nil {
			t.Fatalf("OCR result was set when extraction was not requested: %T", response.GetOcrResult())
		}
		return
	}
	switch result := response.GetOcrResult().(type) {
	case *pb.CaptureWindowScreenshotResponse_OcrText:
		if result == nil {
			t.Fatal("OCR text outcome is nil")
		}
	case *pb.CaptureWindowScreenshotResponse_OcrError:
		status := result.OcrError
		if status == nil || status.GetCode() < 1 || status.GetCode() > 16 || status.GetMessage() == "" {
			t.Fatalf("OCR error outcome is not canonical: %+v", status)
		}
	default:
		t.Fatalf("OCR was requested but no explicit outcome was returned: %T", result)
	}
}

func finiteBounds(bounds *pb.Bounds) bool {
	return bounds != nil &&
		!math.IsNaN(bounds.GetX()) && !math.IsInf(bounds.GetX(), 0) &&
		!math.IsNaN(bounds.GetY()) && !math.IsInf(bounds.GetY(), 0) &&
		!math.IsNaN(bounds.GetWidth()) && !math.IsInf(bounds.GetWidth(), 0) && bounds.GetWidth() > 0 &&
		!math.IsNaN(bounds.GetHeight()) && !math.IsInf(bounds.GetHeight(), 0) && bounds.GetHeight() > 0
}

func finitePositiveRegion(region *pbtype.Region) bool {
	return finiteRegion(region) && region.GetWidth() > 0 && region.GetHeight() > 0
}

func equalBounds(left, right *pb.Bounds, tolerance float64) bool {
	return left != nil && right != nil &&
		math.Abs(left.GetX()-right.GetX()) <= tolerance &&
		math.Abs(left.GetY()-right.GetY()) <= tolerance &&
		math.Abs(left.GetWidth()-right.GetWidth()) <= tolerance &&
		math.Abs(left.GetHeight()-right.GetHeight()) <= tolerance
}

func regionEqualsBounds(region *pbtype.Region, bounds *pb.Bounds, tolerance float64) bool {
	return region != nil && bounds != nil &&
		math.Abs(region.GetX()-bounds.GetX()) <= tolerance &&
		math.Abs(region.GetY()-bounds.GetY()) <= tolerance &&
		math.Abs(region.GetWidth()-bounds.GetWidth()) <= tolerance &&
		math.Abs(region.GetHeight()-bounds.GetHeight()) <= tolerance
}

func regionContainsBounds(region *pbtype.Region, bounds *pb.Bounds, tolerance float64) bool {
	return region != nil && bounds != nil &&
		bounds.GetX() >= region.GetX()-tolerance &&
		bounds.GetY() >= region.GetY()-tolerance &&
		bounds.GetX()+bounds.GetWidth() <= region.GetX()+region.GetWidth()+tolerance &&
		bounds.GetY()+bounds.GetHeight() <= region.GetY()+region.GetHeight()+tolerance
}

func regionContainsRegion(outer, inner *pbtype.Region, tolerance float64) bool {
	return outer != nil && inner != nil &&
		inner.GetX() >= outer.GetX()-tolerance &&
		inner.GetY() >= outer.GetY()-tolerance &&
		inner.GetX()+inner.GetWidth() <= outer.GetX()+outer.GetWidth()+tolerance &&
		inner.GetY()+inner.GetHeight() <= outer.GetY()+outer.GetHeight()+tolerance
}
