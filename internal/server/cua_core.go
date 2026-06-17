// Copyright 2025 Joseph Cumines
//
// CUA core tool handlers — OpenAI CUA aligned (9 tools)
// screenshot, click, double_click, type, keypress, scroll, drag, move, wait

package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strings"
	"time"

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
	"home":      "home",
	"end":       "end",
	"pageup":    "pageUp",
	"page_up":   "pageUp",
	"pagedown":  "pageDown",
	"page_down": "pageDown",
	// Arrow keys
	"arrowup":    "arrowUp",
	"up":         "arrowUp",
	"arrowdown":  "arrowDown",
	"down":       "arrowDown",
	"arrowleft":  "arrowLeft",
	"left":       "arrowLeft",
	"arrowright": "arrowRight",
	"right":      "arrowRight",
	// Function keys
	"f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4",
	"f5": "f5", "f6": "f6", "f7": "f7", "f8": "f8",
	"f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12",
}

// normalizeCUAKey maps a CUA-style key name to the macOS key name.
// If the key is not in the mapping, it is returned as-is (e.g., "a", "1").
func normalizeCUAKey(key string) string {
	if mapped, ok := cuaKeyMap[strings.ToLower(key)]; ok {
		return mapped
	}
	return key
}

// cuaKeysToModifiers converts CUA-style key names to proto KeyPress_Modifier enums.
// Only modifier keys are converted; non-modifier keys are returned separately.
// Returns (modifiers, nonModifierKeys).
func cuaKeysToModifiers(keys []string) (modifiers []pb.KeyPress_Modifier, nonModifierKeys []string) {
	for _, key := range keys {
		switch strings.ToLower(key) {
		case "ctrl", "control":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_CONTROL)
		case "alt", "option":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_OPTION)
		case "meta", "command", "cmd":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_COMMAND)
		case "shift":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_SHIFT)
		case "fn", "function":
			modifiers = append(modifiers, pb.KeyPress_MODIFIER_FUNCTION)
		default:
			nonModifierKeys = append(nonModifierKeys, key)
		}
	}
	return
}

// clickWithModifiers clicks with modifiers held by decomposing into ButtonDown+ButtonUp.
// Required because MouseClick proto lacks a Modifiers field.
func (s *MCPServer) clickWithModifiers(ctx context.Context, x, y float64, clickType pb.MouseClick_ClickType, clickCount int32, modifiers []pb.KeyPress_Modifier) (*pb.Input, error) {
	if clickCount <= 0 {
		return nil, nil
	}
	var lastResp *pb.Input
	for range clickCount {
		_, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_ButtonDown{
						ButtonDown: &pb.MouseButtonDown{
							Position:  &typepb.Point{X: x, Y: y},
							Button:    clickType,
							Modifiers: modifiers,
						},
					},
				},
			},
		})
		if err != nil {
			return nil, fmt.Errorf("mouse down with modifiers failed: %w", err)
		}

		upResp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_ButtonUp{
						ButtonUp: &pb.MouseButtonUp{
							Position:  &typepb.Point{X: x, Y: y},
							Button:    clickType,
							Modifiers: modifiers,
						},
					},
				},
			},
		})
		if err != nil {
			return nil, fmt.Errorf("mouse up with modifiers failed: %w", err)
		}
		lastResp = upResp
	}

	return lastResp, nil
}

// wrapActionWithModifiers holds modifiers via ButtonDown/ButtonUp around a non-click action.
// Side effect: registers as a click at the position (acceptable for modifier simulation).
func (s *MCPServer) wrapActionWithModifiers(ctx context.Context, x, y float64, modifiers []pb.KeyPress_Modifier, action func() (*pb.Input, error)) (*pb.Input, error) {
	downResp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: defaultApplicationParent,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_ButtonDown{
					ButtonDown: &pb.MouseButtonDown{
						Position:  &typepb.Point{X: x, Y: y},
						Button:    pb.MouseClick_CLICK_TYPE_LEFT,
						Modifiers: modifiers,
					},
				},
			},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("hold modifiers failed: %w", err)
	}
	_ = downResp

	result, err := action()
	if err != nil {
		_, upErr := s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_ButtonUp{
						ButtonUp: &pb.MouseButtonUp{
							Position:  &typepb.Point{X: x, Y: y},
							Button:    pb.MouseClick_CLICK_TYPE_LEFT,
							Modifiers: modifiers,
						},
					},
				},
			},
		})
		if upErr != nil {
			return nil, fmt.Errorf("action failed: %w; modifier release also failed: %v", err, upErr)
		}
		return nil, err
	}

	_, upErr := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: defaultApplicationParent,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_ButtonUp{
					ButtonUp: &pb.MouseButtonUp{
						Position:  &typepb.Point{X: x, Y: y},
						Button:    pb.MouseClick_CLICK_TYPE_LEFT,
						Modifiers: modifiers,
					},
				},
			},
		},
	})
	if upErr != nil {
		log.Printf("WARNING: modifier release failed after successful action: %v", upErr)
	}

	return result, nil
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

// modifierToKeyName converts a proto modifier enum to the key name string.
func modifierToKeyName(mod pb.KeyPress_Modifier) string {
	switch mod {
	case pb.KeyPress_MODIFIER_COMMAND:
		return "command"
	case pb.KeyPress_MODIFIER_OPTION:
		return "option"
	case pb.KeyPress_MODIFIER_CONTROL:
		return "control"
	case pb.KeyPress_MODIFIER_SHIFT:
		return "shift"
	case pb.KeyPress_MODIFIER_FUNCTION:
		return "function"
	case pb.KeyPress_MODIFIER_CAPS_LOCK:
		return "capslock"
	default:
		return "unknown"
	}
}

// mapButtonString maps a CUA button string to proto click type.
// Supports: left, right, middle. "back" and "forward" are unsupported (no proto enum) and return left.
func mapButtonString(button string) pb.MouseClick_ClickType {
	switch strings.ToLower(button) {
	case "right":
		return pb.MouseClick_CLICK_TYPE_RIGHT
	case "middle":
		return pb.MouseClick_CLICK_TYPE_MIDDLE
	case "back", "forward":
		return pb.MouseClick_CLICK_TYPE_LEFT
	default:
		return pb.MouseClick_CLICK_TYPE_LEFT
	}
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

// handleScreenshot handles the screenshot tool — unified capture dispatching
// to CaptureScreenshot, CaptureWindowScreenshot, or CaptureRegionScreenshot
// based on which parameters are provided.
func (s *MCPServer) handleScreenshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Display int      `json:"display"`
		Window  string   `json:"window"`
		X       *float64 `json:"x"`
		Y       *float64 `json:"y"`
		Width   *float64 `json:"width"`
		Height  *float64 `json:"height"`
		Format  string   `json:"format"`
		Quality int32    `json:"quality"`
		OCR     bool     `json:"ocr"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	format := parseImageFormat(params.Format)
	quality := applyDefaultQuality(params.Quality)

	if params.Display < 0 {
		return errorResult("display must be a non-negative integer"), nil
	}

	// Dispatch based on parameters
	switch {
	case params.Window != "":
		// Window-specific capture
		resp, err := s.client.CaptureWindowScreenshot(ctx, &pb.CaptureWindowScreenshotRequest{
			Window:         params.Window,
			Format:         format,
			Quality:        quality,
			IncludeOcrText: params.OCR,
		})
		if err != nil {
			return grpcErrorResult(err, "screenshot"), nil
		}
		return screenshotResult(resp.ImageData, resp.Format, resp.Width, resp.Height,
			fmt.Sprintf("Window screenshot: %dx%d - %s", resp.Width, resp.Height, resp.Window),
			params.OCR, resp.OcrText), nil

	case params.X != nil && params.Y != nil && params.Width != nil && params.Height != nil:
		// Region capture
		if math.IsNaN(*params.X) || math.IsInf(*params.X, 0) || math.IsNaN(*params.Y) || math.IsInf(*params.Y, 0) {
			return errorResult("Region coordinates must be finite numbers"), nil
		}
		if *params.Width <= 0 || *params.Height <= 0 || math.IsNaN(*params.Width) || math.IsNaN(*params.Height) || math.IsInf(*params.Width, 0) || math.IsInf(*params.Height, 0) {
			return errorResult("Region width and height must be positive finite numbers"), nil
		}
		resp, err := s.client.CaptureRegionScreenshot(ctx, &pb.CaptureRegionScreenshotRequest{
			Region: &typepb.Region{
				X:      *params.X,
				Y:      *params.Y,
				Width:  *params.Width,
				Height: *params.Height,
			},
			Format:         format,
			Quality:        quality,
			IncludeOcrText: params.OCR,
		})
		if err != nil {
			return grpcErrorResult(err, "screenshot"), nil
		}
		return screenshotResult(resp.ImageData, resp.Format, resp.Width, resp.Height,
			fmt.Sprintf("Region screenshot: %dx%d at (%.0f, %.0f)", resp.Width, resp.Height, *params.X, *params.Y),
			params.OCR, resp.OcrText), nil

	default:
		// Full display capture
		resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
			Format:         format,
			Quality:        quality,
			Display:        int32(params.Display),
			IncludeOcrText: params.OCR,
		})
		if err != nil {
			return grpcErrorResult(err, "screenshot"), nil
		}
		return screenshotResult(resp.ImageData, resp.Format, resp.Width, resp.Height,
			fmt.Sprintf("Screenshot: %dx%d (display %d)", resp.Width, resp.Height, params.Display),
			params.OCR, resp.OcrText), nil
	}
}

// screenshotResult builds a ToolResult with image content and optional OCR text.
func screenshotResult(imageData []byte, format pb.ImageFormat, width, height int32, summary string, includeOCR bool, ocrText string) *ToolResult {
	encoded := base64.StdEncoding.EncodeToString(imageData)
	mediaType := imageFormatToMediaType(format)

	result := &ToolResult{
		Content: []Content{
			{Type: "image", Data: encoded, MimeType: mediaType},
			{Type: "text", Text: summary},
		},
	}

	if includeOCR && ocrText != "" {
		result.Content = append(result.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("OCR Text:\n%s", ocrText),
		})
	}

	return result
}

// handleClick handles the click tool — click at screen coordinates with optional
// modifier keys held during the click.
func (s *MCPServer) cuaHandleClick(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		X          *float64 `json:"x"`
		Y          *float64 `json:"y"`
		Button     string   `json:"button"`
		ClickCount int32    `json:"click_count"`
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

	const maxClickCount int32 = 10
	clickType := mapButtonString(params.Button)
	clickCount := params.ClickCount
	if clickCount <= 0 {
		clickCount = 1
	}
	if clickCount > maxClickCount {
		return errorResultf("click_count must be at most %d", maxClickCount), nil
	}

	modifiers, _ := cuaKeysToModifiers(params.Keys)

	var resp *pb.Input
	if len(modifiers) > 0 {
		var err error
		resp, err = s.clickWithModifiers(ctx, *params.X, *params.Y, clickType, clickCount, modifiers)
		if err != nil {
			return grpcErrorResult(err, "click"), nil
		}
	} else {
		var err error
		resp, err = s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_Click{
						Click: &pb.MouseClick{
							Position:   &typepb.Point{X: *params.X, Y: *params.Y},
							ClickType:  clickType,
							ClickCount: clickCount,
						},
					},
				},
			},
		})
		if err != nil {
			return grpcErrorResult(err, "click"), nil
		}
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

	return textResultf("%s %s-click at (%.0f, %.0f) - Input: %s", clickWord, buttonDisplayName(clickType), *params.X, *params.Y, inputName(resp)), nil
}

// handleDoubleClick handles the double_click tool.
func (s *MCPServer) handleDoubleClick(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		X      *float64 `json:"x"`
		Y      *float64 `json:"y"`
		Button string   `json:"button"`
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

	clickType := mapButtonString(params.Button)

	modifiers, _ := cuaKeysToModifiers(params.Keys)

	var resp *pb.Input
	if len(modifiers) > 0 {
		var err error
		resp, err = s.clickWithModifiers(ctx, *params.X, *params.Y, clickType, 2, modifiers)
		if err != nil {
			return grpcErrorResult(err, "double_click"), nil
		}
	} else {
		var err error
		resp, err = s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_Click{
						Click: &pb.MouseClick{
							Position:   &typepb.Point{X: *params.X, Y: *params.Y},
							ClickType:  clickType,
							ClickCount: 2,
						},
					},
				},
			},
		})
		if err != nil {
			return grpcErrorResult(err, "double_click"), nil
		}
	}

	return textResultf("double %s-click at (%.0f, %.0f) - Input: %s", buttonDisplayName(clickType), *params.X, *params.Y, inputName(resp)), nil
}

// handleType handles the type tool — type text as keyboard input.
func (s *MCPServer) handleType(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Text      string  `json:"text"`
		CharDelay float64 `json:"char_delay"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Text == "" {
		return errorResult("text parameter is required"), nil
	}
	if params.CharDelay < 0 {
		return errorResult("char_delay must be non-negative"), nil
	}

	if errResult := validateInputLen(params.Text, maxInputTextLen, "text"); errResult != nil {
		return errResult, nil
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

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: defaultApplicationParent,
		Input:  input,
	})
	if err != nil {
		return grpcErrorResult(err, "type"), nil
	}

	displayText := truncateText(params.Text)
	return textResultf("Typed %d characters: \"%s\" - Input: %s", len(params.Text), displayText, resp.Name), nil
}

// handleKeypress handles the keypress tool — press key combinations.
// CUA keys[] format: ["ctrl","c"] or ["meta","shift","3"].
// The last non-modifier key is the primary key; all others are modifiers.
func (s *MCPServer) handleKeypress(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Keys []string `json:"keys"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if len(params.Keys) == 0 {
		return errorResult("keys parameter is required and must be non-empty"), nil
	}

	// Separate modifiers from the primary key
	modifierEnums, nonModifierKeys := cuaKeysToModifiers(params.Keys)

	if len(nonModifierKeys) == 0 && len(modifierEnums) == 0 {
		return errorResult("no valid keys provided"), nil
	}

	// The primary key is the last non-modifier key, or the last key if all are modifiers
	var primaryKey string
	if len(nonModifierKeys) > 0 {
		primaryKey = normalizeCUAKey(nonModifierKeys[len(nonModifierKeys)-1])
	} else {
		// All keys are modifiers — press the last modifier as primary
		primaryKey = modifierToKeyName(modifierEnums[len(modifierEnums)-1])
		modifierEnums = modifierEnums[:len(modifierEnums)-1]
	}

	input := &pb.Input{
		Action: &pb.InputAction{
			InputType: &pb.InputAction_PressKey{
				PressKey: &pb.KeyPress{
					Key:       primaryKey,
					Modifiers: modifierEnums,
				},
			},
		},
	}

	resp, err := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: defaultApplicationParent,
		Input:  input,
	})
	if err != nil {
		return grpcErrorResult(err, "keypress"), nil
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
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		X       float64  `json:"x"`
		Y       float64  `json:"y"`
		ScrollX float64  `json:"scroll_x"`
		ScrollY float64  `json:"scroll_y"`
		Keys    []string `json:"keys"`
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

	modifiers, _ := cuaKeysToModifiers(params.Keys)

	scroll := &pb.Scroll{
		Position:   &typepb.Point{X: params.X, Y: params.Y},
		Horizontal: params.ScrollX,
		Vertical:   -params.ScrollY,
	}

	var resp *pb.Input
	if len(modifiers) > 0 {
		var err error
		resp, err = s.wrapActionWithModifiers(ctx, params.X, params.Y, modifiers, func() (*pb.Input, error) {
			r, e := s.client.CreateInput(ctx, &pb.CreateInputRequest{
				Parent: defaultApplicationParent,
				Input: &pb.Input{
					Action: &pb.InputAction{
						InputType: &pb.InputAction_Scroll{Scroll: scroll},
					},
				},
			})
			return r, e
		})
		if err != nil {
			return grpcErrorResult(err, "scroll"), nil
		}
	} else {
		var err error
		resp, err = s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_Scroll{Scroll: scroll},
				},
			},
		})
		if err != nil {
			return grpcErrorResult(err, "scroll"), nil
		}
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

	return textResultf("Scrolled %s (scroll_x:%.0f, scroll_y:%.0f) at (%.0f, %.0f) - Input: %s",
		direction, params.ScrollX, params.ScrollY, params.X, params.Y, inputName(resp)), nil
}

// handleDrag handles the drag tool — click-and-drag along a sequence of waypoints.
// Uses CUA-style path[] instead of old start_x/start_y/end_x/end_y.
func (s *MCPServer) cuaHandleDrag(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Path []struct {
			X float64 `json:"x"`
			Y float64 `json:"y"`
		} `json:"path"`
		Button   string   `json:"button"`
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
	if params.Duration < 0 {
		return errorResult("duration must be non-negative"), nil
	}

	clickType := mapButtonString(params.Button)

	modifiers, _ := cuaKeysToModifiers(params.Keys)

	start := params.Path[0]
	end := params.Path[len(params.Path)-1]

	drag := &pb.MouseDrag{
		StartPosition: &typepb.Point{X: start.X, Y: start.Y},
		EndPosition:   &typepb.Point{X: end.X, Y: end.Y},
		Duration:      params.Duration,
		Button:        clickType,
	}

	var resp *pb.Input
	if len(modifiers) > 0 {
		var err error
		resp, err = s.wrapActionWithModifiers(ctx, start.X, start.Y, modifiers, func() (*pb.Input, error) {
			r, e := s.client.CreateInput(ctx, &pb.CreateInputRequest{
				Parent: defaultApplicationParent,
				Input: &pb.Input{
					Action: &pb.InputAction{
						InputType: &pb.InputAction_Drag{Drag: drag},
					},
				},
			})
			return r, e
		})
		if err != nil {
			return grpcErrorResult(err, "drag"), nil
		}
	} else {
		var err error
		resp, err = s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_Drag{Drag: drag},
				},
			},
		})
		if err != nil {
			return grpcErrorResult(err, "drag"), nil
		}
	}

	return textResultf("Dragged from (%.0f, %.0f) to (%.0f, %.0f) using %d waypoint(s) - Input: %s",
		start.X, start.Y, end.X, end.Y, len(params.Path), inputName(resp)), nil
}

// handleMove handles the move tool — move mouse cursor without clicking.
func (s *MCPServer) handleMove(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		X    *float64 `json:"x"`
		Y    *float64 `json:"y"`
		Keys []string `json:"keys"`
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

	modifiers, _ := cuaKeysToModifiers(params.Keys)

	move := &pb.MouseMove{
		Position: &typepb.Point{X: *params.X, Y: *params.Y},
	}

	var resp *pb.Input
	if len(modifiers) > 0 {
		var err error
		resp, err = s.wrapActionWithModifiers(ctx, *params.X, *params.Y, modifiers, func() (*pb.Input, error) {
			r, e := s.client.CreateInput(ctx, &pb.CreateInputRequest{
				Parent: defaultApplicationParent,
				Input: &pb.Input{
					Action: &pb.InputAction{
						InputType: &pb.InputAction_MoveMouse{MoveMouse: move},
					},
				},
			})
			return r, e
		})
		if err != nil {
			return grpcErrorResult(err, "move"), nil
		}
	} else {
		var err error
		resp, err = s.client.CreateInput(ctx, &pb.CreateInputRequest{
			Parent: defaultApplicationParent,
			Input: &pb.Input{
				Action: &pb.InputAction{
					InputType: &pb.InputAction_MoveMouse{MoveMouse: move},
				},
			},
		})
		if err != nil {
			return grpcErrorResult(err, "move"), nil
		}
	}

	return textResultf("Moved mouse to (%.0f, %.0f) - Input: %s", *params.X, *params.Y, inputName(resp)), nil
}

// handleWait handles the wait tool — pause for a specified duration.
// No gRPC call needed; native Go sleep.
func (s *MCPServer) handleWait(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Duration float64 `json:"duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if math.IsNaN(params.Duration) || math.IsInf(params.Duration, 0) {
		return errorResult("duration must be a finite number"), nil
	}

	if params.Duration <= 0 {
		params.Duration = 1.0
	}

	// Cap wait to request timeout to avoid blocking indefinitely
	maxWait := float64(s.cfg.RequestTimeout)
	if params.Duration > maxWait {
		params.Duration = maxWait
	}

	timer := time.NewTimer(time.Duration(params.Duration * float64(time.Second)))
	defer timer.Stop()
	select {
	case <-s.ctx.Done():
		return textResultf("Wait interrupted"), nil
	case <-timer.C:
	}

	return textResultf("Waited %.1fs", params.Duration), nil
}
