// Copyright 2025 Joseph Cumines
//
// MCP server implementation

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"sync"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// MCPServer represents an MCP server
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type MCPServer struct {
	client    pb.MacosUseClient
	opsClient longrunningpb.OperationsClient
	ctx       context.Context
	cfg       *config.Config
	conn      *grpc.ClientConn
	tools     map[string]*Tool
	cancel    context.CancelFunc
	mu        sync.RWMutex
}

// Tool represents an MCP tool
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Tool struct {
	Handler     func(*ToolCall) (*ToolResult, error)
	InputSchema map[string]interface{}
	Name        string
	Description string
}

// ToolCall represents a tool call request
type ToolCall struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// ToolResult represents a tool call result
type ToolResult struct {
	Content []Content `json:"content"`
	IsError bool      `json:"isError,omitempty"`
}

// Content represents a content item in a tool result
type Content struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// NewMCPServer creates a new MCP server
func NewMCPServer(cfg *config.Config) (*MCPServer, error) {
	ctx, cancel := context.WithCancel(context.Background())

	s := &MCPServer{
		cfg:    cfg,
		ctx:    ctx,
		cancel: cancel,
		tools:  make(map[string]*Tool),
	}

	// Initialize gRPC connection
	if err := s.initGRPC(); err != nil {
		cancel()
		return nil, fmt.Errorf("failed to initialize gRPC: %w", err)
	}

	// Register tools
	s.registerTools()

	return s, nil
}

// initGRPC initializes the gRPC connection
func (s *MCPServer) initGRPC() error {
	var opts []grpc.DialOption

	if s.cfg.ServerTLS {
		creds := credentials.NewTLS(nil)
		if s.cfg.ServerCertFile != "" {
			var err error
			creds, err = credentials.NewClientTLSFromFile(s.cfg.ServerCertFile, "")
			if err != nil {
				return fmt.Errorf("failed to load TLS cert: %w", err)
			}
		}
		opts = append(opts, grpc.WithTransportCredentials(creds))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.NewClient(s.cfg.ServerAddr, opts...)
	if err != nil {
		return fmt.Errorf("failed to create client: %w", err)
	}

	s.conn = conn
	s.client = pb.NewMacosUseClient(conn)
	s.opsClient = longrunningpb.NewOperationsClient(conn)

	return nil
}

// Shutdown gracefully shuts down the server
func (s *MCPServer) Shutdown() {
	s.conn.Close()
	if s.conn != nil {
		s.cancel()
		log.Println("Shutting down MCP server...")
	}
}

// registerTools registers all available tools
func (s *MCPServer) registerTools() {
	s.tools = map[string]*Tool{
		"find_elements": {
			Name:        "find_elements",
			Description: "Find UI elements by criteria",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent element ID to search within",
					},
					"selector": map[string]interface{}{
						"type":        "object",
						"description": "Criteria to match elements (role, title, etc.)",
					},
				},
			},
			Handler: s.handleFindElements,
		},
		"list_windows": {
			Name:        "list_windows",
			Description: "List all open windows",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleListWindows,
		},
		"list_displays": {
			Name:        "list_displays",
			Description: "List all connected displays",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleListDisplays,
		},
		"get_display": {
			Name:        "get_display",
			Description: "Get details of a specific display",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"display_id": map[string]interface{}{
						"type":        "string",
						"description": "ID of the display to retrieve",
					},
				},
				"required": []string{"display_id"},
			},
			Handler: s.handleGetDisplay,
		},
		"get_clipboard": {
			Name:        "get_clipboard",
			Description: "Get text from clipboard",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleGetClipboard,
		},
	}
}

// Serve starts serving MCP requests
func (s *MCPServer) Serve(tr *transport.StdioTransport) error {
	log.Println("MCP server starting...")

	for {
		select {
		case <-s.ctx.Done():
			log.Println("MCP server stopping (context cancelled)")
			return nil
		default:
			// Read a message
			msg, err := tr.ReadMessage()
			if err != nil {
				if err == io.EOF {
					log.Println("MCP server stopping (EOF)")
					return nil
				}
				log.Printf("Error reading message: %v", err)
				continue
			}

			// Handle the message
			go s.handleMessage(tr, msg)
		}
	}
}

// handleMessage handles a single MCP message
func (s *MCPServer) handleMessage(tr *transport.StdioTransport, msg *transport.Message) {
	// Handle initialize request
	if msg.Method == "initialize" {
		response := &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  []byte(`{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"}}`),
		}
		if err := tr.WriteMessage(response); err != nil {
			log.Printf("Error writing response: %v", err)
		}
		return
	}

	// Handle list_tools request
	if msg.Method == "tools/list" {
		s.mu.RLock()
		tools := make([]map[string]interface{}, 0, len(s.tools))
		for _, tool := range s.tools {
			tools = append(tools, map[string]interface{}{
				"name":        tool.Name,
				"description": tool.Description,
				"inputSchema": tool.InputSchema,
			})
		}
		s.mu.RUnlock()

		result, _ := json.Marshal(map[string]interface{}{"tools": tools})
		response := &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}
		if err := tr.WriteMessage(response); err != nil {
			log.Printf("Error writing response: %v", err)
		}
		return
	}

	// Handle tool call request
	if msg.Method == "tools/call" {
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    -32600,
					Message: fmt.Sprintf("Invalid request: %v", err),
				},
			}
			tr.WriteMessage(response)
			return
		}

		s.mu.RLock()
		tool, exists := s.tools[params.Name]
		s.mu.RUnlock()

		if !exists {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    -32601,
					Message: fmt.Sprintf("Tool not found: %s", params.Name),
				},
			}
			tr.WriteMessage(response)
			return
		}

		// Call the tool handler
		result, err := tool.Handler(&ToolCall{
			Name:      params.Name,
			Arguments: params.Arguments,
		})

		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    -32603,
					Message: err.Error(),
				},
			}
			tr.WriteMessage(response)
			return
		}

		// Format the result as content array
		resultMap := map[string]interface{}{
			"content": result.Content,
		}
		if result.IsError {
			resultMap["isError"] = true
		}

		resultBytes, _ := json.Marshal(resultMap)
		response := &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  resultBytes,
		}
		if err := tr.WriteMessage(response); err != nil {
			log.Printf("Error writing response: %v", err)
		}
		return
	}

	// Handle unknown method
	response := &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Error: &transport.ErrorObj{
			Code:    -32601,
			Message: fmt.Sprintf("Method not found: %s", msg.Method),
		},
	}
	tr.WriteMessage(response)
}
