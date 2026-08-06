// Copyright 2025 Joseph Cumines
//
// CUA physical-input tool handlers.

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// cuaKeyMap maps CUA-style key names to macOS key names accepted by the gRPC server.
var cuaKeyMap = map[string]string{
	// Modifiers
	"ctrl":  "control",
	"alt":   "option",
	"meta":  "command",
	"shift": "shift",
	"fn":    "function",
	// Special keys
	"enter":     "return",
	"return":    "return",
	"esc":       "escape",
	"escape":    "escape",
	"backspace": "delete",
	"delete":    "delete",
	"space":     "space",
	"tab":       "tab",
	// Arrow keys
	"arrowup":    "up",
	"up":         "up",
	"arrowdown":  "down",
	"down":       "down",
	"arrowleft":  "left",
	"left":       "left",
	"arrowright": "right",
	"right":      "right",
	// Function keys
	"f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4",
	"f5": "f5", "f6": "f6", "f7": "f7", "f8": "f8",
	"f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12",
}

func cuaPointerModifiers(keys []string) ([]pb.KeyPress_Modifier, *ToolResult) {
	modifiers, err := parseCUAModifiers(keys)
	if err != nil {
		return nil, errorResult(err.Error())
	}
	return modifiers, nil
}

// inputName safely returns the input name string from a *pb.Input,
// returning a placeholder when the input is nil or has an empty name.
func inputName(r *pb.Input) string {
	if r == nil {
		return "(modifier-composite)"
	}
	name := r.GetName()
	if name == "" {
		return "(unknown)"
	}
	return name
}

// buttonDisplayName returns a human-readable button name.
func buttonDisplayName(clickType pb.MouseClick_ClickType) string {
	switch clickType {
	case pb.MouseClick_CLICK_TYPE_RIGHT:
		return "right"
	case pb.MouseClick_CLICK_TYPE_MIDDLE:
		return "middle"
	default:
		return "left"
	}
}

// handleClick handles the click tool — click at screen coordinates with optional
// modifier keys held during the click.
func (s *MCPServer) cuaHandleClick(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target     string   `json:"target"`
		X          *float64 `json:"x"`
		Y          *float64 `json:"y"`
		Button     *string  `json:"button"`
		ClickCount *int32   `json:"click_count"`
		Keys       []string `json:"keys"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.X == nil || params.Y == nil {
		return errorResult("x and y parameters are required"), nil
	}
	if math.IsNaN(*params.X) || math.IsInf(*params.X, 0) || math.IsNaN(*params.Y) || math.IsInf(*params.Y, 0) {
		return errorResult("coordinates must be finite numbers"), nil
	}

	clickType, parseError := parseCUAButton(params.Button)
	if parseError != nil {
		return errorResult(parseError.Error()), nil
	}
	clickCount, parseError := parseCUAClickCount(params.ClickCount)
	if parseError != nil {
		return errorResult(parseError.Error()), nil
	}

	modifiers, modifierError := cuaPointerModifiers(params.Keys)
	if modifierError != nil {
		return modifierError, nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(s.cfg, 0)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	request, err := buildCUAInputRequest(params.Target, &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Click{
				Click: &pb.MouseClick{
					Position:   &typepb.Point{X: *params.X, Y: *params.Y},
					ClickType:  &clickType,
					ClickCount: &clickCount,
					Modifiers:  modifiers,
				},
			},
		},
	})
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "click"), nil
	}
	if result := incompleteInputResult(resp, request, "click"); result != nil {
		return result, nil
	}

	clickWord := "single"
	switch clickCount {
	case 2:
		clickWord = "double"
	case 3:
		clickWord = "triple"
	default:
		if clickCount > 3 {
			clickWord = fmt.Sprintf("%d-tuple", clickCount)
		}
	}

	return textResultf(
		"%s %s-click at (%s, %s) - Input: %s",
		clickWord,
		buttonDisplayName(clickType),
		formatCUANumber(*params.X),
		formatCUANumber(*params.Y),
		inputName(resp),
	), nil
}

// handleDoubleClick handles the double_click tool.
func (s *MCPServer) handleDoubleClick(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target string   `json:"target"`
		X      *float64 `json:"x"`
		Y      *float64 `json:"y"`
		Button *string  `json:"button"`
		Keys   []string `json:"keys"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.X == nil || params.Y == nil {
		return errorResult("x and y parameters are required"), nil
	}
	if math.IsNaN(*params.X) || math.IsInf(*params.X, 0) || math.IsNaN(*params.Y) || math.IsInf(*params.Y, 0) {
		return errorResult("coordinates must be finite numbers"), nil
	}

	clickType, parseError := parseCUAButton(params.Button)
	if parseError != nil {
		return errorResult(parseError.Error()), nil
	}
	clickCount := int32(2)

	modifiers, modifierError := cuaPointerModifiers(params.Keys)
	if modifierError != nil {
		return modifierError, nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(s.cfg, 0)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	request, err := buildCUAInputRequest(params.Target, &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Click{
				Click: &pb.MouseClick{
					Position:   &typepb.Point{X: *params.X, Y: *params.Y},
					ClickType:  &clickType,
					ClickCount: &clickCount,
					Modifiers:  modifiers,
				},
			},
		},
	})
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "double_click"), nil
	}
	if result := incompleteInputResult(resp, request, "double_click"); result != nil {
		return result, nil
	}

	return textResultf(
		"double %s-click at (%s, %s) - Input: %s",
		buttonDisplayName(clickType),
		formatCUANumber(*params.X),
		formatCUANumber(*params.Y),
		inputName(resp),
	), nil
}

// handleType handles the type tool — type text as keyboard input.
func (s *MCPServer) handleType(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Text      string  `json:"text"`
		CharDelay float64 `json:"char_delay"`
		Target    string  `json:"target"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Text == "" {
		return errorResult("text parameter is required"), nil
	}
	if !isFinite(params.CharDelay) || params.CharDelay < 0 || params.CharDelay > 60 {
		return errorResult("char_delay must be finite and between 0 and 60 seconds"), nil
	}

	if errResult := validateInputLen(params.Text, maxInputTextLen, "text"); errResult != nil {
		return errResult, nil
	}
	requestTimeout, scheduleErr := validatePhysicalTypeSchedule(
		s.cfg,
		params.Text,
		params.CharDelay,
	)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_TypeText{
				TypeText: &pb.TextInput{
					Text:      params.Text,
					CharDelay: params.CharDelay,
				},
			},
		},
	}

	request, err := buildCUAKeyboardInputRequest(params.Target, input)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "type"), nil
	}

	if result := incompleteInputResult(resp, request, "type"); result != nil {
		return result, nil
	}

	displayText := truncateText(params.Text)
	return textResultf(
		"Typed %d characters: \"%s\" - Input: %s",
		utf8.RuneCountInString(params.Text),
		displayText,
		resp.Name,
	), nil
}

// handleKeypress handles the keypress tool — press one primary key with
// optional modifier keys.
func (s *MCPServer) handleKeypress(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target       string   `json:"target"`
		Keys         []string `json:"keys"`
		HoldDuration float64  `json:"hold_duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if len(params.Keys) == 0 {
		return errorResult("keys parameter is required and must be non-empty"), nil
	}
	if !isFinite(params.HoldDuration) || params.HoldDuration < 0 || params.HoldDuration > 3600 {
		return errorResult("hold_duration must be finite and between 0 and 3600 seconds"), nil
	}

	primaryKey, modifierEnums, parseError := parseCUAKeyChord(params.Keys)
	if parseError != nil {
		return errorResult(parseError.Error()), nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(
		s.cfg,
		params.HoldDuration,
	)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_PressKey{
				PressKey: &pb.KeyPress{
					Key:          primaryKey,
					Modifiers:    modifierEnums,
					HoldDuration: params.HoldDuration,
				},
			},
		},
	}

	request, err := buildCUAKeyboardInputRequest(params.Target, input)
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "keypress"), nil
	}
	if result := incompleteInputResult(resp, request, "keypress"); result != nil {
		return result, nil
	}

	// Build display string
	var keyCombo strings.Builder
	for _, k := range params.Keys[:len(params.Keys)-1] {
		keyCombo.WriteString(k)
		keyCombo.WriteString("+")
	}
	keyCombo.WriteString(params.Keys[len(params.Keys)-1])

	return textResultf("Pressed key: %s - Input: %s", keyCombo.String(), resp.Name), nil
}

// handleScroll handles the scroll tool — scroll at a position by delta amounts.
// Uses CUA-style scroll_x/scroll_y instead of old horizontal/vertical.
func (s *MCPServer) cuaHandleScroll(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target   string   `json:"target"`
		X        float64  `json:"x"`
		Y        float64  `json:"y"`
		ScrollX  float64  `json:"scroll_x"`
		ScrollY  float64  `json:"scroll_y"`
		Keys     []string `json:"keys"`
		Duration float64  `json:"duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if math.IsNaN(params.X) || math.IsInf(params.X, 0) || math.IsNaN(params.Y) || math.IsInf(params.Y, 0) {
		return errorResult("coordinates must be finite numbers"), nil
	}
	if math.IsNaN(params.ScrollX) || math.IsInf(params.ScrollX, 0) || math.IsNaN(params.ScrollY) || math.IsInf(params.ScrollY, 0) {
		return errorResult("scroll deltas must be finite numbers"), nil
	}
	if !isFinite(params.Duration) || params.Duration < 0 || params.Duration > 60 {
		return errorResult("duration must be finite and between 0 and 60 seconds"), nil
	}

	modifiers, modifierError := cuaPointerModifiers(params.Keys)
	if modifierError != nil {
		return modifierError, nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(
		s.cfg,
		params.Duration,
	)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	scroll := &pb.Scroll{
		Position:   &typepb.Point{X: params.X, Y: params.Y},
		Horizontal: params.ScrollX,
		Vertical:   -params.ScrollY,
		Duration:   params.Duration,
		Modifiers:  modifiers,
	}

	request, err := buildCUAInputRequest(params.Target, &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Scroll{Scroll: scroll},
		},
	})
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "scroll"), nil
	}
	if result := incompleteInputResult(resp, request, "scroll"); result != nil {
		return result, nil
	}

	direction := ""
	if params.ScrollY > 0 {
		direction = "down"
	} else if params.ScrollY < 0 {
		direction = "up"
	}
	if params.ScrollX > 0 {
		if direction != "" {
			direction += " and "
		}
		direction += "right"
	} else if params.ScrollX < 0 {
		if direction != "" {
			direction += " and "
		}
		direction += "left"
	}
	if direction == "" {
		direction = "no movement"
	}

	return textResultf(
		"Scrolled %s (scroll_x:%s, scroll_y:%s) at (%s, %s) - Input: %s",
		direction,
		formatCUANumber(params.ScrollX),
		formatCUANumber(params.ScrollY),
		formatCUANumber(params.X),
		formatCUANumber(params.Y),
		inputName(resp),
	), nil
}

// handleDrag handles the drag tool — click-and-drag along a sequence of waypoints.
// Uses CUA-style path[] instead of old start_x/start_y/end_x/end_y.
func (s *MCPServer) cuaHandleDrag(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target string `json:"target"`
		Path   []struct {
			X float64 `json:"x"`
			Y float64 `json:"y"`
		} `json:"path"`
		Button   *string  `json:"button"`
		Keys     []string `json:"keys"`
		Duration float64  `json:"duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if len(params.Path) < 2 {
		return errorResult("path must contain at least 2 waypoints"), nil
	}
	for i, p := range params.Path {
		if math.IsNaN(p.X) || math.IsInf(p.X, 0) || math.IsNaN(p.Y) || math.IsInf(p.Y, 0) {
			return errorResultf("path[%d] coordinates must be finite numbers", i), nil
		}
	}
	if !isFinite(params.Duration) || params.Duration < 0 || params.Duration > 60 {
		return errorResult("duration must be finite and between 0 and 60 seconds"), nil
	}

	clickType, parseError := parseCUAButton(params.Button)
	if parseError != nil {
		return errorResult(parseError.Error()), nil
	}

	modifiers, modifierError := cuaPointerModifiers(params.Keys)
	if modifierError != nil {
		return modifierError, nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(
		s.cfg,
		params.Duration,
	)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	start := params.Path[0]
	end := params.Path[len(params.Path)-1]
	path := make([]*typepb.Point, len(params.Path))
	for index, point := range params.Path {
		path[index] = &typepb.Point{X: point.X, Y: point.Y}
	}

	drag := &pb.MouseDrag{
		StartPosition: &typepb.Point{X: start.X, Y: start.Y},
		EndPosition:   &typepb.Point{X: end.X, Y: end.Y},
		Duration:      params.Duration,
		Button:        &clickType,
		Modifiers:     modifiers,
		Path:          path,
	}

	request, err := buildCUAInputRequest(params.Target, &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Drag{Drag: drag},
		},
	})
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "drag"), nil
	}
	if result := incompleteInputResult(resp, request, "drag"); result != nil {
		return result, nil
	}

	return textResultf(
		"Dragged from (%s, %s) to (%s, %s) using %d waypoint(s) - Input: %s",
		formatCUANumber(start.X),
		formatCUANumber(start.Y),
		formatCUANumber(end.X),
		formatCUANumber(end.Y),
		len(params.Path),
		inputName(resp),
	), nil
}

// handleMove handles the move tool — move mouse cursor without clicking.
func (s *MCPServer) handleMove(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Target   string   `json:"target"`
		X        *float64 `json:"x"`
		Y        *float64 `json:"y"`
		Keys     []string `json:"keys"`
		Duration float64  `json:"duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.X == nil || params.Y == nil {
		return errorResult("x and y parameters are required"), nil
	}
	if math.IsNaN(*params.X) || math.IsInf(*params.X, 0) || math.IsNaN(*params.Y) || math.IsInf(*params.Y, 0) {
		return errorResult("coordinates must be finite numbers"), nil
	}
	if !isFinite(params.Duration) || params.Duration < 0 || params.Duration > 60 {
		return errorResult("duration must be finite and between 0 and 60 seconds"), nil
	}

	modifiers, modifierError := cuaPointerModifiers(params.Keys)
	if modifierError != nil {
		return modifierError, nil
	}
	requestTimeout, scheduleErr := validatePhysicalInputDuration(
		s.cfg,
		params.Duration,
	)
	if scheduleErr != nil {
		return errorResult(scheduleErr.Error()), nil
	}

	move := &pb.MouseMove{
		Position:  &typepb.Point{X: *params.X, Y: *params.Y},
		Duration:  params.Duration,
		Modifiers: modifiers,
	}

	request, err := buildCUAInputRequest(params.Target, &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_MoveMouse{MoveMouse: move},
		},
	})
	if err != nil {
		return errorResult(err.Error()), nil
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), requestTimeout)
	defer cancel()
	resp, err := s.client.CreateInput(ctx, request)
	if err != nil {
		return grpcErrorResult(err, "move"), nil
	}
	if result := incompleteInputResult(resp, request, "move"); result != nil {
		return result, nil
	}

	return textResultf(
		"Moved mouse to (%s, %s) - Input: %s",
		formatCUANumber(*params.X),
		formatCUANumber(*params.Y),
		inputName(resp),
	), nil
}

func formatCUANumber(value float64) string {
	return strconv.FormatFloat(value, 'g', -1, 64)
}
