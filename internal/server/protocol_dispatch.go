// Copyright 2026 Joseph Cumines

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

// handleHTTPMessage executes a JSON-RPC message through the single production
// dispatcher. Notifications are executed but never produce a response.
func (s *MCPServer) handleHTTPMessage(msg *transport.Message) (*transport.Message, error) {
	prepared, response := s.prepareMCPMessage(msg)
	if prepared == nil {
		return response, nil
	}
	return s.executePreparedMCPMessage(prepared)
}

// handleStdioMessage writes the shared dispatcher result to the stdio
// transport. HTTP and stdio therefore cannot drift onto separate registries,
// validation, dispatch, serialization, or notification behavior.
func (s *MCPServer) handleStdioMessage(tr *transport.StdioTransport, msg *transport.Message) {
	response, err := s.handleHTTPMessage(msg)
	s.writeStdioDispatchResult(tr, msg.ID, response, err)
}

func (s *MCPServer) handlePreparedStdioMessage(tr *transport.StdioTransport, prepared *preparedMCPMessage) {
	response, err := s.executePreparedMCPMessage(prepared)
	s.writeStdioDispatchResult(tr, prepared.message.ID, response, err)
}

func (s *MCPServer) writeStdioDispatchResult(
	tr *transport.StdioTransport,
	id json.RawMessage,
	response *transport.Message,
	err error,
) {
	if err != nil {
		if errors.Is(err, transport.ErrRequestCancelled) {
			return
		}
		response = &transport.Message{
			JSONRPC: "2.0",
			ID:      id,
			Error: &transport.ErrorObj{
				Code:    transport.ErrCodeInternalError,
				Message: err.Error(),
			},
		}
	}
	if response == nil {
		return
	}
	if err := tr.WriteMessage(response); err != nil {
		log.Printf("Error writing response: %v", err)
	}
}

// handleMessage remains as a package-local compatibility entry point for
// focused tests. Production stdio calls handleStdioMessage directly.
func (s *MCPServer) handleMessage(tr *transport.StdioTransport, msg *transport.Message) {
	s.handleStdioMessage(tr, msg)
}

func isJSONRPCNotification(msg *transport.Message) bool {
	if msg == nil {
		return false
	}
	id := bytes.TrimSpace(msg.ID)
	return len(id) == 0
}

// validateAndProcessInitialize validates initialize params and returns the response or an error.
// This is shared between HTTP and stdio transports for consistency.
func (s *MCPServer) validateAndProcessInitialize(msg *transport.Message) (*transport.Message, error) {
	invalidParams := func(message string) (*transport.Message, error) {
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &transport.ErrorObj{
				Code:    transport.ErrCodeInvalidParams,
				Message: message,
			},
		}, nil
	}

	if len(bytes.TrimSpace(msg.Params)) == 0 {
		return invalidParams("invalid initialize params: params are required")
	}

	var params MCPInitializeParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return invalidParams(fmt.Sprintf("invalid initialize params: %v", err))
	}
	if params.ProtocolVersion == "" {
		return invalidParams("invalid initialize params: protocolVersion is required")
	}
	if params.Capabilities == nil {
		return invalidParams("invalid initialize params: capabilities must be an object")
	}
	if params.ClientInfo == nil {
		return invalidParams("invalid initialize params: clientInfo is required")
	}
	if strings.TrimSpace(params.ClientInfo.Name) == "" {
		return invalidParams("invalid initialize params: clientInfo.name is required")
	}
	if strings.TrimSpace(params.ClientInfo.Version) == "" {
		return invalidParams("invalid initialize params: clientInfo.version is required")
	}

	// Validate and normalize protocol version per MCP 2025-11-25 lifecycle.
	// The client sends the latest version it supports. If the server does not
	// support that exact version, it MUST respond with another version it does
	// support. The client is then responsible for disconnecting if unsupported.
	protocolVersion := params.ProtocolVersion
	if protocolVersion != mcpProtocolVersionCurrent {
		if protocolVersion == "" {
			log.Printf("WARN: MCP client did not specify protocolVersion, defaulting to %s", mcpProtocolVersionCurrent)
		} else {
			log.Printf("WARN: MCP client requested unsupported protocol version %s, responding with %s", protocolVersion, mcpProtocolVersionCurrent)
		}
		protocolVersion = mcpProtocolVersionCurrent
	}

	// Log client info
	clientName := params.ClientInfo.Name
	clientVersion := params.ClientInfo.Version
	log.Printf("INFO: MCP client connected: %s v%s (protocol: %s)", clientName, clientVersion, protocolVersion)

	// Get display information for grounding
	displayInfo := s.getDisplayGroundingInfo()

	// Build and return the response
	result, err := json.Marshal(map[string]any{
		"protocolVersion": protocolVersion,
		"capabilities": map[string]any{
			"tools":     map[string]any{},
			"resources": map[string]any{"subscribe": false, "listChanged": false},
			"prompts":   map[string]any{},
		},
		"serverInfo":  map[string]any{"name": "macos-use-sdk", "version": "0.1.0"},
		"displayInfo": json.RawMessage(displayInfo),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to marshal initialize response: %w", err)
	}
	return &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Result:  result,
	}, nil
}

// handleHTTPMessage handles a single MCP message from HTTP transport
func (s *MCPServer) dispatchMCPMessage(msg *transport.Message) (*transport.Message, error) {
	// Handle initialize request
	if msg.Method == "initialize" {
		return s.validateAndProcessInitialize(msg)
	}

	// Handle notifications/initialized - client acknowledgment of successful initialization
	// Per MCP spec: clients send this notification after receiving initialize response
	if msg.Method == "notifications/initialized" {
		// This is a notification, no response required
		return nil, nil
	}

	// Handle ping request.
	// Per MCP 2025-11-25 basic/utilities/ping: both parties MUST respond promptly
	// with an empty result.
	if msg.Method == "ping" {
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  []byte(`{}`),
		}, nil
	}

	// Handle list_tools request
	if msg.Method == "tools/list" {
		s.mu.RLock()
		tools := make([]map[string]any, 0, len(s.tools))
		for _, tool := range s.tools {
			tools = append(tools, map[string]any{
				"name":        tool.Name,
				"description": tool.Description,
				"inputSchema": tool.InputSchema,
				"annotations": tool.mcpAnnotations(),
			})
		}
		s.mu.RUnlock()
		sort.Slice(tools, func(i, j int) bool {
			return tools[i]["name"].(string) < tools[j]["name"].(string)
		})

		result, err := json.Marshal(map[string]any{"tools": tools})
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: "failed to marshal tools list",
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle resources/list request
	if msg.Method == "resources/list" {
		resources := []map[string]any{
			{
				"uri":         "screen://main",
				"name":        "Main Display Screenshot",
				"description": "Current screenshot of the main display",
				"mimeType":    "image/png",
			},
			{
				"uri":         "accessibility://",
				"name":        "Accessibility Tree Template",
				"description": "Use accessibility://{pid} to get element tree for an application",
				"mimeType":    "application/json",
			},
			{
				"uri":         "clipboard://current",
				"name":        "Current Clipboard",
				"description": "Current clipboard contents as text",
				"mimeType":    "text/plain",
			},
		}
		result, err := json.Marshal(map[string]any{"resources": resources})
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle resources/read request
	if msg.Method == "resources/read" {
		var params struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("invalid params: %v", err),
				},
			}, nil
		}

		contents, err := s.readResource(msg.Context, params.URI)
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: err.Error(),
				},
			}, nil
		}

		result, err := json.Marshal(map[string]any{"contents": contents})
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle prompts/list request
	if msg.Method == "prompts/list" {
		prompts := s.listPrompts()
		result, err := json.Marshal(map[string]any{"prompts": prompts})
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle prompts/get request
	if msg.Method == "prompts/get" {
		var params struct {
			Arguments map[string]any `json:"arguments"`
			Name      string         `json:"name"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("invalid params: %v", err),
				},
			}, nil
		}

		prompt, err := s.getPrompt(params.Name, params.Arguments)
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams, // Unknown prompt name is invalid params per MCP spec
					Message: err.Error(),
				},
			}, nil
		}

		result, err := json.Marshal(prompt)
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle tool call
	if msg.Method == "tools/call" {
		params, decodeErr := decodeToolCallParams(msg.Params)
		if decodeErr != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("Invalid params: %v", decodeErr),
				},
			}, nil
		}

		s.mu.RLock()
		tool, ok := s.tools[params.Name]
		s.mu.RUnlock()

		if !ok {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeMethodNotFound,
					Message: fmt.Sprintf("Tool not found: %s", params.Name),
				},
			}, nil
		}

		// Validate tool input against schema before calling handler
		args, decodeErr := decodeToolArguments(params.Arguments)
		if decodeErr != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("Invalid arguments JSON: %v", decodeErr),
				},
			}, nil
		}

		s.mu.RLock()
		validationErr := validateToolInput(params.Name, args, s.tools)
		s.mu.RUnlock()
		if validationErr != nil {
			validationErr.ID = msg.ID
			return validationErr, nil
		}

		callCtx, cancelCall := s.newToolCallContext(msg.Context)
		defer cancelCall()
		call := &ToolCall{
			Context:   callCtx,
			Name:      params.Name,
			Arguments: params.Arguments,
		}

		// Track start time for metrics
		startTime := time.Now()

		var result *ToolResult
		var err error
		if tool.requiresExclusiveMutation(params.Arguments) {
			result, err = s.physicalDesktopMutations().execute(callCtx, func() (*ToolResult, error) {
				return tool.Handler(call)
			})
			switch {
			case errors.Is(err, errMutationQueueFull):
				result = errorResult("physical desktop mutation queue is full; retry after another mutation completes")
				err = nil
			case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
				result = errorResultf("physical desktop mutation was not completed: %v", err)
				err = nil
			}
		} else {
			result, err = tool.Handler(call)
		}

		// Calculate duration
		duration := time.Since(startTime)

		// Determine status and record metrics
		status := "ok"
		if err != nil {
			status = "error"
		} else if result != nil && result.IsError {
			status = "error"
		}

		// Record metrics if HTTP transport is available
		s.mu.RLock()
		httpTransport := s.httpTransport
		s.mu.RUnlock()
		if httpTransport != nil {
			httpTransport.Metrics().RecordRequest(params.Name, status, duration)
		}

		// Record audit log
		if s.auditLogger != nil {
			if auditErr := s.auditLogger.LogToolCall(params.Name, params.Arguments, status, duration); auditErr != nil {
				// The tool may already have changed macOS state, so replacing its
				// truthful result with an audit error would invite an unsafe retry.
				// Surface the operational failure without misreporting tool behavior.
				log.Printf("Error writing non-content audit metadata: %v", auditErr)
			}
		}

		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: err.Error(),
				},
			}, nil
		}

		resultJSON, err := json.Marshal(result)
		if err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: "failed to marshal tool result",
				},
			}, nil
		}
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  resultJSON,
		}, nil
	}

	// Unknown method.
	// Notifications (messages without an ID) MUST NOT receive a response.
	if len(msg.ID) == 0 {
		return nil, nil
	}

	return &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Error: &transport.ErrorObj{
			Code:    transport.ErrCodeMethodNotFound,
			Message: fmt.Sprintf("Method not found: %s", msg.Method),
		},
	}, nil
}
