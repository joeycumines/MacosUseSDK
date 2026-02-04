// Copyright 2025 Joseph Cumines
//
// Session and macro tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleCreateSession handles the create_session tool
func (s *MCPServer) handleCreateSession(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Metadata    map[string]string `json:"metadata"`
		SessionID   string            `json:"session_id"`
		DisplayName string            `json:"display_name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	session := &pb.Session{
		DisplayName: params.DisplayName,
		Metadata:    params.Metadata,
	}

	resp, err := s.client.CreateSession(ctx, &pb.CreateSessionRequest{
		Session:   session,
		SessionId: params.SessionID,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to create session: %v", err)}},
		}, nil
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"name":         resp.Name,
		"display_name": resp.DisplayName,
		"state":        resp.State.String(),
		"create_time":  resp.CreateTime.AsTime().Format(time.RFC3339),
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleGetSession handles the get_session tool
func (s *MCPServer) handleGetSession(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	resp, err := s.client.GetSession(ctx, &pb.GetSessionRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get session: %v", err)}},
		}, nil
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"name":             resp.Name,
		"display_name":     resp.DisplayName,
		"state":            resp.State.String(),
		"create_time":      resp.CreateTime.AsTime().Format(time.RFC3339),
		"last_access_time": resp.LastAccessTime.AsTime().Format(time.RFC3339),
		"transaction_id":   resp.TransactionId,
		"metadata":         resp.Metadata,
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleListSessions handles the list_sessions tool
func (s *MCPServer) handleListSessions(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		PageToken string `json:"page_token"`
		PageSize  int32  `json:"page_size"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	resp, err := s.client.ListSessions(ctx, &pb.ListSessionsRequest{
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list sessions: %v", err)}},
		}, nil
	}

	sessions := make([]map[string]interface{}, 0, len(resp.Sessions))
	for _, sess := range resp.Sessions {
		sessions = append(sessions, map[string]interface{}{
			"name":         sess.Name,
			"display_name": sess.DisplayName,
			"state":        sess.State.String(),
		})
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"sessions":        sessions,
		"next_page_token": resp.NextPageToken,
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleDeleteSession handles the delete_session tool
func (s *MCPServer) handleDeleteSession(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name  string `json:"name"`
		Force bool   `json:"force"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	_, err := s.client.DeleteSession(ctx, &pb.DeleteSessionRequest{
		Name:  params.Name,
		Force: params.Force,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to delete session: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Deleted session: %s", params.Name)}},
	}, nil
}

// handleGetSessionSnapshot handles the get_session_snapshot tool
func (s *MCPServer) handleGetSessionSnapshot(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	resp, err := s.client.GetSessionSnapshot(ctx, &pb.GetSessionSnapshotRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get session snapshot: %v", err)}},
		}, nil
	}

	history := make([]map[string]interface{}, 0, len(resp.History))
	for _, record := range resp.History {
		history = append(history, map[string]interface{}{
			"operation_type": record.OperationType,
			"resource":       record.Resource,
			"success":        record.Success,
			"error":          record.Error,
		})
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"session": map[string]interface{}{
			"name":  resp.Session.GetName(),
			"state": resp.Session.GetState().String(),
		},
		"applications": resp.Applications,
		"observations": resp.Observations,
		"history":      history,
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleBeginTransaction handles the begin_transaction tool
func (s *MCPServer) handleBeginTransaction(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Session string `json:"session"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Session == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "session parameter is required"}},
		}, nil
	}

	resp, err := s.client.BeginTransaction(ctx, &pb.BeginTransactionRequest{Session: params.Session})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to begin transaction: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Transaction started. ID: %s", resp.TransactionId),
		}},
	}, nil
}

// handleCommitTransaction handles the commit_transaction tool
func (s *MCPServer) handleCommitTransaction(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name          string `json:"name"`
		TransactionID string `json:"transaction_id"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" || params.TransactionID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name and transaction_id parameters are required"}},
		}, nil
	}

	resp, err := s.client.CommitTransaction(ctx, &pb.CommitTransactionRequest{
		Name:          params.Name,
		TransactionId: params.TransactionID,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to commit transaction: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Transaction %s committed. State: %s, Operations: %d",
				resp.TransactionId, resp.State.String(), resp.OperationsCount),
		}},
	}, nil
}

// handleRollbackTransaction handles the rollback_transaction tool
func (s *MCPServer) handleRollbackTransaction(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name          string `json:"name"`
		TransactionID string `json:"transaction_id"`
		RevisionID    string `json:"revision_id"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" || params.TransactionID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name and transaction_id parameters are required"}},
		}, nil
	}

	resp, err := s.client.RollbackTransaction(ctx, &pb.RollbackTransactionRequest{
		Name:          params.Name,
		TransactionId: params.TransactionID,
		RevisionId:    params.RevisionID,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to rollback transaction: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Transaction %s rolled back. State: %s", resp.TransactionId, resp.State.String()),
		}},
	}, nil
}

// handleCreateMacro handles the create_macro tool
func (s *MCPServer) handleCreateMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		MacroID     string   `json:"macro_id"`
		DisplayName string   `json:"display_name"`
		Description string   `json:"description"`
		Tags        []string `json:"tags"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.DisplayName == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "display_name parameter is required"}},
		}, nil
	}

	macro := &pb.Macro{
		DisplayName: params.DisplayName,
		Description: params.Description,
		Tags:        params.Tags,
		Actions:     []*pb.MacroAction{}, // Empty initially
	}

	resp, err := s.client.CreateMacro(ctx, &pb.CreateMacroRequest{
		Macro:   macro,
		MacroId: params.MacroID,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to create macro: %v", err)}},
		}, nil
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"name":         resp.Name,
		"display_name": resp.DisplayName,
		"description":  resp.Description,
		"tags":         resp.Tags,
		"create_time":  resp.CreateTime.AsTime().Format(time.RFC3339),
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleGetMacro handles the get_macro tool
func (s *MCPServer) handleGetMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	resp, err := s.client.GetMacro(ctx, &pb.GetMacroRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get macro: %v", err)}},
		}, nil
	}

	actions := make([]string, 0, len(resp.Actions))
	for _, action := range resp.Actions {
		actions = append(actions, action.GetDescription())
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"name":            resp.Name,
		"display_name":    resp.DisplayName,
		"description":     resp.Description,
		"action_count":    len(resp.Actions),
		"actions":         actions,
		"tags":            resp.Tags,
		"execution_count": resp.ExecutionCount,
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleListMacros handles the list_macros tool
func (s *MCPServer) handleListMacros(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		PageToken string `json:"page_token"`
		PageSize  int32  `json:"page_size"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	resp, err := s.client.ListMacros(ctx, &pb.ListMacrosRequest{
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list macros: %v", err)}},
		}, nil
	}

	macros := make([]map[string]interface{}, 0, len(resp.Macros))
	for _, m := range resp.Macros {
		macros = append(macros, map[string]interface{}{
			"name":            m.Name,
			"display_name":    m.DisplayName,
			"action_count":    len(m.Actions),
			"execution_count": m.ExecutionCount,
		})
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"macros":          macros,
		"next_page_token": resp.NextPageToken,
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleDeleteMacro handles the delete_macro tool
func (s *MCPServer) handleDeleteMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	_, err := s.client.DeleteMacro(ctx, &pb.DeleteMacroRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to delete macro: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Deleted macro: %s", params.Name)}},
	}, nil
}

// handleUpdateMacro handles the update_macro tool
func (s *MCPServer) handleUpdateMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name        string   `json:"name"`
		DisplayName string   `json:"display_name"`
		Description string   `json:"description"`
		Tags        []string `json:"tags"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	macro := &pb.Macro{
		Name:        params.Name,
		DisplayName: params.DisplayName,
		Description: params.Description,
		Tags:        params.Tags,
	}

	resp, err := s.client.UpdateMacro(ctx, &pb.UpdateMacroRequest{Macro: macro})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to update macro: %v", err)}},
		}, nil
	}

	data, _ := json.MarshalIndent(map[string]interface{}{
		"name":         resp.Name,
		"display_name": resp.DisplayName,
		"description":  resp.Description,
		"tags":         resp.Tags,
		"update_time":  resp.UpdateTime.AsTime().Format(time.RFC3339),
	}, "", "  ")

	return &ToolResult{
		Content: []Content{{Type: "text", Text: string(data)}},
	}, nil
}

// handleExecuteMacro handles the execute_macro tool
func (s *MCPServer) handleExecuteMacro(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		ParameterValues map[string]string `json:"parameter_values"`
		Macro           string            `json:"macro"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Macro == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "macro parameter is required"}},
		}, nil
	}

	resp, err := s.client.ExecuteMacro(ctx, &pb.ExecuteMacroRequest{
		Macro:           params.Macro,
		ParameterValues: params.ParameterValues,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to execute macro: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Macro execution started. Operation: %s, Done: %v", resp.Name, resp.Done),
		}},
	}, nil
}
