// Copyright 2025 Joseph Cumines
//
// Go MCP macro tool handlers.

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/fieldmaskpb"
)

const maxMacroDisplayNameLen = 256
const maxMacroDescriptionLen = 4096
const maxMacroTagLen = 128
const maxMacroTags = 32

const createMacroDescription = "Create a named, reusable macro that records an ordered list of automation actions. " +
	"Use this when you will repeat the same sequence of actions (clicks, keystrokes, writes) on a stable target and want to replay them atomically by name; do not use it for one-off interactions. " +
	"You must provide a display_name and a non-empty actions list; tags, description, and a custom macro_id are optional. " +
	"The result contains the fully-qualified macros/{id} resource name, which you pass to get_macro, update_macro, execute_macro, or delete_macro."

const getMacroDescription = "Retrieve the full definition of one macro by its exact macros/{id} resource name. " +
	"Use this to inspect a macro's actions, parameters, tags, and execution count before running or modifying it. " +
	"You must provide the exact `macro` resource name (use list_macros first if you do not know it). " +
	"The result is the complete macro body; it performs no actions on the desktop."

const listMacrosDescription = "List all stored macros with optional opaque pagination. " +
	"Use this to discover the available macros and their macros/{id} resource names before calling get_macro, execute_macro, update_macro, or delete_macro. " +
	"Provide page_size to limit the count and page_token from a previous response to continue; the token is opaque, so do not parse it. " +
	"The result contains the macro summaries and a next_page_token that is empty when the listing is complete."

const updateMacroDescription = "Update one existing macro, replacing only the fields you provide (display_name, description, actions, or tags). " +
	"Use this to correct or refine a macro after inspecting it with get_macro; fields you omit are left unchanged. " +
	"You must provide the target `macro` resource name and at least one field to change; pass the full replacement actions/tags array (they are not merged). " +
	"The result contains the updated macro; it performs no actions on the desktop."

const deleteMacroDescription = "Permanently delete one macro by its exact macros/{id} resource name. " +
	"Use this only when a macro is no longer needed; deletion is irreversible, so confirm the name with get_macro or list_macros first. " +
	"You must provide the `macro` resource name; set force to true only if a prior execution is still in flight. " +
	"A successful result confirms removal; the macro can no longer be executed or referenced."

const executeMacroDescription = "Execute one stored macro by name, replaying its ordered actions as a long-running operation. " +
	"Use this to run a macro you previously created or discovered via list_macros; prefer it over re-issuing each action individually when the same sequence recurs. " +
	"You must provide the `macro` resource name; optionally target an applications/{id} scope for physical actions and a timeout in seconds (default 300). " +
	"The result reports the macro's execution outcome; the actions it contains (clicks, keystrokes, writes) take real effect on the desktop."

// validateCreateMacroInput validates create_macro arguments: a non-empty
// display name within the length limit, a non-empty action list, an optional
// description within its limit, and tags within per-tag/count limits.
func validateCreateMacroInput(arguments map[string]any) error {
	displayName, err := requiredString(arguments, "display_name")
	if err != nil {
		return err
	}
	if len(displayName) > maxMacroDisplayNameLen {
		return fmt.Errorf("display_name must be at most %d characters", maxMacroDisplayNameLen)
	}
	// actions is required and must be a non-empty array.
	rawActions, ok := arguments["actions"].([]any)
	if !ok {
		return fmt.Errorf("actions parameter is required and must be a non-empty array")
	}
	if len(rawActions) == 0 {
		return fmt.Errorf("actions must contain at least one action")
	}
	if desc, ok, err := optionalString(arguments, "description"); err != nil {
		return err
	} else if ok && len(desc) > maxMacroDescriptionLen {
		return fmt.Errorf("description must be at most %d characters", maxMacroDescriptionLen)
	}
	if err := validateMacroTags(arguments["tags"]); err != nil {
		return err
	}
	if macroID, ok, err := optionalString(arguments, "macro_id"); err != nil {
		return err
	} else if ok && macroID == "" {
		return fmt.Errorf("macro_id must be non-empty when provided")
	}
	return nil
}

// validateUpdateMacroInput validates update_macro arguments: the target macro
// resource name is required, and at least one mutable field must be provided,
// each within its length/count limit.
func validateUpdateMacroInput(arguments map[string]any) error {
	macro, err := requiredString(arguments, "macro")
	if err != nil {
		return err
	}
	if !strings.HasPrefix(macro, "macros/") {
		return fmt.Errorf("macro resource name must start with macros/ (use list_macros to find valid names)")
	}
	provided := false
	if name, ok, err := optionalString(arguments, "display_name"); err != nil {
		return err
	} else if ok {
		provided = true
		if name == "" {
			return fmt.Errorf("display_name must be non-empty")
		}
		if len(name) > maxMacroDisplayNameLen {
			return fmt.Errorf("display_name must be at most %d characters", maxMacroDisplayNameLen)
		}
	}
	if desc, ok, err := optionalString(arguments, "description"); err != nil {
		return err
	} else if ok {
		provided = true
		if len(desc) > maxMacroDescriptionLen {
			return fmt.Errorf("description must be at most %d characters", maxMacroDescriptionLen)
		}
	}
	if _, ok := arguments["actions"]; ok {
		provided = true
		rawActions, ok := arguments["actions"].([]any)
		if !ok {
			return fmt.Errorf("actions must be an array")
		}
		if len(rawActions) == 0 {
			return fmt.Errorf("actions must contain at least one action")
		}
	}
	if _, ok := arguments["tags"]; ok {
		provided = true
		if err := validateMacroTags(arguments["tags"]); err != nil {
			return err
		}
	}
	if !provided {
		return fmt.Errorf("at least one of display_name, description, actions, or tags must be provided to update")
	}
	return nil
}

// validateMacroResourceInput validates that a required "macro" parameter is a
// non-empty macros/{id} resource name. Used by get_macro, delete_macro, and
// execute_macro.
func validateMacroResourceInput(arguments map[string]any) error {
	macro, err := requiredString(arguments, "macro")
	if err != nil {
		return err
	}
	if !strings.HasPrefix(macro, "macros/") {
		return fmt.Errorf("macro resource name must start with macros/ (use list_macros to find valid names)")
	}
	return nil
}

// validateMacroTags enforces per-tag length and total tag count limits.
func validateMacroTags(raw any) error {
	if raw == nil {
		return nil // tags are optional
	}
	tags, ok := raw.([]any)
	if !ok {
		return fmt.Errorf("tags must be an array of strings")
	}
	if len(tags) > maxMacroTags {
		return fmt.Errorf("tags must contain at most %d entries", maxMacroTags)
	}
	for index, t := range tags {
		tag, ok := t.(string)
		if !ok {
			return fmt.Errorf("tags[%d] must be a string", index)
		}
		if tag == "" {
			return fmt.Errorf("tags[%d] must be non-empty", index)
		}
		if len(tag) > maxMacroTagLen {
			return fmt.Errorf("tags[%d] must be at most %d characters", index, maxMacroTagLen)
		}
	}
	return nil
}

// requiredString extracts and validates a required string parameter.
func requiredString(arguments map[string]any, key string) (string, error) {
	v, ok := arguments[key]
	if !ok || v == nil {
		return "", fmt.Errorf("%s parameter is required", key)
	}
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("%s must be a string", key)
	}
	if s == "" {
		return "", fmt.Errorf("%s must be non-empty", key)
	}
	return s, nil
}

// optionalString extracts an optional string parameter. Returns (value, ok, err):
// ok is false when absent, true when present; err is non-nil only on a present
// but non-string value.
func optionalString(arguments map[string]any, key string) (string, bool, error) {
	v, ok := arguments[key]
	if !ok || v == nil {
		return "", false, nil
	}
	s, ok := v.(string)
	if !ok {
		return "", true, fmt.Errorf("%s must be a string", key)
	}
	return s, true, nil
}

// handleListMacros lists all macros with optional pagination.
func (s *MCPServer) handleListMacros(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	resp, err := s.client.ListMacros(ctx, &pb.ListMacrosRequest{
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return grpcErrorResult(err, "list_macros"), nil
	}

	result, _ := json.Marshal(map[string]any{
		"macros":          macroListToMaps(resp.Macros),
		"next_page_token": resp.NextPageToken,
	})
	return textResult(string(result)), nil
}

// handleGetMacro retrieves a single macro by resource name.
func (s *MCPServer) handleGetMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Macro string `json:"macro"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.Macro == "" {
		return errorResult("macro resource name is required"), nil
	}
	if !strings.HasPrefix(params.Macro, "macros/") {
		return errorResult("macro resource name must start with macros/"), nil
	}

	resp, err := s.client.GetMacro(ctx, &pb.GetMacroRequest{Name: params.Macro})
	if err != nil {
		return grpcErrorResult(err, "get_macro"), nil
	}

	result, _ := protojson.Marshal(resp)
	return textResult(string(result)), nil
}

// handleCreateMacro creates a new macro. Accepts proto-JSON macro body.
func (s *MCPServer) handleCreateMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	// Extract raw JSON for the macro and optional macro_id.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(call.Arguments, &raw); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	var req pb.CreateMacroRequest

	// Unmarshal macro_id if present.
	if macroIDRaw, ok := raw["macro_id"]; ok {
		var macroID string
		if err := json.Unmarshal(macroIDRaw, &macroID); err != nil {
			return errorResultf("Invalid macro_id: %v", err), nil
		}
		req.MacroId = macroID
	}

	// The macro body can be provided either as "macro" (proto-JSON object) or
	// as flat fields (display_name, description, actions, tags).
	if macroRaw, ok := raw["macro"]; ok {
		var macro pb.Macro
		if err := protojson.Unmarshal(macroRaw, &macro); err != nil {
			return errorResultf("Invalid macro body: %v", err), nil
		}
		req.Macro = &macro
	} else {
		// Flat-field path: build macro from top-level parameters.
		macro := &pb.Macro{}
		if v, ok := raw["display_name"]; ok {
			var s string
			if err := json.Unmarshal(v, &s); err != nil {
				return errorResultf("Invalid display_name: %v", err), nil
			}
			macro.DisplayName = s
		}
		if v, ok := raw["description"]; ok {
			var s string
			if err := json.Unmarshal(v, &s); err != nil {
				return errorResultf("Invalid description: %v", err), nil
			}
			macro.Description = s
		}
		if v, ok := raw["actions"]; ok {
			var rawActions []json.RawMessage
			if err := json.Unmarshal(v, &rawActions); err != nil {
				return errorResultf("Invalid actions: %v", err), nil
			}
			macro.Actions = make([]*pb.MacroAction, 0, len(rawActions))
			for i, rawAct := range rawActions {
				var action pb.MacroAction
				if err := protojson.Unmarshal(rawAct, &action); err != nil {
					return errorResultf("Invalid action[%d]: %v", i, err), nil
				}
				macro.Actions = append(macro.Actions, &action)
			}
		}
		if v, ok := raw["tags"]; ok {
			var tags []string
			if err := json.Unmarshal(v, &tags); err != nil {
				return errorResultf("Invalid tags: %v", err), nil
			}
			macro.Tags = tags
		}
		req.Macro = macro
	}

	if req.Macro == nil {
		return errorResult("macro body is required"), nil
	}
	if req.Macro.DisplayName == "" && len(raw["macro"]) > 0 {
		// Allow proto-JSON macro with display_name set inside; fall through.
		// But if flat-field and missing, reject.
		if _, hasFlat := raw["display_name"]; !hasFlat {
			return errorResult("display_name is required"), nil
		}
	}

	if len(req.Macro.Actions) == 0 {
		return errorResult("at least one action is required"), nil
	}

	resp, err := s.client.CreateMacro(ctx, &req)
	if err != nil {
		return grpcErrorResult(err, "create_macro"), nil
	}

	result, _ := protojson.Marshal(resp)
	return textResult(string(result)), nil
}

// handleUpdateMacro updates an existing macro.
func (s *MCPServer) handleUpdateMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(call.Arguments, &raw); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	var params struct {
		Macro string `json:"macro"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.Macro == "" {
		return errorResult("macro resource name is required"), nil
	}
	if !strings.HasPrefix(params.Macro, "macros/") {
		return errorResult("macro resource name must start with macros/"), nil
	}

	macro := &pb.Macro{Name: params.Macro}
	var maskPaths []string

	for _, field := range []string{"display_name", "description", "actions", "tags"} {
		if _, ok := raw[field]; !ok {
			continue
		}
		maskPaths = append(maskPaths, field)
		switch field {
		case "display_name":
			var s string
			if err := json.Unmarshal(raw[field], &s); err != nil {
				return errorResultf("Invalid display_name: %v", err), nil
			}
			macro.DisplayName = s
		case "description":
			var s string
			if err := json.Unmarshal(raw[field], &s); err != nil {
				return errorResultf("Invalid description: %v", err), nil
			}
			macro.Description = s
		case "actions":
			var rawActions []json.RawMessage
			if err := json.Unmarshal(raw[field], &rawActions); err != nil {
				return errorResultf("Invalid actions: %v", err), nil
			}
			macro.Actions = make([]*pb.MacroAction, 0, len(rawActions))
			for i, rawAct := range rawActions {
				var action pb.MacroAction
				if err := protojson.Unmarshal(rawAct, &action); err != nil {
					return errorResultf("Invalid action[%d]: %v", i, err), nil
				}
				macro.Actions = append(macro.Actions, &action)
			}
		case "tags":
			var tags []string
			if err := json.Unmarshal(raw[field], &tags); err != nil {
				return errorResultf("Invalid tags: %v", err), nil
			}
			macro.Tags = tags
		}
	}

	if len(maskPaths) == 0 {
		return errorResult("at least one field to update is required"), nil
	}

	resp, err := s.client.UpdateMacro(ctx, &pb.UpdateMacroRequest{
		Macro:      macro,
		UpdateMask: &fieldmaskpb.FieldMask{Paths: maskPaths},
	})
	if err != nil {
		return grpcErrorResult(err, "update_macro"), nil
	}

	result, _ := protojson.Marshal(resp)
	return textResult(string(result)), nil
}

// handleDeleteMacro deletes a macro.
func (s *MCPServer) handleDeleteMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Macro string `json:"macro"`
		Force bool   `json:"force"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.Macro == "" {
		return errorResult("macro resource name is required"), nil
	}
	if !strings.HasPrefix(params.Macro, "macros/") {
		return errorResult("macro resource name must start with macros/"), nil
	}

	_, err := s.client.DeleteMacro(ctx, &pb.DeleteMacroRequest{
		Name:  params.Macro,
		Force: params.Force,
	})
	if err != nil {
		return grpcErrorResult(err, "delete_macro"), nil
	}

	return textResult(`{"deleted":true}`), nil
}

// handleExecuteMacro executes a macro and returns the LRO name.
func (s *MCPServer) handleExecuteMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Macro       string `json:"macro"`
		Application string `json:"application"`
		Timeout     int32  `json:"timeout"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	if params.Macro == "" {
		return errorResult("macro resource name is required"), nil
	}
	if !strings.HasPrefix(params.Macro, "macros/") {
		return errorResult("macro resource name must start with macros/"), nil
	}

	req := &pb.ExecuteMacroRequest{Macro: params.Macro}
	if params.Application != "" {
		req.Application = params.Application
	}
	if params.Timeout > 0 {
		req.Options = &pb.ExecutionOptions{
			Timeout: float64(params.Timeout),
		}
	}

	resp, err := s.client.ExecuteMacro(ctx, req)
	if err != nil {
		return grpcErrorResult(err, "execute_macro"), nil
	}

	result, _ := json.Marshal(map[string]any{
		"operation": resp.Name,
		"done":      resp.Done,
	})
	return textResult(string(result)), nil
}

// macroListToMaps converts a slice of proto Macros to a slice of maps.
func macroListToMaps(macros []*pb.Macro) []map[string]any {
	result := make([]map[string]any, 0, len(macros))
	for _, m := range macros {
		result = append(result, macroToMap(m))
	}
	return result
}

// macroToMap converts a proto Macro to a map for JSON serialization.
func macroToMap(m *pb.Macro) map[string]any {
	if m == nil {
		return nil
	}
	actions := make([]map[string]any, 0, len(m.Actions))
	for _, a := range m.Actions {
		actions = append(actions, macroActionToMap(a))
	}
	result := map[string]any{
		"name":            m.Name,
		"display_name":    m.DisplayName,
		"description":     m.Description,
		"execution_count": m.ExecutionCount,
		"tags":            m.Tags,
		"actions":         actions,
	}
	if m.CreateTime != nil {
		result["create_time"] = m.CreateTime.AsTime().UTC().Format(time.RFC3339)
	}
	if m.UpdateTime != nil {
		result["update_time"] = m.UpdateTime.AsTime().UTC().Format(time.RFC3339)
	}
	return result
}

// macroActionToMap converts a proto MacroAction to a map.
func macroActionToMap(a *pb.MacroAction) map[string]any {
	m := map[string]any{
		"description": a.Description,
	}
	// Serialize the oneof action via protojson for readability.
	if actionBytes, err := protojson.Marshal(a); err == nil {
		var actionMap map[string]any
		if json.Unmarshal(actionBytes, &actionMap) == nil {
			for k, v := range actionMap {
				if k != "description" {
					m[k] = v
				}
			}
		}
	}
	return m
}
