// Copyright 2026 Joseph Cumines

package server

import (
	"fmt"
	"math"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/rivo/uniseg"
	"google.golang.org/protobuf/proto"
)

const maxPublicInputEventCount = int64(1<<31 - 1)

func incompleteInputResult(
	input *pb.Input,
	request *pb.CreateInputRequest,
	operation string,
) *ToolResult {
	if input == nil {
		return errorResultf("%s failed: server returned no Input resource", operation)
	}
	if request == nil || request.GetInput() == nil || request.GetInputId() == "" {
		return errorResultf("%s failed: adapter lost its exact input request", operation)
	}
	wantName := request.GetParent() + "/inputs/" + request.GetInputId()
	if input.GetName() != wantName {
		return errorResultf(
			"%s failed: server returned Input name %q, want %q",
			operation,
			input.GetName(),
			wantName,
		)
	}
	if !proto.Equal(input.GetAction(), request.GetInput().GetAction()) {
		return errorResultf("%s failed: server changed the requested action", operation)
	}
	if !proto.Equal(input.GetTarget(), request.GetInput().GetTarget()) {
		return errorResultf("%s failed: server changed the requested target", operation)
	}
	if input.GetState() != pb.Input_STATE_COMPLETED {
		detail := input.GetError()
		if detail == "" {
			detail = fmt.Sprintf("server returned non-completed state %s", input.GetState())
		}
		return errorResultf("%s failed: %s", operation, detail)
	}
	if input.GetError() != "" {
		return errorResultf(
			"%s failed: completed Input has terminal error %q",
			operation,
			input.GetError(),
		)
	}
	if result := invalidInputTimestamps(input, operation); result != nil {
		return result
	}

	delivery := input.GetDeliveryResult()
	if delivery == nil {
		return errorResultf("%s failed: completed Input has no delivery receipt", operation)
	}
	if delivery.GetCommitment() != pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED {
		return errorResultf(
			"%s failed: delivery commitment is %s",
			operation,
			delivery.GetCommitment(),
		)
	}
	if delivery.GetPostedEventCount() < 0 {
		return errorResultf(
			"%s failed: delivery receipt has negative posted event count %d",
			operation,
			delivery.GetPostedEventCount(),
		)
	}
	wantPostedEvents, err := expectedInputPostedEventCount(request.GetInput().GetAction())
	if err != nil {
		return errorResultf("%s failed: adapter cannot verify requested event count: %v", operation, err)
	}
	if delivery.GetPostedEventCount() != wantPostedEvents {
		if delivery.GetPostedEventCount() == 0 {
			return errorResultf(
				"%s failed: delivery receipt has no posted events; want %d",
				operation,
				wantPostedEvents,
			)
		}
		return errorResultf(
			"%s failed: delivery receipt posted event count is %d, want %d",
			operation,
			delivery.GetPostedEventCount(),
			wantPostedEvents,
		)
	}
	if !delivery.GetRoutedDeliveryObserved() {
		return errorResultf("%s failed: routed delivery was not observed", operation)
	}
	return nil
}

func invalidInputTimestamps(input *pb.Input, operation string) *ToolResult {
	createTime := input.GetCreateTime()
	if createTime == nil {
		return errorResultf("%s failed: completed Input has no create_time", operation)
	}
	if err := createTime.CheckValid(); err != nil {
		return errorResultf("%s failed: completed Input has invalid create_time: %v", operation, err)
	}
	completeTime := input.GetCompleteTime()
	if completeTime == nil {
		return errorResultf("%s failed: completed Input has no complete_time", operation)
	}
	if err := completeTime.CheckValid(); err != nil {
		return errorResultf("%s failed: completed Input has invalid complete_time: %v", operation, err)
	}
	if completeTime.AsTime().Before(createTime.AsTime()) {
		return errorResultf("%s failed: complete_time precedes create_time", operation)
	}
	return nil
}

func expectedInputPostedEventCount(action *pb.InputAction) (int32, error) {
	if action == nil {
		return 0, fmt.Errorf("action is missing")
	}
	var count int64
	switch inputType := action.GetInputType().(type) {
	case *pb.InputAction_MouseClick:
		if inputType.MouseClick == nil {
			return 0, fmt.Errorf("click action is missing")
		}
		clickCount := int64(1)
		if inputType.MouseClick.ClickCount != nil {
			clickCount = int64(inputType.MouseClick.GetClickCount())
		}
		if clickCount < 1 {
			return 0, fmt.Errorf("click_count must be positive")
		}
		count = clickCount * 2
	case *pb.InputAction_TextInput:
		if inputType.TextInput == nil || inputType.TextInput.GetText() == "" {
			return 0, fmt.Errorf("text_input action is missing text")
		}
		count = int64(uniseg.GraphemeClusterCount(inputType.TextInput.GetText())) * 2
	case *pb.InputAction_KeyPress:
		if inputType.KeyPress == nil {
			return 0, fmt.Errorf("key_press action is missing")
		}
		count = 2
	case *pb.InputAction_MouseMove:
		if inputType.MouseMove == nil {
			return 0, fmt.Errorf("mouse_move action is missing")
		}
		duration := inputType.MouseMove.GetDuration()
		if !isFinite(duration) || duration < 0 {
			return 0, fmt.Errorf("move duration is invalid")
		}
		if duration == 0 {
			count = 1
		} else {
			count = 20
		}
	case *pb.InputAction_MouseDrag:
		if inputType.MouseDrag == nil {
			return 0, fmt.Errorf("drag action is missing")
		}
		switch pathCount := len(inputType.MouseDrag.GetWaypoints()); {
		case pathCount == 0:
			count = 3
		case pathCount >= 2:
			count = int64(pathCount) + 1
		default:
			return 0, fmt.Errorf("drag waypoints must contain at least two points")
		}
	case *pb.InputAction_ScrollAction:
		if inputType.ScrollAction == nil {
			return 0, fmt.Errorf("scroll action is missing")
		}
		scrollCount, err := expectedScrollPostedEventCount(inputType.ScrollAction)
		if err != nil {
			return 0, err
		}
		count = scrollCount
	case *pb.InputAction_HoverAction:
		if inputType.HoverAction == nil {
			return 0, fmt.Errorf("hover action is missing")
		}
		count = 1
	default:
		return 0, fmt.Errorf("action input_type is missing or unsupported")
	}
	if count < 1 || count > maxPublicInputEventCount {
		return 0, fmt.Errorf("event count %d is outside the public range", count)
	}
	return int32(count), nil
}

func expectedScrollPostedEventCount(scroll *pb.Scroll) (int64, error) {
	duration := scroll.GetDuration()
	if !isFinite(duration) || duration < 0 {
		return 0, fmt.Errorf("scroll duration is invalid")
	}
	horizontal, err := roundedPublicScrollMagnitude(scroll.GetHorizontal())
	if err != nil {
		return 0, fmt.Errorf("horizontal scroll delta: %w", err)
	}
	vertical, err := roundedPublicScrollMagnitude(scroll.GetVertical())
	if err != nil {
		return 0, fmt.Errorf("vertical scroll delta: %w", err)
	}
	maximumMagnitude := max(horizontal, vertical)
	if maximumMagnitude == 0 {
		return 0, fmt.Errorf("scroll delta must produce a physical event")
	}
	if duration == 0 {
		return 1, nil
	}
	return min(int64(20), maximumMagnitude), nil
}

func roundedPublicScrollMagnitude(value float64) (int64, error) {
	if !isFinite(value) {
		return 0, fmt.Errorf("must be finite")
	}
	rounded := math.Round(value)
	if rounded < math.MinInt32 || rounded > math.MaxInt32 {
		return 0, fmt.Errorf("is outside the supported range")
	}
	result := int64(rounded)
	if result < 0 {
		return -result, nil
	}
	return result, nil
}
