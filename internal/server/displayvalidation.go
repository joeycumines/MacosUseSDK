// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"fmt"
	"math"
	"strconv"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

const (
	displayCollectionPageSize = int32(1000)
	maximumDisplayPageCount   = 1024
)

type displayResponseValidationError struct {
	message string
}

func (e *displayResponseValidationError) Error() string {
	return e.message
}

func loadAndValidateDisplayTopology(
	ctx context.Context,
	client pb.ExactMacClient,
) ([]*pb.Display, error) {
	var displays []*pb.Display
	seenTokens := map[string]struct{}{"": {}}
	nextPageToken := ""

	for range maximumDisplayPageCount {
		response, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{
			PageSize:  displayCollectionPageSize,
			PageToken: nextPageToken,
		})
		if err != nil {
			return nil, err
		}
		if response == nil {
			return nil, invalidDisplayResponse("list response is nil")
		}
		displays = append(displays, response.Displays...)

		nextPageToken = response.NextPageToken
		if nextPageToken == "" {
			if err := validateDisplayTopology(displays); err != nil {
				return nil, err
			}
			return displays, nil
		}
		if _, exists := seenTokens[nextPageToken]; exists {
			return nil, invalidDisplayResponse("pagination token cycle")
		}
		seenTokens[nextPageToken] = struct{}{}
	}

	return nil, invalidDisplayResponse("pagination exceeded the bounded page limit")
}

func validateDisplayTopology(displays []*pb.Display) error {
	if len(displays) == 0 {
		return invalidDisplayResponse("topology is empty")
	}

	names := make(map[string]struct{}, len(displays))
	ids := make(map[int64]struct{}, len(displays))
	mainCount := 0
	for index, display := range displays {
		if display == nil {
			return invalidDisplayResponse("display %d is nil", index)
		}
		if display.DisplayId <= 0 || display.DisplayId > math.MaxUint32 {
			return invalidDisplayResponse(
				"display %d has an invalid CGDirectDisplayID",
				index,
			)
		}
		expectedName := "displays/" + strconv.FormatInt(display.DisplayId, 10)
		if display.Name != expectedName {
			return invalidDisplayResponse(
				"display %d name %q does not match id %d",
				index,
				display.Name,
				display.DisplayId,
			)
		}
		if _, exists := names[display.Name]; exists {
			return invalidDisplayResponse("display name %q is duplicated", display.Name)
		}
		if _, exists := ids[display.DisplayId]; exists {
			return invalidDisplayResponse("display id %d is duplicated", display.DisplayId)
		}
		names[display.Name] = struct{}{}
		ids[display.DisplayId] = struct{}{}

		if !validDisplayRegion(display.Frame) {
			return invalidDisplayResponse("display %q frame is missing or invalid", display.Name)
		}
		if !validDisplayRegion(display.VisibleFrame) {
			return invalidDisplayResponse(
				"display %q visible frame is missing or invalid",
				display.Name,
			)
		}
		if !screenshotRegionContains(display.Frame, display.VisibleFrame, 0.001) {
			return invalidDisplayResponse(
				"display %q visible frame is outside its frame",
				display.Name,
			)
		}
		if !isFinitePositiveScreenshot(display.Scale) {
			return invalidDisplayResponse(
				"display %q scale is not finite and positive",
				display.Name,
			)
		}
		if display.IsMain {
			mainCount++
		}
	}
	if mainCount != 1 {
		return invalidDisplayResponse(
			"topology has %d main displays; exactly one is required",
			mainCount,
		)
	}
	return nil
}

func validateCursorTopology(
	cursor *pb.CaptureCursorPositionResponse,
	displays []*pb.Display,
) error {
	if cursor == nil {
		return invalidDisplayResponse("cursor response is nil")
	}
	if !isFinite(cursor.X) || !isFinite(cursor.Y) {
		return invalidDisplayResponse("cursor coordinates are not finite")
	}
	if !isCanonicalDisplayResourceName(cursor.Display) {
		return invalidDisplayResponse("cursor display name is not canonical")
	}

	var containing []*pb.Display
	for _, display := range displays {
		if displayRegionContainsPointHalfOpen(display.Frame, cursor.X, cursor.Y) {
			containing = append(containing, display)
		}
	}
	if len(containing) != 1 || containing[0].Name != cursor.Display {
		return invalidDisplayResponse(
			"cursor does not belong to exactly one claimed active display",
		)
	}
	return nil
}

func validDisplayRegion(region *typepb.Region) bool {
	return validScreenshotRegion(region) &&
		isFinite(region.X+region.Width) &&
		isFinite(region.Y+region.Height)
}

func displayRegionContainsPointHalfOpen(
	region *typepb.Region,
	x float64,
	y float64,
) bool {
	return x >= region.X &&
		x < region.X+region.Width &&
		y >= region.Y &&
		y < region.Y+region.Height
}

func invalidDisplayResponse(format string, arguments ...any) error {
	return &displayResponseValidationError{
		message: fmt.Sprintf(format, arguments...),
	}
}
