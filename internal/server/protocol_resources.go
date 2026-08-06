// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// getDisplayGroundingInfo returns JSON string with display information for grounding
// Format follows MCP computer tool specification with screens array
func (s *MCPServer) getDisplayGroundingInfo() string {
	// Handle missing client (e.g., in tests)
	if s.client == nil {
		return `{"screens":[]}`
	}

	ctx, cancel := context.WithTimeout(s.ctx, displayInfoTimeout)
	defer cancel()

	resp, err := s.client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		log.Printf("Warning: failed to get display info for grounding: %v", err)
		return `{"screens":[]}`
	}

	if len(resp.Displays) == 0 {
		return `{"screens":[]}`
	}

	// Build screens array following MCP computer tool format
	screens := make([]map[string]any, 0, len(resp.Displays))

	for i, d := range resp.Displays {
		// Use display ID or index as identifier
		id := fmt.Sprintf("display-%d", i)
		if d.IsMain {
			id = "main"
		}

		dInfo := map[string]any{
			"id":            id,
			"width":         d.Frame.Width,
			"height":        d.Frame.Height,
			"pixel_density": d.Scale,
			"origin_x":      d.Frame.X,
			"origin_y":      d.Frame.Y,
		}
		screens = append(screens, dInfo)
	}

	info := map[string]any{
		"screens": screens,
	}

	infoBytes, err := json.Marshal(info)
	if err != nil {
		log.Printf("Warning: failed to marshal display info: %v", err)
		return `{"screens":[]}`
	}
	return string(infoBytes)
}

// readResource reads content for a resource URI and returns one or more content
// blocks compliant with the 2025-11-25 MCP resources/read result schema.
// Supported URI schemes:
//   - screen://main: captures screenshot of main display, returns base64 PNG in blob
//   - accessibility://{pid}: returns element tree JSON for application with given PID
//   - clipboard://current: returns current clipboard text content
func (s *MCPServer) readResource(parent context.Context, uri string) (contents []map[string]any, err error) {
	if parent == nil {
		parent = s.ctx
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()

	// Parse URI scheme
	if after, ok := strings.CutPrefix(uri, "screen://"); ok {
		// Handle screen://main - capture screenshot
		suffix := after
		if suffix != "main" {
			return nil, fmt.Errorf("unsupported screen resource: %s (only 'main' is supported)", suffix)
		}

		// Capture screenshot of main display
		resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
			Format: pb.ImageFormat_IMAGE_FORMAT_PNG,
		})
		if err != nil {
			return nil, fmt.Errorf("failed to capture screenshot: %w", err)
		}

		// Binary resource content MUST be returned in the "blob" field per spec.
		encoded := base64.StdEncoding.EncodeToString(resp.ImageData)
		return []map[string]any{
			{"uri": uri, "mimeType": "image/png", "blob": encoded},
		}, nil
	}

	if after, ok := strings.CutPrefix(uri, "accessibility://"); ok {
		// Handle accessibility://{pid} - return element tree
		pidStr := after
		if pidStr == "" {
			return nil, fmt.Errorf("accessibility:// requires a PID (e.g., accessibility://1234)")
		}

		pid, err := strconv.ParseInt(pidStr, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("invalid PID in accessibility URI: %s", pidStr)
		}

		// Build application resource name and traverse accessibility tree
		appName := fmt.Sprintf("applications/%d", pid)
		resp, err := s.client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
			Name: appName,
		})
		if err != nil {
			return nil, fmt.Errorf("failed to traverse accessibility tree: %w", err)
		}

		// Convert elements to JSON
		elements := make([]map[string]any, 0, len(resp.Elements))
		for _, elem := range resp.Elements {
			elemMap := map[string]any{
				"id":   elem.GetElementId(),
				"role": elem.GetRole(),
				"path": elem.GetPath(),
			}
			if text := elem.GetText(); text != "" {
				elemMap["text"] = text
			}
			// Add bounds from individual x/y/width/height fields
			x, y := elem.GetX(), elem.GetY()
			w, h := elem.GetWidth(), elem.GetHeight()
			if w > 0 || h > 0 {
				elemMap["bounds"] = map[string]any{
					"x":      x,
					"y":      y,
					"width":  w,
					"height": h,
				}
			}
			if len(elem.GetActions()) > 0 {
				elemMap["actions"] = elem.GetActions()
			}
			elements = append(elements, elemMap)
		}

		result := map[string]any{
			"application":  appName,
			"elementCount": len(elements),
			"elements":     elements,
		}

		jsonBytes, err := json.Marshal(result)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal accessibility tree: %w", err)
		}
		return []map[string]any{
			{"uri": uri, "mimeType": "application/json", "text": string(jsonBytes)},
		}, nil
	}

	if after, ok := strings.CutPrefix(uri, "clipboard://"); ok {
		// Handle clipboard://current - return clipboard text
		suffix := after
		if suffix != "current" {
			return nil, fmt.Errorf("unsupported clipboard resource: %s (only 'current' is supported)", suffix)
		}

		resp, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
		if err != nil {
			return nil, fmt.Errorf("failed to get clipboard: %w", err)
		}

		// Return text content (or indicate if empty/non-text)
		content := resp.GetContent()
		if content == nil {
			return []map[string]any{
				{"uri": uri, "mimeType": "text/plain", "text": ""},
			}, nil // Empty clipboard
		}
		switch payload := content.GetContent().(type) {
		case *pb.ClipboardContent_Text:
			return []map[string]any{
				{"uri": uri, "mimeType": "text/plain", "text": payload.Text},
			}, nil
		case *pb.ClipboardContent_Html:
			return []map[string]any{
				{"uri": uri, "mimeType": "text/html", "text": payload.Html},
			}, nil
		case *pb.ClipboardContent_Rtf:
			return []map[string]any{
				{"uri": uri, "mimeType": "text/rtf", "text": string(payload.Rtf)},
			}, nil
		case *pb.ClipboardContent_Files:
			if payload.Files == nil {
				return nil, fmt.Errorf("clipboard returned file content without paths")
			}
			filesJSON, _ := json.Marshal(payload.Files.GetPaths())
			return []map[string]any{
				{"uri": uri, "mimeType": "application/json", "text": string(filesJSON)},
			}, nil
		case *pb.ClipboardContent_Url:
			return []map[string]any{
				{"uri": uri, "mimeType": "text/plain", "text": payload.Url},
			}, nil
		case *pb.ClipboardContent_Image:
			return nil, fmt.Errorf("clipboard image content is not available as a text resource")
		default:
			return nil, fmt.Errorf("clipboard content has no payload")
		}
	}

	return nil, fmt.Errorf("unsupported resource URI scheme: %s", uri)
}

// listPrompts returns the list of available MCP prompt templates.
func (s *MCPServer) listPrompts() []map[string]any {
	return []map[string]any{
		{
			"name":        "navigate_to_element",
			"description": "Navigate to and click an accessibility element",
			"arguments": []map[string]any{
				{"name": "selector", "description": "One key:value selector, such as role:AXButton, text:Save, or text_contains:submit", "required": true},
			},
		},
		{
			"name":        "fill_form",
			"description": "Find and fill form fields with values",
			"arguments": []map[string]any{
				{"name": "fields", "description": "JSON object mapping field names/labels to values", "required": true},
			},
		},
		{
			"name":        "verify_state",
			"description": "Verify an element matches expected state",
			"arguments": []map[string]any{
				{"name": "selector", "description": "Element selector", "required": true},
				{"name": "expected_state", "description": "Expected state: visible, enabled, focused, or text value", "required": true},
			},
		},
	}
}

// getPrompt returns a specific prompt with argument substitution.
// Prompts return messages with role "user" per MCP specification.
func (s *MCPServer) getPrompt(name string, args map[string]any) (map[string]any, error) {
	switch name {
	case "navigate_to_element":
		selector := ""
		if v, ok := args["selector"]; ok {
			selector = fmt.Sprintf("%v", v)
		}
		content := fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, call find_elements with parent set to the exact application/window resource and selector set to one key:value expression. Selector for this step: %s
   Example: {"parent": "applications/<application>/windows/<window>", "selector": "role:AXButton"}
2. Once found, use click_element with the same parent and element ID. The handle remains bound to that exact parent and AX identity; rediscover it if the UI or owner changes.
3. Verify the action completed successfully by checking for state changes

If the element is not immediately visible, you may need to:
- Scroll to reveal it
- Poll with find_elements and use wait between attempts
- Check if it's in a different window`, selector)

		return map[string]any{
			"description": "Navigate to and click an accessibility element",
			"messages": []map[string]any{
				{
					"role": "user",
					"content": map[string]any{
						"type": "text",
						"text": content,
					},
				},
			},
		}, nil

	case "fill_form":
		fieldsStr := "{}"
		if v, ok := args["fields"]; ok {
			if fieldBytes, err := json.Marshal(v); err == nil {
				fieldsStr = string(fieldBytes)
			}
		}

		content := fmt.Sprintf(`Fill form fields with the following values:

%s

For each field:
1. Use find_elements to locate the form field by its label or role (AXTextField, AXTextArea, AXComboBox)
2. Focus the field by clicking on it
3. Use type_element to enter the value
4. Verify the value was entered correctly by reading the element's value

Common field roles:
- AXTextField: Single-line text input
- AXTextArea: Multi-line text input
- AXCheckBox: Checkbox (use click_element to toggle)
- AXPopUpButton: Dropdown menu
- AXComboBox: Combo box with text and dropdown`, fieldsStr)

		return map[string]any{
			"description": "Find and fill form fields with values",
			"messages": []map[string]any{
				{
					"role": "user",
					"content": map[string]any{
						"type": "text",
						"text": content,
					},
				},
			},
		}, nil

	case "verify_state":
		selector := ""
		if v, ok := args["selector"]; ok {
			selector = fmt.Sprintf("%v", v)
		}
		expectedState := ""
		if v, ok := args["expected_state"]; ok {
			expectedState = fmt.Sprintf("%v", v)
		}

		content := fmt.Sprintf(`Verify that a UI element matches the expected state.

Element to find: %s
Expected state: %s

Steps:
1. Use find_elements to locate the element matching the selector
2. Use read_element to retrieve the element's current properties
3. Compare the element's state against the expected value:
   - "visible": Check that the element exists and is not hidden
   - "enabled": Check AXEnabled attribute is true
   - "focused": Check AXFocused attribute is true
   - For text values: Check AXValue or AXTitle matches the expected text

4. Report whether the verification passed or failed with details

If the state may change asynchronously, poll with find_elements/read_element and use wait between attempts until timeout.`, selector, expectedState)

		return map[string]any{
			"description": "Verify an element matches expected state",
			"messages": []map[string]any{
				{
					"role": "user",
					"content": map[string]any{
						"type": "text",
						"text": content,
					},
				},
			},
		}, nil

	default:
		return nil, fmt.Errorf("unknown prompt: %s", name)
	}
}
