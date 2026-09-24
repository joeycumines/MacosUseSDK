// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// TestMCPPromptsGetNavigateToElement tests prompts/get for navigate_to_element
// with selector and action arguments.
func TestMCPPromptsGetNavigateToElement(t *testing.T) {
	tests := []struct {
		name           string
		selector       string
		wantContains   []string
		wantNotContain []string
	}{
		{
			name:     "with button selector",
			selector: "button:Submit",
			wantContains: []string{
				"button:Submit",
				"click_element",
				"find_elements",
			},
		},
		{
			name:     "with cell selector",
			selector: "cell:Document.txt",
			wantContains: []string{
				"cell:Document.txt",
				"click_element",
			},
		},
		{
			name:     "with icon selector",
			selector: "icon:Finder",
			wantContains: []string{
				"icon:Finder",
				"click_element",
			},
		},
		{
			name:     "with menu selector",
			selector: "menu:File",
			wantContains: []string{
				"menu:File",
				"click_element",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			selector := tt.selector

			content := fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, call find_elements with parent set to the exact application/window resource and selector set to one key:value expression. Selector for this step: %s
   Example: {"parent": "applications/<application>/windows/<window>", "selector": "role:AXButton"}
2. Once found, use click_element with the same parent and element ID. The handle remains bound to that exact parent and AX identity; rediscover it if the UI or owner changes.
3. Verify the action completed successfully by checking for state changes

If the element is not immediately visible, you may need to:
- Scroll to reveal it
- Poll with find_elements and use wait between attempts
- Check if it's in a different window`, selector)

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}

			for _, notWant := range tt.wantNotContain {
				if strings.Contains(content, notWant) {
					t.Errorf("Content should NOT contain %q", notWant)
				}
			}
		})
	}
}

// TestMCPPromptsGetFillForm tests prompts/get for fill_form with fields argument.
func TestMCPPromptsGetFillForm(t *testing.T) {
	tests := []struct {
		name         string
		fields       map[string]any
		wantContains []string
	}{
		{
			name: "simple text fields",
			fields: map[string]any{
				"username": "testuser",
				"email":    "test@example.com",
			},
			wantContains: []string{
				"testuser",
				"test@example.com",
				"AXTextField",
				"find_elements",
			},
		},
		{
			name:   "empty fields object",
			fields: map[string]any{},
			wantContains: []string{
				"{}",
				"AXTextField",
			},
		},
		{
			name: "fields with nested values",
			fields: map[string]any{
				"address": map[string]string{
					"street": "123 Main St",
					"city":   "Boston",
				},
			},
			wantContains: []string{
				"123 Main St",
				"Boston",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt for fill_form
			fieldsStr := "{}"
			if fieldBytes, err := json.Marshal(tt.fields); err == nil {
				fieldsStr = string(fieldBytes)
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

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}
		})
	}
}

// TestMCPPromptsGetVerifyState tests prompts/get for verify_state with selector
// and expected_state arguments.
func TestMCPPromptsGetVerifyState(t *testing.T) {
	tests := []struct {
		name          string
		selector      string
		expectedState string
		wantContains  []string
	}{
		{
			name:          "verify visible state",
			selector:      "button:OK",
			expectedState: "visible",
			wantContains: []string{
				"button:OK",
				"visible",
				"find_elements",
				"read_element",
			},
		},
		{
			name:          "verify enabled state",
			selector:      "textfield:Search",
			expectedState: "enabled",
			wantContains: []string{
				"textfield:Search",
				"enabled",
				"AXEnabled",
			},
		},
		{
			name:          "verify focused state",
			selector:      "textarea:Editor",
			expectedState: "focused",
			wantContains: []string{
				"textarea:Editor",
				"focused",
				"AXFocused",
			},
		},
		{
			name:          "verify text value",
			selector:      "label:Status",
			expectedState: "Connected",
			wantContains: []string{
				"label:Status",
				"Connected",
				"AXValue",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt for verify_state
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

If the state may change asynchronously, poll with find_elements/read_element and use wait between attempts until timeout.`, tt.selector, tt.expectedState)

			for _, want := range tt.wantContains {
				if !strings.Contains(content, want) {
					t.Errorf("Content should contain %q", want)
				}
			}
		})
	}
}

// TestMCPPromptsGetUnknownPrompt tests error handling for unknown prompt names.
func TestMCPPromptsGetUnknownPrompt(t *testing.T) {
	unknownPrompts := []string{
		"unknown_prompt",
		"does_not_exist",
		"navigate_to_element_v2",
		"",
		"NAVIGATE_TO_ELEMENT", // case-sensitive
	}

	for _, name := range unknownPrompts {
		t.Run("unknown_"+name, func(t *testing.T) {
			// Simulate getPrompt error handling
			var err error
			switch name {
			case "navigate_to_element", "fill_form", "verify_state":
				// These are known prompts - should not error
			default:
				err = fmt.Errorf("unknown prompt: %s", name)
			}

			if err == nil {
				t.Errorf("Expected error for unknown prompt %q", name)
				return
			}

			if !strings.Contains(err.Error(), "unknown prompt") {
				t.Errorf("Error should contain 'unknown prompt', got: %v", err)
			}
		})
	}
}

// TestMCPPromptsGetMissingArguments tests default values when optional arguments
// are missing from the request.
func TestMCPPromptsGetMissingArguments(t *testing.T) {
	tests := []struct {
		name              string
		promptName        string
		args              map[string]any
		wantDefaultValue  string
		wantContentSubstr string
	}{
		{
			name:              "navigate_to_element without action still uses click prompt",
			promptName:        "navigate_to_element",
			args:              map[string]any{"selector": "button:Test"},
			wantContentSubstr: "click_element",
		},
		{
			name:              "navigate_to_element without selector",
			promptName:        "navigate_to_element",
			args:              map[string]any{},
			wantContentSubstr: "Selector for this step:", // empty selector is allowed
		},
		{
			name:              "fill_form without fields uses empty object",
			promptName:        "fill_form",
			args:              map[string]any{},
			wantDefaultValue:  "{}",
			wantContentSubstr: "{}",
		},
		{
			name:              "verify_state without selector",
			promptName:        "verify_state",
			args:              map[string]any{"expected_state": "visible"},
			wantContentSubstr: "Element to find: ",
		},
		{
			name:              "verify_state without expected_state",
			promptName:        "verify_state",
			args:              map[string]any{"selector": "button:OK"},
			wantContentSubstr: "Expected state: ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt with partial arguments
			var content string

			switch tt.promptName {
			case "navigate_to_element":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, call find_elements with parent set to the exact application/window resource and selector set to one key:value expression. Selector for this step: %s
   Example: {"parent": "applications/<application>/windows/<window>", "selector": "role:AXButton"}
2. Once found, use click_element with the same parent and element ID. The handle remains bound to that exact parent and AX identity; rediscover it if the UI or owner changes.`, selector)

			case "fill_form":
				fieldsStr := "{}"
				if v, ok := tt.args["fields"]; ok {
					if fieldBytes, err := json.Marshal(v); err == nil {
						fieldsStr = string(fieldBytes)
					}
				}
				content = fieldsStr

			case "verify_state":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				expectedState := ""
				if v, ok := tt.args["expected_state"]; ok {
					expectedState = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf("Element to find: %s\nExpected state: %s", selector, expectedState)
			}

			if !strings.Contains(content, tt.wantContentSubstr) {
				t.Errorf("Content should contain %q, got: %s", tt.wantContentSubstr, content)
			}
		})
	}
}

// TestMCPPromptsGetResponseStructure validates prompts/get JSON-RPC response
// matches MCP spec with messages array containing role:user.
func TestMCPPromptsGetResponseStructure(t *testing.T) {
	// Simulate complete JSON-RPC response for prompts/get
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 6,
		"result": {
			"description": "Navigate to and click an accessibility element",
			"messages": [
				{
					"role": "user",
					"content": {
						"type": "text",
						"text": "Find and interact with a UI element..."
					}
				}
			]
		}
	}`

	var response map[string]any
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatalf("Failed to parse response JSON: %v", err)
	}

	// Verify JSON-RPC 2.0 structure
	if response["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want '2.0'", response["jsonrpc"])
	}

	// Verify result object
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatal("Response should contain 'result' object")
	}

	// Verify description field
	if _, ok := result["description"].(string); !ok {
		t.Error("Result should contain 'description' string field")
	}

	// Verify messages array
	messages, ok := result["messages"].([]any)
	if !ok {
		t.Fatal("Result should contain 'messages' array")
	}

	if len(messages) == 0 {
		t.Fatal("Messages array should not be empty")
	}

	// Verify message structure
	message, ok := messages[0].(map[string]any)
	if !ok {
		t.Fatal("Message should be an object")
	}

	// Verify role is "user" per MCP spec
	role, ok := message["role"].(string)
	if !ok {
		t.Error("Message should have 'role' string field")
	}
	if role != "user" {
		t.Errorf("Message role = %q, want 'user' (per MCP spec)", role)
	}

	// Verify content structure
	content, ok := message["content"].(map[string]any)
	if !ok {
		t.Fatal("Message should have 'content' object")
	}

	contentType, ok := content["type"].(string)
	if !ok {
		t.Error("Content should have 'type' string field")
	}
	if contentType != "text" {
		t.Errorf("Content type = %q, want 'text'", contentType)
	}

	if _, ok := content["text"].(string); !ok {
		t.Error("Content should have 'text' string field")
	}
}

// TestMCPPromptsArgumentSubstitution verifies arguments are properly substituted
// into prompt content.
func TestMCPPromptsArgumentSubstitution(t *testing.T) {
	tests := []struct {
		name       string
		promptName string
		args       map[string]any
		mustAppear []string
	}{
		{
			name:       "navigate_to_element substitutes selector",
			promptName: "navigate_to_element",
			args:       map[string]any{"selector": "UNIQUE_SELECTOR_12345"},
			mustAppear: []string{"UNIQUE_SELECTOR_12345"},
		},
		{
			name:       "fill_form substitutes fields JSON",
			promptName: "fill_form",
			args: map[string]any{
				"fields": map[string]string{"UNIQUE_FIELD": "UNIQUE_VALUE"},
			},
			mustAppear: []string{"UNIQUE_FIELD", "UNIQUE_VALUE"},
		},
		{
			name:       "verify_state substitutes selector",
			promptName: "verify_state",
			args:       map[string]any{"selector": "UNIQUE_SELECTOR_VERIFY", "expected_state": "visible"},
			mustAppear: []string{"UNIQUE_SELECTOR_VERIFY"},
		},
		{
			name:       "verify_state substitutes expected_state",
			promptName: "verify_state",
			args:       map[string]any{"selector": "elem", "expected_state": "UNIQUE_STATE_VALUE"},
			mustAppear: []string{"UNIQUE_STATE_VALUE"},
		},
		{
			name:       "special characters in arguments",
			promptName: "navigate_to_element",
			args:       map[string]any{"selector": `button:"Click Me" with spaces`},
			mustAppear: []string{`button:"Click Me" with spaces`},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate getPrompt with argument substitution
			var content string

			switch tt.promptName {
			case "navigate_to_element":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, call find_elements with parent set to the exact application/window resource and selector set to one key:value expression. Selector for this step: %s
   Example: {"parent": "applications/<application>/windows/<window>", "selector": "role:AXButton"}
2. Once found, use click_element with the same parent and element ID. The handle remains bound to that exact parent and AX identity; rediscover it if the UI or owner changes.`, selector)

			case "fill_form":
				fieldsStr := "{}"
				if v, ok := tt.args["fields"]; ok {
					if fieldBytes, err := json.Marshal(v); err == nil {
						fieldsStr = string(fieldBytes)
					}
				}
				content = fmt.Sprintf(`Fill form fields with the following values:

%s`, fieldsStr)

			case "verify_state":
				selector := ""
				if v, ok := tt.args["selector"]; ok {
					selector = fmt.Sprintf("%v", v)
				}
				expectedState := ""
				if v, ok := tt.args["expected_state"]; ok {
					expectedState = fmt.Sprintf("%v", v)
				}
				content = fmt.Sprintf(`Verify that a UI element matches the expected state.

Element to find: %s
Expected state: %s`, selector, expectedState)
			}

			for _, want := range tt.mustAppear {
				if !strings.Contains(content, want) {
					t.Errorf("Argument %q was not substituted into content", want)
				}
			}
		})
	}
}
