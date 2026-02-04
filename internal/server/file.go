// Copyright 2025 Joseph Cumines
//
// File dialog tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleAutomateOpenFileDialog handles the automate_open_file_dialog tool
func (s *MCPServer) handleAutomateOpenFileDialog(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Application      string   `json:"application"`
		FilePath         string   `json:"file_path"`
		DefaultDirectory string   `json:"default_directory"`
		FileFilters      []string `json:"file_filters"`
		Timeout          float64  `json:"timeout"`
		AllowMultiple    bool     `json:"allow_multiple"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Application == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "application parameter is required"}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = 30.0
	}

	resp, err := s.client.AutomateOpenFileDialog(ctx, &pb.AutomateOpenFileDialogRequest{
		Application:      params.Application,
		FilePath:         params.FilePath,
		DefaultDirectory: params.DefaultDirectory,
		FileFilters:      params.FileFilters,
		Timeout:          timeout,
		AllowMultiple:    params.AllowMultiple,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to automate open file dialog: %v", err)}},
		}, nil
	}

	if !resp.Success {
		errMsg := resp.Error
		if errMsg == "" {
			errMsg = "operation was not successful"
		}
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Open file dialog automation failed: %s", errMsg)}},
		}, nil
	}

	if len(resp.SelectedPaths) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "Dialog completed but no files were selected"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Selected files:\n%s", strings.Join(resp.SelectedPaths, "\n")),
		}},
	}, nil
}

// handleAutomateSaveFileDialog handles the automate_save_file_dialog tool
func (s *MCPServer) handleAutomateSaveFileDialog(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Application      string  `json:"application"`
		FilePath         string  `json:"file_path"`
		DefaultDirectory string  `json:"default_directory"`
		DefaultFilename  string  `json:"default_filename"`
		Timeout          float64 `json:"timeout"`
		ConfirmOverwrite bool    `json:"confirm_overwrite"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Application == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "application parameter is required"}},
		}, nil
	}

	if params.FilePath == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "file_path parameter is required"}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = 30.0
	}

	resp, err := s.client.AutomateSaveFileDialog(ctx, &pb.AutomateSaveFileDialogRequest{
		Application:      params.Application,
		FilePath:         params.FilePath,
		DefaultDirectory: params.DefaultDirectory,
		DefaultFilename:  params.DefaultFilename,
		Timeout:          timeout,
		ConfirmOverwrite: params.ConfirmOverwrite,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to automate save file dialog: %v", err)}},
		}, nil
	}

	if !resp.Success {
		errMsg := resp.Error
		if errMsg == "" {
			errMsg = "operation was not successful"
		}
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Save file dialog automation failed: %s", errMsg)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("File saved to: %s", resp.SavedPath),
		}},
	}, nil
}

// handleSelectFile handles the select_file tool
func (s *MCPServer) handleSelectFile(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Application  string `json:"application"`
		FilePath     string `json:"file_path"`
		RevealFinder bool   `json:"reveal_finder"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Application == "" || params.FilePath == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "application and file_path parameters are required"}},
		}, nil
	}

	resp, err := s.client.SelectFile(ctx, &pb.SelectFileRequest{
		Application:  params.Application,
		FilePath:     params.FilePath,
		RevealFinder: params.RevealFinder,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to select file: %v", err)}},
		}, nil
	}

	if !resp.Success {
		errMsg := resp.Error
		if errMsg == "" {
			errMsg = "operation was not successful"
		}
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("File selection failed: %s", errMsg)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Selected file: %s", resp.SelectedPath),
		}},
	}, nil
}

// handleSelectDirectory handles the select_directory tool
func (s *MCPServer) handleSelectDirectory(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Application   string `json:"application"`
		DirectoryPath string `json:"directory_path"`
		CreateMissing bool   `json:"create_missing"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Application == "" || params.DirectoryPath == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "application and directory_path parameters are required"}},
		}, nil
	}

	resp, err := s.client.SelectDirectory(ctx, &pb.SelectDirectoryRequest{
		Application:   params.Application,
		DirectoryPath: params.DirectoryPath,
		CreateMissing: params.CreateMissing,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to select directory: %v", err)}},
		}, nil
	}

	if !resp.Success {
		errMsg := resp.Error
		if errMsg == "" {
			errMsg = "operation was not successful"
		}
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Directory selection failed: %s", errMsg)}},
		}, nil
	}

	msg := fmt.Sprintf("Selected directory: %s", resp.SelectedPath)
	if resp.Created {
		msg += " (created)"
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: msg}},
	}, nil
}

// handleDragFiles handles the drag_files tool
func (s *MCPServer) handleDragFiles(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Application     string   `json:"application"`
		TargetElementID string   `json:"target_element_id"`
		FilePaths       []string `json:"file_paths"`
		Duration        float64  `json:"duration"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Application == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "application parameter is required"}},
		}, nil
	}

	if len(params.FilePaths) == 0 {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "file_paths parameter must contain at least one path"}},
		}, nil
	}

	if params.TargetElementID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "target_element_id parameter is required"}},
		}, nil
	}

	resp, err := s.client.DragFiles(ctx, &pb.DragFilesRequest{
		Application:     params.Application,
		FilePaths:       params.FilePaths,
		TargetElementId: params.TargetElementID,
		Duration:        params.Duration,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to drag files: %v", err)}},
		}, nil
	}

	if !resp.Success {
		errMsg := resp.Error
		if errMsg == "" {
			errMsg = "operation was not successful"
		}
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("File drag failed: %s", errMsg)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Dropped %d files onto element %s", resp.FilesDropped, params.TargetElementID),
		}},
	}, nil
}
