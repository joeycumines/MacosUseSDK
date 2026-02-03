// Copyright 2025 Joseph Cumines
//
// Scripting tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/protobuf/types/known/durationpb"
)

// defaultScriptTimeout is the default timeout for script execution in seconds.
const defaultScriptTimeout = 30

// handleExecuteAppleScript handles the execute_apple_script tool
func (s *MCPServer) handleExecuteAppleScript(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Script  string `json:"script"`
		Timeout int32  `json:"timeout"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Script == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "script parameter is required"}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = defaultScriptTimeout
	}

	resp, err := s.client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script:  params.Script,
		Timeout: durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to execute AppleScript: %v", err)}},
		}, nil
	}

	if !resp.Success || resp.Error != "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("AppleScript execution failed: %s", resp.Error)}},
		}, nil
	}

	if resp.Output == "" {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "Script executed (no output)"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("AppleScript result: %s", resp.Output)}},
	}, nil
}

// handleExecuteJavaScript handles the execute_javascript tool
func (s *MCPServer) handleExecuteJavaScript(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Script  string `json:"script"`
		Timeout int32  `json:"timeout"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Script == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "script parameter is required"}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = defaultScriptTimeout
	}

	resp, err := s.client.ExecuteJavaScript(ctx, &pb.ExecuteJavaScriptRequest{
		Script:  params.Script,
		Timeout: durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to execute JavaScript: %v", err)}},
		}, nil
	}

	if !resp.Success || resp.Error != "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("JavaScript execution failed: %s", resp.Error)}},
		}, nil
	}

	if resp.Output == "" {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "Script executed (no output)"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("JavaScript result: %s", resp.Output)}},
	}, nil
}

// handleExecuteShellCommand handles the execute_shell_command tool.
//
// SECURITY: This handler executes arbitrary shell commands.
// It is disabled by default and requires MCP_SHELL_COMMANDS_ENABLED=true to enable.
func (s *MCPServer) handleExecuteShellCommand(call *ToolCall) (*ToolResult, error) {
	// Security check: shell commands must be explicitly enabled
	if !s.cfg.ShellCommandsEnabled {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Shell command execution is disabled. Set MCP_SHELL_COMMANDS_ENABLED=true to enable."}},
		}, nil
	}

	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Command          string   `json:"command"`
		WorkingDirectory string   `json:"working_directory"`
		Args             []string `json:"args"`
		Timeout          int32    `json:"timeout"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Command == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "command parameter is required"}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = defaultScriptTimeout
	}

	resp, err := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
		Command:          params.Command,
		Args:             params.Args,
		WorkingDirectory: params.WorkingDirectory,
		Timeout:          durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to execute shell command: %v", err)}},
		}, nil
	}

	// Check for execution error (not command failure)
	if resp.Error != "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Shell command failed: %s", resp.Error)}},
		}, nil
	}

	output := resp.Stdout
	if resp.Stderr != "" {
		if output != "" {
			output += "\n\nSTDERR:\n" + resp.Stderr
		} else {
			output = "STDERR:\n" + resp.Stderr
		}
	}

	if resp.ExitCode != 0 {
		return &ToolResult{
			IsError: true,
			Content: []Content{{
				Type: "text",
				Text: fmt.Sprintf("Command exited with code %d\n%s", resp.ExitCode, output),
			}},
		}, nil
	}

	if output == "" {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "Command executed (no output)"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: output}},
	}, nil
}

// handleValidateScript handles the validate_script tool
func (s *MCPServer) handleValidateScript(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Type   string `json:"type"`
		Script string `json:"script"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Type == "" || params.Script == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "type and script parameters are required"}},
		}, nil
	}

	// Map type string to proto enum
	var scriptType pb.ScriptType
	switch params.Type {
	case "applescript":
		scriptType = pb.ScriptType_SCRIPT_TYPE_APPLESCRIPT
	case "javascript":
		scriptType = pb.ScriptType_SCRIPT_TYPE_JXA
	case "shell":
		scriptType = pb.ScriptType_SCRIPT_TYPE_SHELL
	default:
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Unknown script type: %s. Valid: applescript, javascript, shell", params.Type)}},
		}, nil
	}

	resp, err := s.client.ValidateScript(ctx, &pb.ValidateScriptRequest{
		Type:   scriptType,
		Script: params.Script,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to validate script: %v", err)}},
		}, nil
	}

	if resp.Valid {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Script validation successful (%s)", params.Type)}},
		}, nil
	}

	// Build error message from errors array
	var errMsg string
	if len(resp.Errors) > 0 {
		errMsg = strings.Join(resp.Errors, "; ")
	}

	return &ToolResult{
		IsError: true,
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Script validation failed: %s", errMsg)}},
	}, nil
}
