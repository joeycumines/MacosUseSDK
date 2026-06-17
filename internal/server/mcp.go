// Copyright 2025 Joseph Cumines

// Package server implements a Model Context Protocol (MCP) server that proxies
// macOS automation requests to a gRPC backend. It exposes 23 CUA-aligned tools
// across 5 categories: core CUA input, application management, element interaction,
// window management, and utility (clipboard, scripting, display).
//
// The server supports both stdio (for MCP clients like Claude Desktop) and
// HTTP/SSE transports (for web-based integrations). All tools follow MCP
// specification version 2025-11-25 with soft-error semantics (isError field
// in ToolResult rather than RPC-level failures).
//
// See docs/ai-artifacts/10-api-reference.md for comprehensive tool documentation.
package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// MCP server constants.
const (
	// displayInfoTimeout is the timeout for fetching display information.
	displayInfoTimeout = 5 * time.Second
)

// MCPServer implements the Model Context Protocol (MCP) server.
// It connects to a gRPC backend and exposes 23 CUA-aligned MCP tools for macOS automation.
// The server supports both stdio and HTTP/SSE transports.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type MCPServer struct {
	client        pb.MacosUseClient
	opsClient     longrunningpb.OperationsClient
	httpTransport *transport.HTTPTransport
	auditLogger   *AuditLogger
	ctx           context.Context
	cfg           *config.Config
	conn          *grpc.ClientConn
	tools         map[string]*Tool
	cancel        context.CancelFunc
	mu            sync.RWMutex
}

// Tool represents an MCP tool with its handler, schema, and metadata.
// Each tool is registered with the server and exposed via the MCP protocol.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Tool struct {
	Handler     func(*ToolCall) (*ToolResult, error)
	InputSchema map[string]any
	Name        string
	Description string
}

// ToolCall represents an incoming MCP tool invocation request.
// It contains the tool name and the JSON-encoded arguments.
type ToolCall struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// ToolResult represents the result of an MCP tool invocation.
// It contains one or more content items (text, images, etc.) and an optional error flag.
type ToolResult struct {
	Content []Content `json:"content"`
	IsError bool      `json:"isError,omitempty"`
}

// Content represents a content item in an MCP tool result.
//
// For type="text":
//   - Text: the text content
//
// For type="image":
//   - Data: base64-encoded image bytes (no data-URI prefix)
//   - MimeType: MIME type (e.g., "image/png", "image/jpeg")
type Content struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

// MCPInitializeParams represents the params of an MCP initialize request.
// Per MCP spec, clients send protocolVersion, clientInfo, and capabilities.
type MCPInitializeParams struct {
	Capabilities    any           `json:"capabilities"`
	ClientInfo      MCPClientInfo `json:"clientInfo"`
	ProtocolVersion string        `json:"protocolVersion"`
}

// MCPClientInfo represents client information in an initialize request.
type MCPClientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// Supported MCP protocol versions.
const (
	// mcpProtocolVersionCurrent is the current MCP specification version.
	mcpProtocolVersionCurrent = "2025-11-25"
)

// NewMCPServer creates a new MCP server with the given configuration.
// It initializes the gRPC connection, audit logger, and registers all tools.
// Returns an error if gRPC connection or audit logger initialization fails.
func NewMCPServer(cfg *config.Config) (*MCPServer, error) {
	ctx, cancel := context.WithCancel(context.Background())

	// Initialize audit logger
	auditLogger, err := NewAuditLogger(cfg.AuditLogFile)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("failed to initialize audit logger: %w", err)
	}

	s := &MCPServer{
		cfg:         cfg,
		ctx:         ctx,
		cancel:      cancel,
		tools:       make(map[string]*Tool),
		auditLogger: auditLogger,
	}

	// Initialize gRPC connection
	if err := s.initGRPC(); err != nil {
		auditLogger.Close()
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

	// Determine the server address
	var serverAddr string
	if s.cfg.ServerSocketPath != "" {
		// Use Unix socket for connection
		serverAddr = "unix://" + s.cfg.ServerSocketPath
		log.Printf("Connecting to gRPC server via Unix socket: %s", s.cfg.ServerSocketPath)
	} else {
		serverAddr = s.cfg.ServerAddr
		log.Printf("Connecting to gRPC server at: %s", serverAddr)
	}

	conn, err := grpc.NewClient(serverAddr, opts...)
	if err != nil {
		return fmt.Errorf("failed to create client: %w", err)
	}

	s.conn = conn
	s.client = pb.NewMacosUseClient(conn)
	s.opsClient = longrunningpb.NewOperationsClient(conn)

	return nil
}

// Shutdown gracefully shuts down the server and releases all resources.
// It closes the HTTP transport, audit logger, and gRPC connection.
func (s *MCPServer) Shutdown() {
	// Close HTTP transport if active
	s.mu.RLock()
	httpTransport := s.httpTransport
	s.mu.RUnlock()
	if httpTransport != nil {
		if err := httpTransport.Close(); err != nil {
			log.Printf("Error closing HTTP transport: %v", err)
		}
	}

	// Close audit logger
	if s.auditLogger != nil {
		if err := s.auditLogger.Close(); err != nil {
			log.Printf("Error closing audit logger: %v", err)
		}
	}

	// Close gRPC connection
	if s.conn != nil {
		s.conn.Close()
	}
	s.cancel()
	log.Println("Shutting down MCP server...")
}

// registerTools initializes all MCP tool handlers for the server.
// This registers 23 CUA-aligned tools across categories: core CUA (9),
// application management (3), element interaction (4), window management (4),
// clipboard (1), scripting (1), display (1).
func (s *MCPServer) registerTools() {
	s.tools = map[string]*Tool{
		// === CATEGORY 1: CORE CUA (9 tools — OpenAI CUA aligned) ===

		"screenshot": {
			Name:        "screenshot",
			Description: "Capture screen and return base64-encoded image. If no window/region specified, captures full display.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"display": map[string]any{"type": "integer", "description": "Display index (default: 0/main)"},
					"window":  map[string]any{"type": "string", "description": "Window resource name for window-specific capture"},
					"x":       map[string]any{"type": "number", "description": "Region origin X (Global Display Coordinates)"},
					"y":       map[string]any{"type": "number", "description": "Region origin Y (Global Display Coordinates)"},
					"width":   map[string]any{"type": "number", "description": "Region width in pixels"},
					"height":  map[string]any{"type": "number", "description": "Region height in pixels"},
					"format":  map[string]any{"type": "string", "description": "png (default), jpeg, tiff", "enum": []string{"png", "jpeg", "tiff"}},
					"quality": map[string]any{"type": "integer", "description": "JPEG quality 1-100 (default: 85)"},
					"ocr":     map[string]any{"type": "boolean", "description": "Include OCR text extraction"},
				},
			},
			Handler: s.handleScreenshot,
		},
		"click": {
			Name:        "click",
			Description: "Click at screen coordinates. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"x":           map[string]any{"type": "number", "description": "X coordinate (Global Display Coordinates, top-left origin)"},
					"y":           map[string]any{"type": "number", "description": "Y coordinate (Global Display Coordinates, top-left origin)"},
					"button":      map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}},
					"click_count": map[string]any{"type": "integer", "description": "1=single (default), 2=double, 3=triple, 4-10=N-tuple; maximum 10"},
					"keys":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Modifier keys held during click: ctrl, alt, meta, shift"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.cuaHandleClick,
		},
		"double_click": {
			Name:        "double_click",
			Description: "Double-click at screen coordinates. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"x":      map[string]any{"type": "number", "description": "X coordinate"},
					"y":      map[string]any{"type": "number", "description": "Y coordinate"},
					"button": map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}},
					"keys":   map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Modifier keys held during double-click"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleDoubleClick,
		},
		"type": {
			Name:        "type",
			Description: "Type text as keyboard input into the currently focused element.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"text":       map[string]any{"type": "string", "description": "Text to type"},
					"char_delay": map[string]any{"type": "number", "description": "Delay between characters in seconds"},
				},
				"required": []string{"text"},
			},
			Handler: s.handleType,
		},
		"keypress": {
			Name:        "keypress",
			Description: "Press key combinations. CUA key names: ctrl, alt, meta, shift, enter, esc, backspace, arrowup, etc.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"keys": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Key combination, e.g. [\"ctrl\",\"c\"] or [\"meta\",\"shift\",\"3\"]"},
				},
				"required": []string{"keys"},
			},
			Handler: s.handleKeypress,
		},
		"scroll": {
			Name:        "scroll",
			Description: "Scroll at a screen position by delta amounts. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"x":        map[string]any{"type": "number", "description": "X coordinate to scroll at"},
					"y":        map[string]any{"type": "number", "description": "Y coordinate to scroll at"},
					"scroll_x": map[string]any{"type": "number", "description": "Horizontal scroll delta (positive=right, negative=left)"},
					"scroll_y": map[string]any{"type": "number", "description": "Vertical scroll delta (positive=down, negative=up)"},
					"keys":     map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Modifier keys held during scroll"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.cuaHandleScroll,
		},
		"drag": {
			Name:        "drag",
			Description: "Click-and-drag along a sequence of waypoints. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"path": map[string]any{
						"type":        "array",
						"items":       map[string]any{"type": "object", "properties": map[string]any{"x": map[string]any{"type": "number"}, "y": map[string]any{"type": "number"}}, "required": []string{"x", "y"}},
						"description": "Ordered waypoints, minimum 2 points",
					},
					"button":   map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}},
					"keys":     map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Modifier keys held during drag"},
					"duration": map[string]any{"type": "number", "description": "Duration of drag in seconds"},
				},
				"required": []string{"path"},
			},
			Handler: s.cuaHandleDrag,
		},
		"move": {
			Name:        "move",
			Description: "Move mouse cursor to a position without clicking. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"x":    map[string]any{"type": "number", "description": "Target X coordinate"},
					"y":    map[string]any{"type": "number", "description": "Target Y coordinate"},
					"keys": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Modifier keys held during move"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleMove,
		},
		"wait": {
			Name:        "wait",
			Description: "Pause for a specified duration.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"duration": map[string]any{"type": "number", "description": "Duration in seconds (default: 1.0)"},
				},
			},
			Handler: s.handleWait,
		},

		// === CATEGORY 2: APPLICATION MANAGEMENT (3 tools) ===

		"open_app": {
			Name:        "open_app",
			Description: "Open, activate, or focus an application with explicit mode control for predictable behavior.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"id":             map[string]any{"type": "string", "description": "App name, bundle ID, or path"},
					"mode":           map[string]any{"type": "string", "description": "launch_or_activate (default), force_new_instance, activate_only", "enum": []string{"launch_or_activate", "force_new_instance", "activate_only"}},
					"bring_to_front": map[string]any{"type": "boolean", "description": "Bring app to foreground (default: true)"},
				},
				"required": []string{"id"},
			},
			Handler: s.handleOpenApp,
		},
		"list_apps": {
			Name:        "list_apps",
			Description: "List running applications currently tracked for automation.",
			InputSchema: map[string]any{
				"type":                 "object",
				"properties":           map[string]any{},
				"additionalProperties": false,
			},
			Handler: s.handleListApps,
		},
		"close_app": {
			Name:        "close_app",
			Description: "Close/quit an application (actually terminates the process, not just untracks).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"app":   map[string]any{"type": "string", "description": "Application resource name or bundle ID"},
					"force": map[string]any{"type": "boolean", "description": "Force quit if app doesn't respond (default: false)"},
				},
				"required": []string{"app"},
			},
			Handler: s.handleCloseApp,
		},

		// === CATEGORY 3: ELEMENT INTERACTION (4 tools) ===

		"find_elements": {
			Name:        "find_elements",
			Description: "Find UI elements by criteria. Returns accessibility tree elements with role, text, position, and available actions.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":        map[string]any{"type": "string", "description": "Parent context (e.g., applications/123 or applications/123/windows/456)"},
					"role":          map[string]any{"type": "string", "description": "Element role (e.g., button, textField, checkBox)"},
					"text":          map[string]any{"type": "string", "description": "Element text content (exact match)"},
					"text_contains": map[string]any{"type": "string", "description": "Element text contains substring"},
					"force_refresh": map[string]any{"type": "boolean", "description": "Discard cached data (default: false)"},
					"page_size":     map[string]any{"type": "integer", "description": "Maximum elements to return"},
					"page_token":    map[string]any{"type": "string", "description": "Opaque page token from previous response"},
				},
				"required": []string{"parent"},
			},
			Handler: s.cuaHandleFindElements,
		},
		"click_element": {
			Name:        "click_element",
			Description: "Click a UI element via accessibility APIs. Automatically clicks element center and acquires focus for reliability.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":  map[string]any{"type": "string", "description": "Parent context"},
					"element": map[string]any{"type": "string", "description": "Element ID from find_elements"},
				},
				"required": []string{"parent", "element"},
			},
			Handler: s.cuaHandleClickElement,
		},
		"type_element": {
			Name:        "type_element",
			Description: "Set the value of a UI element (text field, etc.). Auto-focuses the element before typing.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":  map[string]any{"type": "string", "description": "Parent context"},
					"element": map[string]any{"type": "string", "description": "Element ID"},
					"text":    map[string]any{"type": "string", "description": "Text to enter"},
				},
				"required": []string{"parent", "element", "text"},
			},
			Handler: s.handleTypeElement,
		},
		"read_element": {
			Name:        "read_element",
			Description: "Get detailed element info: role, text, bounds, value, available actions, focused/enabled state.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"element": map[string]any{"type": "string", "description": "Element resource name"},
				},
				"required": []string{"element"},
			},
			Handler: s.handleReadElement,
		},

		// === CATEGORY 4: WINDOW MANAGEMENT (4 tools) ===

		"focus_window": {
			Name:        "focus_window",
			Description: "Bring a window to the front.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
				},
				"required": []string{"window"},
			},
			Handler: s.cuaHandleFocusWindow,
		},
		"move_window": {
			Name:        "move_window",
			Description: "Move a window to a new position. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
					"x":      map[string]any{"type": "number", "description": "New X position (Global Display Coordinates)"},
					"y":      map[string]any{"type": "number", "description": "New Y position (Global Display Coordinates)"},
				},
				"required": []string{"window", "x", "y"},
			},
			Handler: s.cuaHandleMoveWindow,
		},
		"resize_window": {
			Name:        "resize_window",
			Description: "Resize a window.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
					"width":  map[string]any{"type": "number", "description": "New width in pixels"},
					"height": map[string]any{"type": "number", "description": "New height in pixels"},
				},
				"required": []string{"window", "width", "height"},
			},
			Handler: s.cuaHandleResizeWindow,
		},
		"list_windows": {
			Name:        "list_windows",
			Description: "List open windows.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"app":        map[string]any{"type": "string", "description": "Filter by application resource name"},
					"page_size":  map[string]any{"type": "integer", "description": "Maximum windows to return"},
					"page_token": map[string]any{"type": "string", "description": "Opaque page token from previous response"},
				},
			},
			Handler: s.cuaHandleListWindows,
		},

		// === CATEGORY 5: UTILITY (3 tools) ===

		"clipboard": {
			Name:        "clipboard",
			Description: "Unified clipboard operations: get, set, or clear clipboard contents.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"action": map[string]any{"type": "string", "description": "get, set, clear", "enum": []string{"get", "set", "clear"}},
					"text":   map[string]any{"type": "string", "description": "Text content (required for set)"},
				},
				"required": []string{"action"},
			},
			Handler: s.handleClipboard,
		},
		"run": {
			Name:        "run",
			Description: "Execute scripts/commands. Type: shell (default), applescript, javascript.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"command": map[string]any{"type": "string", "description": "Command or script to execute"},
					"type":    map[string]any{"type": "string", "description": "shell (default), applescript, javascript", "enum": []string{"shell", "applescript", "javascript"}},
					"timeout": map[string]any{"type": "integer", "description": "Timeout in seconds (default: 30)"},
				},
				"required": []string{"command"},
			},
			Handler: s.handleRun,
		},
		"get_display": {
			Name:        "get_display",
			Description: "Get display information and cursor position.",
			InputSchema: map[string]any{
				"type":                 "object",
				"properties":           map[string]any{},
				"additionalProperties": false,
			},
			Handler: s.cuaHandleGetDisplay,
		},
	}
}

// Serve starts serving MCP requests over the given stdio transport.
// It blocks until the transport is closed or the server context is cancelled.
func (s *MCPServer) Serve(tr *transport.StdioTransport) error {
	log.Println("MCP server starting...")

	// Use a goroutine for reading messages to allow context cancellation
	type readResult struct {
		msg *transport.Message
		err error
	}
	msgCh := make(chan readResult)

	go func() {
		for {
			msg, err := tr.ReadMessage()
			select {
			case msgCh <- readResult{msg, err}:
				if err != nil {
					return // Exit reader goroutine on error
				}
			case <-s.ctx.Done():
				return // Exit reader goroutine on context cancellation
			}
		}
	}()

	for {
		select {
		case <-s.ctx.Done():
			log.Println("MCP server stopping (context cancelled)")
			tr.Close() // Close transport to unblock reader goroutine
			return nil
		case result := <-msgCh:
			if result.err != nil {
				if result.err == io.EOF || strings.Contains(result.err.Error(), "stdin closed") {
					log.Println("MCP server stopping (EOF)")
					return nil
				}
				log.Printf("Error reading message: %v", result.err)
				continue
			}
			// Handle the message
			go s.handleMessage(tr, result.msg)
		}
	}
}

// ServeHTTP starts serving MCP requests over the HTTP/SSE transport.
// It blocks until the transport is closed or an error occurs.
func (s *MCPServer) ServeHTTP(tr *transport.HTTPTransport) error {
	log.Println("MCP server starting with HTTP/SSE transport...")
	s.mu.Lock()
	s.httpTransport = tr
	s.mu.Unlock()
	return tr.Serve(s.handleHTTPMessage)
}

// validateAndProcessInitialize validates initialize params and returns the response or an error.
// This is shared between HTTP and stdio transports for consistency.
func (s *MCPServer) validateAndProcessInitialize(msg *transport.Message) (*transport.Message, error) {
	// Parse the initialize params
	var params MCPInitializeParams
	if len(msg.Params) > 0 {
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			// Malformed params - treat as empty and use defaults
			log.Printf("WARN: MCP initialize params parse error (using defaults): %v", err)
		}
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
	if clientName == "" {
		clientName = "unknown"
	}
	if clientVersion == "" {
		clientVersion = "unknown"
	}
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
func (s *MCPServer) handleHTTPMessage(msg *transport.Message) (*transport.Message, error) {
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
			})
		}
		s.mu.RUnlock()

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

		contents, err := s.readResource(params.URI)
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
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			return &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("Invalid params: %v", err),
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
		var args map[string]any
		if len(params.Arguments) > 0 {
			if err := json.Unmarshal(params.Arguments, &args); err != nil {
				return &transport.Message{
					JSONRPC: "2.0",
					ID:      msg.ID,
					Error: &transport.ErrorObj{
						Code:    transport.ErrCodeInvalidParams,
						Message: fmt.Sprintf("Invalid arguments JSON: %v", err),
					},
				}, nil
			}
		} else {
			args = make(map[string]any)
		}

		s.mu.RLock()
		validationErr := validateToolInput(params.Name, args, s.tools)
		s.mu.RUnlock()
		if validationErr != nil {
			validationErr.ID = msg.ID
			return validationErr, nil
		}

		call := &ToolCall{
			Name:      params.Name,
			Arguments: params.Arguments,
		}

		// Track start time for metrics
		startTime := time.Now()

		result, err := tool.Handler(call)

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
			s.auditLogger.LogToolCall(params.Name, params.Arguments, status, duration)
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
	if len(msg.ID) == 0 || string(msg.ID) == "null" {
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

// handleMessage handles a single MCP message
func (s *MCPServer) handleMessage(tr *transport.StdioTransport, msg *transport.Message) {
	// Handle initialize request
	if msg.Method == "initialize" {
		response, err := s.validateAndProcessInitialize(msg)
		if err != nil {
			log.Printf("Error processing initialize: %v", err)
			return
		}
		if response != nil {
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
		}
		return
	}

	// Handle notifications/initialized - client acknowledgment of successful initialization
	// Per MCP spec: clients send this notification after receiving initialize response
	if msg.Method == "notifications/initialized" {
		// This is a notification, no response required
		return
	}

	// Handle ping request.
	// Per MCP 2025-11-25 basic/utilities/ping: the receiver MUST respond with an empty result.
	if msg.Method == "ping" {
		response := &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  []byte(`{}`),
		}
		if err := tr.WriteMessage(response); err != nil {
			log.Printf("Error writing response: %v", err)
		}
		return
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
			})
		}
		s.mu.RUnlock()

		result, err := json.Marshal(map[string]any{"tools": tools})
		if err != nil {
			log.Printf("Error marshaling tools list: %v", err)
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: "failed to marshal tools list",
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}
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
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}
			if writeErr := tr.WriteMessage(response); writeErr != nil {
				log.Printf("Error writing error response: %v", writeErr)
			}
			return
		}
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

	// Handle resources/read request
	if msg.Method == "resources/read" {
		var params struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("invalid params: %v", err),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		contents, err := s.readResource(params.URI)
		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: err.Error(),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		result, err := json.Marshal(map[string]any{"contents": contents})
		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}
			if writeErr := tr.WriteMessage(response); writeErr != nil {
				log.Printf("Error writing error response: %v", writeErr)
			}
			return
		}
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

	// Handle prompts/list request
	if msg.Method == "prompts/list" {
		prompts := s.listPrompts()
		result, err := json.Marshal(map[string]any{"prompts": prompts})
		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}
			if writeErr := tr.WriteMessage(response); writeErr != nil {
				log.Printf("Error writing error response: %v", writeErr)
			}
			return
		}
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

	// Handle prompts/get request
	if msg.Method == "prompts/get" {
		var params struct {
			Arguments map[string]any `json:"arguments"`
			Name      string         `json:"name"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("invalid params: %v", err),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		prompt, err := s.getPrompt(params.Name, params.Arguments)
		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInvalidParams, // Unknown prompt name is invalid params per MCP spec
					Message: err.Error(),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		result, err := json.Marshal(prompt)
		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: fmt.Sprintf("internal error: %v", err),
				},
			}
			if writeErr := tr.WriteMessage(response); writeErr != nil {
				log.Printf("Error writing error response: %v", writeErr)
			}
			return
		}
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
					Code:    transport.ErrCodeInvalidParams,
					Message: fmt.Sprintf("Invalid params: %v", err),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
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
					Code:    transport.ErrCodeMethodNotFound,
					Message: fmt.Sprintf("Tool not found: %s", params.Name),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		// Validate tool input against schema before calling handler
		var args map[string]any
		if len(params.Arguments) > 0 {
			if err := json.Unmarshal(params.Arguments, &args); err != nil {
				response := &transport.Message{
					JSONRPC: "2.0",
					ID:      msg.ID,
					Error: &transport.ErrorObj{
						Code:    transport.ErrCodeInvalidParams,
						Message: fmt.Sprintf("Invalid arguments JSON: %v", err),
					},
				}
				if err := tr.WriteMessage(response); err != nil {
					log.Printf("Error writing response: %v", err)
				}
				return
			}
		} else {
			args = make(map[string]any)
		}

		s.mu.RLock()
		validationErr := validateToolInput(params.Name, args, s.tools)
		s.mu.RUnlock()
		if validationErr != nil {
			validationErr.ID = msg.ID
			if err := tr.WriteMessage(validationErr); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		// Track start time for metrics
		startTime := time.Now()

		// Call the tool handler
		result, err := tool.Handler(&ToolCall{
			Name:      params.Name,
			Arguments: params.Arguments,
		})

		// Calculate duration
		duration := time.Since(startTime)

		// Determine status
		status := "ok"
		if err != nil {
			status = "error"
		} else if result != nil && result.IsError {
			status = "error"
		}

		// Record audit log (stdio transport has no metrics registry)
		if s.auditLogger != nil {
			s.auditLogger.LogToolCall(params.Name, params.Arguments, status, duration)
		}

		if err != nil {
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: err.Error(),
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}

		// Format the result as content array
		resultMap := map[string]any{
			"content": result.Content,
		}
		if result.IsError {
			resultMap["isError"] = true
		}

		resultBytes, err := json.Marshal(resultMap)
		if err != nil {
			log.Printf("Error marshaling tool result: %v", err)
			response := &transport.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Error: &transport.ErrorObj{
					Code:    transport.ErrCodeInternalError,
					Message: "failed to marshal tool result",
				},
			}
			if err := tr.WriteMessage(response); err != nil {
				log.Printf("Error writing response: %v", err)
			}
			return
		}
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

	// Handle unknown method.
	// Per MCP 2025-11-25 base protocol, notifications (messages without an ID)
	// MUST NOT receive a response.
	if len(msg.ID) == 0 || string(msg.ID) == "null" {
		return
	}
	response := &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Error: &transport.ErrorObj{
			Code:    transport.ErrCodeMethodNotFound,
			Message: fmt.Sprintf("Method not found: %s", msg.Method),
		},
	}
	if err := tr.WriteMessage(response); err != nil {
		log.Printf("Error writing response: %v", err)
	}
}

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
func (s *MCPServer) readResource(uri string) (contents []map[string]any, err error) {
	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
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

		resp, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{})
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
		if text := content.GetText(); text != "" {
			return []map[string]any{
				{"uri": uri, "mimeType": "text/plain", "text": text},
			}, nil
		}
		if html := content.GetHtml(); html != "" {
			return []map[string]any{
				{"uri": uri, "mimeType": "text/html", "text": html},
			}, nil
		}
		if rtf := content.GetRtf(); len(rtf) > 0 {
			return []map[string]any{
				{"uri": uri, "mimeType": "text/rtf", "text": string(rtf)},
			}, nil
		}
		if files := content.GetFiles(); files != nil && len(files.GetPaths()) > 0 {
			filesJSON, _ := json.Marshal(files.GetPaths())
			return []map[string]any{
				{"uri": uri, "mimeType": "application/json", "text": string(filesJSON)},
			}, nil
		}
		if url := content.GetUrl(); url != "" {
			return []map[string]any{
				{"uri": uri, "mimeType": "text/plain", "text": url},
			}, nil
		}
		return []map[string]any{
			{"uri": uri, "mimeType": "text/plain", "text": ""},
		}, nil // Empty clipboard
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
				{"name": "selector", "description": "Element selector criteria: role, text, or text_contains", "required": true},
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

1. First, call find_elements with parent set to the target application/window. Use exactly one of the flat top-level fields role, text, or text_contains to match the element. Match value for this step: %s
   Example: {"parent": "applications/123/windows/456", "role": "button"}
2. Once found, use click_element with the same parent and element ID
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
