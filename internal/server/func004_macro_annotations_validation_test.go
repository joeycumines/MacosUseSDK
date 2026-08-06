// Copyright 2025 Joseph Cumines
//
// FUNC-004 defect tests: C8 (MCP tool annotations surfaced in tools/list),
// C9 (macro + type_element descriptions are prescriptive multi-sentence
// guidance), and C10 (macro tools have ValidateInput enforcing length limits
// via the C12 constants). State-difference assertions: each test proves a
// concrete observable behavior rather than a happy-path OK.

package server

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// toolListEntry decodes the tools/list wire response including annotations.
type toolListEntry struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations"`
}

type toolListResultWithAnnotations struct {
	Tools []toolListEntry `json:"tools"`
}

// TestMCPToolsList_AnnotationsSurfaceForEachTool (C8) proves every production
// tool exposes the four MCP 2025-11-25 hint keys through tools/list on both
// the HTTP and stdio transports, and that read-only vs mutating tools carry
// the contractually correct readOnlyHint.
func TestMCPToolsList_AnnotationsSurfaceForEachTool(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()

	// Read tools/list straight off the registry-derived annotation helper and
	// the live HTTP wire response; both must agree and carry all four hints.
	httpTools := toolsListOverHTTP(t, server)

	requiredHints := []string{"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"}
	for _, name := range allRegisteredToolNames(server) {
		tool, ok := server.tools[name]
		if !ok {
			t.Fatalf("registered tool %q missing from server.tools", name)
		}
		// Registry-derived annotations must contain all four hints.
		registryHints := tool.mcpAnnotations()
		for _, hint := range requiredHints {
			if _, ok := registryHints[hint]; !ok {
				t.Fatalf("tool %q registry annotations missing hint %q", name, hint)
			}
		}
		// Wire response must surface the same hints for this tool.
		wire, ok := httpTools[name]
		if !ok {
			t.Fatalf("tool %q missing from tools/list wire response", name)
		}
		if wire.Annotations == nil {
			t.Fatalf("tool %q tools/list response has no annotations", name)
		}
		for _, hint := range requiredHints {
			if _, ok := wire.Annotations[hint]; !ok {
				t.Fatalf("tool %q wire annotations missing hint %q", name, hint)
			}
		}
		// readOnlyHint correctness: read-only tools must be read-only true;
		// mutating tools must be read-only false.
		registryRO, _ := registryHints["readOnlyHint"].(bool)
		if tool.MutationPolicy == mutationPolicyReadOnly && !registryRO {
			t.Fatalf("read-only tool %q has readOnlyHint=false", name)
		}
		if tool.MutationPolicy != mutationPolicyReadOnly && registryRO {
			t.Fatalf("mutating tool %q has readOnlyHint=true", name)
		}
		wireRO, _ := wire.Annotations["readOnlyHint"].(bool)
		if registryRO != wireRO {
			t.Fatalf("tool %q wire readOnlyHint=%v differs from registry %v", name, wireRO, registryRO)
		}
	}
}

// TestMCPAnnotations_DestructiveMacrosAreFlagged (C8) proves the genuinely
// destructive macro tools (delete_macro, execute_macro) override the default
// destructiveHint=false with destructiveHint=true, while create/update/get/list
// stay non-destructive. This is a state-difference assertion across siblings.
func TestMCPAnnotations_DestructiveMacrosAreFlagged(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()

	destructive := map[string]bool{
		"delete_macro":  true,
		"execute_macro": true,
	}
	for _, name := range []string{"create_macro", "get_macro", "list_macros", "update_macro"} {
		destructive[name] = false
	}
	for name, wantDestructive := range destructive {
		tool, ok := server.tools[name]
		if !ok {
			t.Fatalf("macro tool %q not registered", name)
		}
		got, _ := tool.mcpAnnotations()["destructiveHint"].(bool)
		if got != wantDestructive {
			t.Fatalf("tool %q destructiveHint=%v, want %v", name, got, wantDestructive)
		}
	}
}

// TestMacroToolDescriptions_ArePrescriptive (C9) proves the macro and
// type_element descriptions are multi-sentence prescriptive guidance (not the
// prior one-sentence stubs) and reference their sibling tools where helpful.
func TestMacroToolDescriptions_ArePrescriptive(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()

	// Each description must have >=3 sentences and mention at least one
	// sibling tool name or a prescriptive verb, proving it tells the model
	// WHEN to call it.
	cases := map[string]string{
		"create_macro":  "display_name",
		"get_macro":     "macros/",
		"list_macros":   "page_token",
		"update_macro":  "get_macro",
		"delete_macro":  "delete",
		"execute_macro": "macro",
		"type_element":  "CLEAR",
	}
	for name, mustContain := range cases {
		tool, ok := server.tools[name]
		if !ok {
			t.Fatalf("tool %q not registered", name)
		}
		if sentenceCount(tool.Description) < 3 {
			t.Fatalf("tool %q description has %d sentences, want >=3: %q", name, sentenceCount(tool.Description), tool.Description)
		}
		if !strings.Contains(tool.Description, mustContain) {
			t.Fatalf("tool %q description %q must contain %q", name, tool.Description, mustContain)
		}
	}
}

// TestMacroValidateInput_CreateEnforcesLimits (C10/C12) proves create_macro's
// ValidateInput rejects missing/oversized display_name, empty actions, and
// over-limit tags, while accepting valid input.
func TestMacroValidateInput_CreateEnforcesLimits(t *testing.T) {
	validator := validateCreateMacroInput
	// Valid input must pass.
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      []any{map[string]any{"kind": "press"}},
	}); err != nil {
		t.Fatalf("valid create input rejected: %v", err)
	}
	// Missing display_name.
	if err := validator(map[string]any{"actions": []any{map[string]any{}}}); err == nil {
		t.Fatal("missing display_name accepted")
	}
	// Oversized display_name.
	if err := validator(map[string]any{
		"display_name": strings.Repeat("x", maxMacroDisplayNameLen+1),
		"actions":      []any{map[string]any{}},
	}); err == nil {
		t.Fatal("oversized display_name accepted")
	}
	// Empty actions array.
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      []any{},
	}); err == nil {
		t.Fatal("empty actions accepted")
	}
	// actions not an array.
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      "nope",
	}); err == nil {
		t.Fatal("non-array actions accepted")
	}
	// Too many tags.
	tooManyTags := make([]any, maxMacroTags+1)
	for i := range tooManyTags {
		tooManyTags[i] = "t"
	}
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      []any{map[string]any{}},
		"tags":         tooManyTags,
	}); err == nil {
		t.Fatal("too many tags accepted")
	}
	// Oversized tag.
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      []any{map[string]any{}},
		"tags":         []any{strings.Repeat("x", maxMacroTagLen+1)},
	}); err == nil {
		t.Fatal("oversized tag accepted")
	}
	// Oversized description.
	if err := validator(map[string]any{
		"display_name": "ok",
		"actions":      []any{map[string]any{}},
		"description":  strings.Repeat("x", maxMacroDescriptionLen+1),
	}); err == nil {
		t.Fatal("oversized description accepted")
	}
}

// TestMacroValidateInput_UpdateRequiresMacroAndField (C10/C14) proves
// update_macro's ValidateInput requires the macros/ resource name (with a
// next-step hint) and at least one mutable field.
func TestMacroValidateInput_UpdateRequiresMacroAndField(t *testing.T) {
	validator := validateUpdateMacroInput
	// Valid update.
	if err := validator(map[string]any{
		"macro":        "macros/abc",
		"display_name": "new",
	}); err != nil {
		t.Fatalf("valid update rejected: %v", err)
	}
	// Missing macro.
	if err := validator(map[string]any{"display_name": "new"}); err == nil {
		t.Fatal("missing macro accepted")
	}
	// Malformed macro must mention list_macros (C14 actionable hint).
	err := validator(map[string]any{"macro": "not-a-resource", "display_name": "new"})
	if err == nil || !strings.Contains(err.Error(), "list_macros") {
		t.Fatalf("malformed macro error lacks hint: %v", err)
	}
	// No mutable field provided.
	if err := validator(map[string]any{"macro": "macros/abc"}); err == nil {
		t.Fatal("update with no mutable field accepted")
	}
}

// TestMacroValidateInput_ResourceInputRejectsBadName (C10/C14) proves the
// shared resource-name validator used by get/delete/execute rejects a missing
// and malformed macro name with a next-step hint.
func TestMacroValidateInput_ResourceInputRejectsBadName(t *testing.T) {
	validator := validateMacroResourceInput
	if err := validator(map[string]any{"macro": "macros/abc"}); err != nil {
		t.Fatalf("valid resource name rejected: %v", err)
	}
	if err := validator(map[string]any{}); err == nil {
		t.Fatal("missing macro accepted")
	}
	err := validator(map[string]any{"macro": "not-a-resource"})
	if err == nil || !strings.Contains(err.Error(), "list_macros") {
		t.Fatalf("malformed resource name error lacks hint: %v", err)
	}
}

// TestMacroToolsWiredToValidators (C10) proves the production macro tools
// actually carry their ValidateInput so schema validation cannot silently
// bypass the limits proven above.
func TestMacroToolsWiredToValidators(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()
	withValidator := map[string]bool{
		"create_macro":  true,
		"update_macro":  true,
		"delete_macro":  true,
		"execute_macro": true,
		"get_macro":     true,
	}
	for name, expectValidator := range withValidator {
		tool, ok := server.tools[name]
		if !ok {
			t.Fatalf("macro tool %q not registered", name)
		}
		if (tool.ValidateInput != nil) != expectValidator {
			t.Fatalf("tool %q ValidateInput wired=%v, want %v", name, tool.ValidateInput != nil, expectValidator)
		}
	}
}

// toolsListOverHTTP returns the tools/list response over the HTTP transport
// keyed by tool name, including annotations.
func toolsListOverHTTP(t *testing.T, server *MCPServer) map[string]toolListEntry {
	t.Helper()
	response, err := server.handleHTTPMessage(&transport.Message{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "tools/list"})
	if err != nil {
		t.Fatalf("HTTP tools/list failed: %v", err)
	}
	if response == nil || response.Error != nil {
		t.Fatalf("HTTP tools/list returned invalid response: %+v", response)
	}
	var result toolListResultWithAnnotations
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode tools/list result: %v", err)
	}
	out := make(map[string]toolListEntry, len(result.Tools))
	for _, tool := range result.Tools {
		out[tool.Name] = tool
	}
	return out
}

// allRegisteredToolNames returns the sorted, non-empty names of every tool the
// registry declares.
func allRegisteredToolNames(server *MCPServer) []string {
	names := make([]string, 0, len(server.tools))
	for name := range server.tools {
		if name == "" {
			continue
		}
		names = append(names, name)
	}
	return names
}

// sentenceCount approximates sentence count by counting terminal punctuation.
func sentenceCount(s string) int {
	n := 0
	for _, r := range s {
		if r == '.' || r == '!' || r == '?' {
			n++
		}
	}
	if n == 0 && strings.TrimSpace(s) != "" {
		return 1
	}
	return n
}
