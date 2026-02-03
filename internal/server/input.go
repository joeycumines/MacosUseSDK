// Copyright 2025 Joseph Cumines
//
// Input tool handlers for Computer Use actions

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// defaultApplicationParent is the parent pattern for inputs targeting any/active application
const defaultApplicationParent = "applications/-"

// handleClick handles the click tool for coordinate-based clicking.
//
// Coordinates use Global Display Coordinates (top-left origin):
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
//   - Secondary displays may have negative X (left of main) or Y (above main)
//   - No bounds checking is performed; out-of-bounds clicks may be ignored by macOS
func (s *MCPServer) handleClick(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// X coordinate in Global Display Coordinates (top-left origin)
		X float64 `json:"x"`
		// Y coordinate in Global Display Coordinates (top-left origin)
		Y float64 `json:"y"`
		// Click type: left, right, middle. Default: left
		Button string `json:"button"`
		// Number of clicks: 1=single, 2=double, 3=triple. Default: 1
		ClickCount int32 `json:"click_count"`
		// Whether to show visual feedback animation
		ShowAnimation bool `json:"show_animation"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	// Map button string to proto enum
	clickType := pb.MouseClick_CLICK_TYPE_LEFT
	switch strings.ToLower(params.Button) {
	case "right":
		clickType = pb.MouseClick_CLICK_TYPE_RIGHT
	case "middle":
		clickType = pb.MouseClick_CLICK_TYPE_MIDDLE
	}

	clickCount := params.ClickCount
	if clickCount <= 0 {
		clickCount = 1
	}

	// Determine parent for input
	parent := params.Application
	if parent == "" {
		// Use a default parent pattern if no application specified
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			ShowAnimation: params.ShowAnimation,
			InputType: &pb.InputAction_Click{
				Click: &pb.MouseClick{
					Position: &typepb.Point{
						X: params.X,
						Y: params.Y,
					},
					ClickType:  clickType,
					ClickCount: clickCount,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to execute click: %v", err)}},
		}, nil
	}

	result := "single"
	if clickCount == 2 {
		result = "double"
	} else if clickCount >= 3 {
		result = "triple"
	}

	buttonName := "left"
	switch clickType {
	case pb.MouseClick_CLICK_TYPE_RIGHT:
		buttonName = "right"
	case pb.MouseClick_CLICK_TYPE_MIDDLE:
		buttonName = "middle"
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Executed %s %s-click at (%.0f, %.0f) - Input: %s", result, buttonName, params.X, params.Y, resp.Name),
		}},
	}, nil
}

// handleTypeText handles the type_text tool for keyboard text injection
func (s *MCPServer) handleTypeText(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Text to type
		Text string `json:"text"`
		// Delay between characters in seconds (for human-like typing)
		CharDelay float64 `json:"char_delay"`
		// Whether to use IME for non-ASCII input
		UseIME bool `json:"use_ime"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Text == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "text parameter is required"}},
		}, nil
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_TypeText{
				TypeText: &pb.TextInput{
					Text:      params.Text,
					UseIme:    params.UseIME,
					CharDelay: params.CharDelay,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to type text: %v", err)}},
		}, nil
	}

	// Truncate displayed text if too long
	displayText := params.Text
	if len(displayText) > 50 {
		displayText = displayText[:47] + "..."
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Typed %d characters: \"%s\" - Input: %s", len(params.Text), displayText, resp.Name),
		}},
	}, nil
}

// handlePressKey handles the press_key tool for keyboard shortcuts and key presses
func (s *MCPServer) handlePressKey(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Key to press (e.g., "return", "escape", "a", "f1")
		Key string `json:"key"`
		// Modifier keys: command, option, control, shift, function
		Modifiers []string `json:"modifiers"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Key == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "key parameter is required"}},
		}, nil
	}

	// Map modifier strings to proto enums
	var modifiers []pb.KeyPress_Modifier
	for _, mod := range params.Modifiers {
		switch strings.ToLower(mod) {
		case "command", "cmd":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_COMMAND)
		case "option", "alt":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_OPTION)
		case "control", "ctrl":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_CONTROL)
		case "shift":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_SHIFT)
		case "function", "fn":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_FUNCTION)
		case "capslock":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_CAPS_LOCK)
		}
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_PressKey{
				PressKey: &pb.KeyPress{
					Key:       params.Key,
					Modifiers: modifiers,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to press key: %v", err)}},
		}, nil
	}

	// Build key combo string for display
	keyCombo := ""
	for _, mod := range params.Modifiers {
		// Capitalize first letter
		if len(mod) > 0 {
			keyCombo += strings.ToUpper(mod[:1]) + strings.ToLower(mod[1:]) + "+"
		}
	}
	keyCombo += params.Key

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Pressed key: %s - Input: %s", keyCombo, resp.Name),
		}},
	}, nil
}

// handleMouseMove handles the mouse_move tool for cursor positioning.
//
// Coordinates use Global Display Coordinates (top-left origin):
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
//   - Secondary displays may have negative X (left of main) or Y (above main)
//   - No bounds checking is performed; out-of-bounds moves may result in cursor at screen edge
func (s *MCPServer) handleMouseMove(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// X coordinate in Global Display Coordinates (top-left origin)
		X float64 `json:"x"`
		// Y coordinate in Global Display Coordinates (top-left origin)
		Y float64 `json:"y"`
		// Duration for smooth animation (seconds)
		Duration float64 `json:"duration"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_MoveMouse{
				MoveMouse: &pb.MouseMove{
					Position: &typepb.Point{
						X: params.X,
						Y: params.Y,
					},
					Duration: params.Duration,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to move mouse: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Moved mouse to (%.0f, %.0f) - Input: %s", params.X, params.Y, resp.Name),
		}},
	}, nil
}

// handleScroll handles the scroll tool for scrolling content.
//
// Coordinates use Global Display Coordinates (top-left origin) when specified.
// If X/Y are not provided, scroll occurs at the current mouse position.
func (s *MCPServer) handleScroll(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Scroll position X (optional, uses current mouse position if not set)
		X *float64 `json:"x"`
		// Scroll position Y (optional, uses current mouse position if not set)
		Y *float64 `json:"y"`
		// Horizontal scroll amount (positive = right, negative = left)
		Horizontal float64 `json:"horizontal"`
		// Vertical scroll amount (positive = up, negative = down)
		Vertical float64 `json:"vertical"`
		// Duration for momentum effect
		Duration float64 `json:"duration"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	scroll := &pb.Scroll{
		Horizontal: params.Horizontal,
		Vertical:   params.Vertical,
		Duration:   params.Duration,
	}

	// Set position if provided
	if params.X != nil && params.Y != nil {
		scroll.Position = &typepb.Point{
			X: *params.X,
			Y: *params.Y,
		}
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Scroll{
				Scroll: scroll,
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to scroll: %v", err)}},
		}, nil
	}

	direction := ""
	if params.Vertical > 0 {
		direction = "up"
	} else if params.Vertical < 0 {
		direction = "down"
	}
	if params.Horizontal > 0 {
		if direction != "" {
			direction += " and "
		}
		direction += "right"
	} else if params.Horizontal < 0 {
		if direction != "" {
			direction += " and "
		}
		direction += "left"
	}
	if direction == "" {
		direction = "no movement"
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Scrolled %s (h:%.0f, v:%.0f) - Input: %s", direction, params.Horizontal, params.Vertical, resp.Name),
		}},
	}, nil
}

// handleDrag handles the drag tool for drag-and-drop operations.
//
// Coordinates use Global Display Coordinates (top-left origin):
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
//   - Secondary displays may have negative X (left of main) or Y (above main)
func (s *MCPServer) handleDrag(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// StartX coordinate in Global Display Coordinates (top-left origin)
		StartX float64 `json:"start_x"`
		// StartY coordinate in Global Display Coordinates (top-left origin)
		StartY float64 `json:"start_y"`
		// EndX coordinate in Global Display Coordinates (top-left origin)
		EndX float64 `json:"end_x"`
		// EndY coordinate in Global Display Coordinates (top-left origin)
		EndY float64 `json:"end_y"`
		// Duration of drag in seconds
		Duration float64 `json:"duration"`
		// Mouse button to use: left, right, middle. Default: left
		Button string `json:"button"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	button := pb.MouseClick_CLICK_TYPE_LEFT
	switch strings.ToLower(params.Button) {
	case "right":
		button = pb.MouseClick_CLICK_TYPE_RIGHT
	case "middle":
		button = pb.MouseClick_CLICK_TYPE_MIDDLE
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Drag{
				Drag: &pb.MouseDrag{
					StartPosition: &typepb.Point{
						X: params.StartX,
						Y: params.StartY,
					},
					EndPosition: &typepb.Point{
						X: params.EndX,
						Y: params.EndY,
					},
					Duration: params.Duration,
					Button:   button,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to drag: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Dragged from (%.0f, %.0f) to (%.0f, %.0f) - Input: %s", params.StartX, params.StartY, params.EndX, params.EndY, resp.Name),
		}},
	}, nil
}

// handleHover handles the hover tool for holding mouse position for a duration.
//
// Coordinates use Global Display Coordinates (top-left origin):
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
//   - Secondary displays may have negative X (left of main) or Y (above main)
func (s *MCPServer) handleHover(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// X coordinate in Global Display Coordinates (top-left origin)
		X float64 `json:"x"`
		// Y coordinate in Global Display Coordinates (top-left origin)
		Y float64 `json:"y"`
		// Duration to hover in seconds
		Duration float64 `json:"duration"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Duration <= 0 {
		params.Duration = 1.0 // Default 1 second hover
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Hover{
				Hover: &pb.Hover{
					Position: &typepb.Point{
						X: params.X,
						Y: params.Y,
					},
					Duration: params.Duration,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to hover: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Hovered at (%.0f, %.0f) for %.1fs - Input: %s", params.X, params.Y, params.Duration, resp.Name),
		}},
	}, nil
}

// handleGesture handles multi-touch gesture actions.
//
// Coordinates use Global Display Coordinates (top-left origin):
//   - CenterX/CenterY specify the gesture center point
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
func (s *MCPServer) handleGesture(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Center X coordinate in Global Display Coordinates (top-left origin)
		CenterX float64 `json:"center_x"`
		// Center Y coordinate in Global Display Coordinates (top-left origin)
		CenterY float64 `json:"center_y"`
		// Gesture type: pinch, zoom, rotate, swipe, force_touch
		GestureType string `json:"gesture_type"`
		// Scale factor for pinch/zoom gestures (e.g., 0.5 = zoom out, 2.0 = zoom in)
		Scale float64 `json:"scale"`
		// Rotation angle in degrees for rotate gestures
		Rotation float64 `json:"rotation"`
		// Number of fingers for swipe gestures (default: 2)
		FingerCount int32 `json:"finger_count"`
		// Direction for swipe gestures: up, down, left, right
		Direction string `json:"direction"`
		// Application context (optional)
		Application string `json:"application"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	// Map gesture type string to proto enum
	gesturePBType := pb.Gesture_GESTURE_TYPE_UNSPECIFIED
	switch strings.ToLower(params.GestureType) {
	case "pinch":
		gesturePBType = pb.Gesture_GESTURE_TYPE_PINCH
	case "zoom":
		gesturePBType = pb.Gesture_GESTURE_TYPE_ZOOM
	case "rotate":
		gesturePBType = pb.Gesture_GESTURE_TYPE_ROTATE
	case "swipe":
		gesturePBType = pb.Gesture_GESTURE_TYPE_SWIPE
	case "force_touch":
		gesturePBType = pb.Gesture_GESTURE_TYPE_FORCE_TOUCH
	default:
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Unknown gesture_type: %s. Valid: pinch, zoom, rotate, swipe, force_touch", params.GestureType)}},
		}, nil
	}

	// Map direction string to proto enum
	directionPB := pb.Gesture_DIRECTION_UNSPECIFIED
	switch strings.ToLower(params.Direction) {
	case "up":
		directionPB = pb.Gesture_DIRECTION_UP
	case "down":
		directionPB = pb.Gesture_DIRECTION_DOWN
	case "left":
		directionPB = pb.Gesture_DIRECTION_LEFT
	case "right":
		directionPB = pb.Gesture_DIRECTION_RIGHT
	}

	parent := params.Application
	if parent == "" {
		parent = defaultApplicationParent
	}

	fingerCount := params.FingerCount
	if fingerCount <= 0 {
		fingerCount = 2 // Default to 2-finger gesture
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_Gesture{
				Gesture: &pb.Gesture{
					Center: &typepb.Point{
						X: params.CenterX,
						Y: params.CenterY,
					},
					GestureType: gesturePBType,
					Scale:       params.Scale,
					Rotation:    params.Rotation,
					FingerCount: fingerCount,
					Direction:   directionPB,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: parent,
		Input:  input,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to perform gesture: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Performed %s gesture at (%.0f, %.0f) - Input: %s", params.GestureType, params.CenterX, params.CenterY, resp.Name),
		}},
	}, nil
}
