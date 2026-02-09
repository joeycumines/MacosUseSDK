// Copyright 2025 Joseph Cumines

// Package server implements a Model Context Protocol (MCP) server that proxies
// macOS automation requests to a gRPC backend. It exposes 77 tools across 14
// categories including window management, accessibility traversal, input control,
// clipboard operations, session/macro management, and more.
//
// The server supports both stdio (for MCP clients like Claude Desktop) and
// HTTP/SSE transports (for web-based integrations). All tools follow MCP
// specification version 2025-11-25 with soft-error semantics (isError field
// in ToolResult rather than RPC-level failures).
//
// See docs/10-api-reference.md for comprehensive tool documentation.
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
	// shutdownResponseDelay is the delay before shutdown to allow response to be sent.
	shutdownResponseDelay = 100 * time.Millisecond
	// displayInfoTimeout is the timeout for fetching display information.
	displayInfoTimeout = 5 * time.Second
)

// MCPServer implements the Model Context Protocol (MCP) server.
// It connects to a gRPC backend and exposes 77 MCP tools for macOS automation
// including screenshot capture, input simulation, window management, and more.
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
	InputSchema map[string]interface{}
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
	IsError bool      `json:"is_error,omitempty"`
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
	Capabilities    interface{}   `json:"capabilities"`
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
	// mcpProtocolVersionPrevious is the previous MCP specification version (deprecated).
	mcpProtocolVersionPrevious = "2024-11-05"
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
// This registers 77 tools across categories: screenshot, input, element,
// window, display, clipboard, application, scripting, observation,
// accessibility, file dialog, session, macro, and input query.
func (s *MCPServer) registerTools() {
	s.tools = map[string]*Tool{
		// === SCREENSHOT TOOLS (P0) ===
		"capture_screenshot": {
			Name:        "capture_screenshot",
			Description: "Capture a full screen screenshot. Returns base64-encoded image data. Essential for visual observation in Computer Use agents.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"format": map[string]interface{}{
						"type":        "string",
						"description": "Image format: png, jpeg, tiff. Default: png",
						"enum":        []string{"png", "jpeg", "tiff"},
					},
					"quality": map[string]interface{}{
						"type":        "integer",
						"description": "JPEG quality (1-100). Only used for jpeg format. Default: 85",
					},
					"display": map[string]interface{}{
						"type":        "integer",
						"description": "Display index for multi-monitor setups. Default: 0 (main display)",
					},
					"include_ocr": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to include OCR text extraction in response",
					},
				},
			},
			Handler: s.handleCaptureScreenshot,
		},
		"capture_window_screenshot": {
			Name:        "capture_window_screenshot",
			Description: "Capture a screenshot of a specific window. Essential for multi-window workflows like VS Code where you need focused visual feedback on the active window.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"window": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
					"format": map[string]interface{}{
						"type":        "string",
						"description": "Image format: png, jpeg, tiff. Default: png",
						"enum":        []string{"png", "jpeg", "tiff"},
					},
					"quality": map[string]interface{}{
						"type":        "integer",
						"description": "JPEG quality (1-100). Only used for jpeg format. Default: 85",
					},
					"include_shadow": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to include window shadow in screenshot. Default: false",
					},
					"include_ocr": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to include OCR text extraction in response",
					},
				},
				"required": []string{"window"},
			},
			Handler: s.handleCaptureWindowScreenshot,
		},
		"capture_region_screenshot": {
			Name:        "capture_region_screenshot",
			Description: "Capture a screenshot of a specific screen region. Uses Global Display Coordinates (top-left origin). Useful for zooming in on UI elements.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x":           map[string]interface{}{"type": "number", "description": "X coordinate of region origin (Global Display Coordinates)"},
					"y":           map[string]interface{}{"type": "number", "description": "Y coordinate of region origin (Global Display Coordinates)"},
					"width":       map[string]interface{}{"type": "number", "description": "Width of region in pixels"},
					"height":      map[string]interface{}{"type": "number", "description": "Height of region in pixels"},
					"format":      map[string]interface{}{"type": "string", "description": "Image format: png, jpeg, tiff"},
					"quality":     map[string]interface{}{"type": "integer", "description": "JPEG quality (1-100)"},
					"include_ocr": map[string]interface{}{"type": "boolean", "description": "Include OCR text extraction"},
				},
				"required": []string{"x", "y", "width", "height"},
			},
			Handler: s.handleCaptureRegionScreenshot,
		},

		// === INPUT TOOLS (P0/P1) ===
		"click": {
			Name:        "click",
			Description: "Click at a specific screen coordinate. Uses Global Display Coordinates (top-left origin, Y increases downward).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x": map[string]interface{}{
						"type":        "number",
						"description": "X coordinate to click (Global Display Coordinates)",
					},
					"y": map[string]interface{}{
						"type":        "number",
						"description": "Y coordinate to click (Global Display Coordinates)",
					},
					"button": map[string]interface{}{
						"type":        "string",
						"description": "Mouse button: left, right, middle. Default: left",
						"enum":        []string{"left", "right", "middle"},
					},
					"click_count": map[string]interface{}{
						"type":        "integer",
						"description": "Number of clicks: 1=single, 2=double, 3=triple. Default: 1",
					},
					"show_animation": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to show visual feedback animation",
					},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleClick,
		},
		"type_text": {
			Name:        "type_text",
			Description: "Type text as keyboard input. Simulates human typing.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"text": map[string]interface{}{
						"type":        "string",
						"description": "Text to type",
					},
					"char_delay": map[string]interface{}{
						"type":        "number",
						"description": "Delay between characters in seconds (for human-like typing)",
					},
					"use_ime": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to use IME for non-ASCII input",
					},
				},
				"required": []string{"text"},
			},
			Handler: s.handleTypeText,
		},
		"press_key": {
			Name:        "press_key",
			Description: "Press a key combination. Supports modifier keys (command, option, control, shift).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"key": map[string]interface{}{
						"type":        "string",
						"description": "Key to press (e.g., return, escape, a, f1, space, tab, delete)",
					},
					"modifiers": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Modifier keys to hold: command, option, control, shift, function, capslock",
					},
				},
				"required": []string{"key"},
			},
			Handler: s.handlePressKey,
		},
		"hold_key": {
			Name:        "hold_key",
			Description: "Hold a key down for a specified duration. Useful for modifier key holds or game-style input where key timing matters.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"key": map[string]interface{}{
						"type":        "string",
						"description": "Key to hold (e.g., a, space, shift)",
					},
					"duration": map[string]interface{}{
						"type":        "number",
						"description": "Duration to hold the key in seconds",
					},
					"modifiers": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Modifier keys to hold: command, option, control, shift, function, capslock",
					},
				},
				"required": []string{"key", "duration"},
			},
			Handler: s.handleHoldKey,
		},
		"mouse_move": {
			Name:        "mouse_move",
			Description: "Move the mouse cursor to a specific position. Uses Global Display Coordinates (top-left origin). Useful for triggering hover states.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x": map[string]interface{}{
						"type":        "number",
						"description": "Target X coordinate (Global Display Coordinates)",
					},
					"y": map[string]interface{}{
						"type":        "number",
						"description": "Target Y coordinate (Global Display Coordinates)",
					},
					"duration": map[string]interface{}{
						"type":        "number",
						"description": "Duration for smooth animation in seconds",
					},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleMouseMove,
		},
		"scroll": {
			Name:        "scroll",
			Description: "Scroll content vertically and/or horizontally. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x": map[string]interface{}{
						"type":        "number",
						"description": "X coordinate to scroll at (Global Display Coordinates, optional)",
					},
					"y": map[string]interface{}{
						"type":        "number",
						"description": "Y coordinate to scroll at (Global Display Coordinates, optional)",
					},
					"horizontal": map[string]interface{}{
						"type":        "number",
						"description": "Horizontal scroll amount (positive = right, negative = left)",
					},
					"vertical": map[string]interface{}{
						"type":        "number",
						"description": "Vertical scroll amount (positive = up, negative = down)",
					},
					"duration": map[string]interface{}{
						"type":        "number",
						"description": "Duration for momentum effect",
					},
				},
			},
			Handler: s.handleScroll,
		},
		"drag": {
			Name:        "drag",
			Description: "Drag from one position to another. Uses Global Display Coordinates (top-left origin). Used for drag-and-drop, selection, and slider operations.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"start_x":  map[string]interface{}{"type": "number", "description": "Start X coordinate (Global Display Coordinates)"},
					"start_y":  map[string]interface{}{"type": "number", "description": "Start Y coordinate (Global Display Coordinates)"},
					"end_x":    map[string]interface{}{"type": "number", "description": "End X coordinate (Global Display Coordinates)"},
					"end_y":    map[string]interface{}{"type": "number", "description": "End Y coordinate (Global Display Coordinates)"},
					"duration": map[string]interface{}{"type": "number", "description": "Duration of drag in seconds"},
					"button":   map[string]interface{}{"type": "string", "description": "Mouse button: left, right, middle"},
				},
				"required": []string{"start_x", "start_y", "end_x", "end_y"},
			},
			Handler: s.handleDrag,
		},
		"mouse_button_down": {
			Name:        "mouse_button_down",
			Description: "Press a mouse button down at a position without releasing. Use with mouse_button_up for stateful drag operations with intermediate moves. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x":         map[string]interface{}{"type": "number", "description": "X coordinate (Global Display Coordinates)"},
					"y":         map[string]interface{}{"type": "number", "description": "Y coordinate (Global Display Coordinates)"},
					"button":    map[string]interface{}{"type": "string", "description": "Mouse button: left, right, middle"},
					"modifiers": map[string]interface{}{"type": "array", "items": map[string]interface{}{"type": "string"}, "description": "Modifier keys: command, option, control, shift"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleMouseButtonDown,
		},
		"mouse_button_up": {
			Name:        "mouse_button_up",
			Description: "Release a mouse button at a position. Use after mouse_button_down to complete drag operations. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x":         map[string]interface{}{"type": "number", "description": "X coordinate (Global Display Coordinates)"},
					"y":         map[string]interface{}{"type": "number", "description": "Y coordinate (Global Display Coordinates)"},
					"button":    map[string]interface{}{"type": "string", "description": "Mouse button: left, right, middle"},
					"modifiers": map[string]interface{}{"type": "array", "items": map[string]interface{}{"type": "string"}, "description": "Modifier keys: command, option, control, shift"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleMouseButtonUp,
		},
		"hover": {
			Name:        "hover",
			Description: "Hover the mouse at a position for a specified duration. Triggers hover states and tooltips.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"x":           map[string]interface{}{"type": "number", "description": "X coordinate in Global Display Coordinates"},
					"y":           map[string]interface{}{"type": "number", "description": "Y coordinate in Global Display Coordinates"},
					"duration":    map[string]interface{}{"type": "number", "description": "Duration to hover in seconds (default: 1.0)"},
					"application": map[string]interface{}{"type": "string", "description": "Application resource name (optional)"},
				},
				"required": []string{"x", "y"},
			},
			Handler: s.handleHover,
		},
		"gesture": {
			Name:        "gesture",
			Description: "Perform a multi-touch gesture (trackpad gestures). Uses Global Display Coordinates (top-left origin). Supports pinch, zoom, rotate, swipe, and force touch.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"center_x":     map[string]interface{}{"type": "number", "description": "Center X coordinate of gesture (Global Display Coordinates)"},
					"center_y":     map[string]interface{}{"type": "number", "description": "Center Y coordinate of gesture (Global Display Coordinates)"},
					"gesture_type": map[string]interface{}{"type": "string", "description": "Gesture type: pinch, zoom, rotate, swipe, force_touch", "enum": []string{"pinch", "zoom", "rotate", "swipe", "force_touch"}},
					"scale":        map[string]interface{}{"type": "number", "description": "Scale factor for pinch/zoom (e.g., 0.5 = zoom out, 2.0 = zoom in)"},
					"rotation":     map[string]interface{}{"type": "number", "description": "Rotation angle in degrees for rotate gesture"},
					"finger_count": map[string]interface{}{"type": "integer", "description": "Number of fingers for swipe (default: 2)"},
					"direction":    map[string]interface{}{"type": "string", "description": "Direction for swipe gesture only: up, down, left, right", "enum": []string{"up", "down", "left", "right"}},
					"application":  map[string]interface{}{"type": "string", "description": "Application resource name (optional)"},
				},
				"required": []string{"center_x", "center_y", "gesture_type"},
			},
			Handler: s.handleGesture,
		},

		// === EXISTING TOOLS ===
		"find_elements": {
			Name:        "find_elements",
			Description: "Find UI elements by criteria. Returns accessibility tree elements with role, text, position, and available actions.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent context (e.g., applications/{id} or applications/{id}/windows/{id})",
					},
					"selector": map[string]interface{}{
						"type":        "object",
						"description": "Criteria to match elements",
						"properties": map[string]interface{}{
							"role":  map[string]interface{}{"type": "string", "description": "Element role (e.g., button, textField)"},
							"text":  map[string]interface{}{"type": "string", "description": "Element text content"},
							"title": map[string]interface{}{"type": "string", "description": "Element title"},
						},
					},
				},
				"required": []string{"parent"},
			},
			Handler: s.handleFindElements,
		},
		"get_element": {
			Name:        "get_element",
			Description: "Get detailed information about a specific UI element including role, text, bounds, and available actions.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Element resource name (from find_elements result)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetElement,
		},
		"get_element_actions": {
			Name:        "get_element_actions",
			Description: "Get available actions for a specific UI element. Returns list of actions like 'press', 'increment', 'decrement'.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Element resource name (e.g., applications/123/elements/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetElementActions,
		},
		"click_element": {
			Name:        "click_element",
			Description: "Click on a UI element using accessibility APIs. More reliable than coordinate-based clicking for known elements.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent context (e.g., applications/{id}/windows/{id})",
					},
					"element_id": map[string]interface{}{
						"type":        "string",
						"description": "Element ID from find_elements result",
					},
				},
				"required": []string{"parent", "element_id"},
			},
			Handler: s.handleClickElement,
		},
		"write_element_value": {
			Name:        "write_element_value",
			Description: "Set the value of a UI element (e.g., text field). Uses accessibility APIs for reliable text entry.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent context (e.g., applications/{id}/windows/{id})",
					},
					"element_id": map[string]interface{}{
						"type":        "string",
						"description": "Element ID from find_elements result",
					},
					"value": map[string]interface{}{
						"type":        "string",
						"description": "Value to set",
					},
				},
				"required": []string{"parent", "element_id", "value"},
			},
			Handler: s.handleWriteElementValue,
		},
		"perform_element_action": {
			Name:        "perform_element_action",
			Description: "Perform an accessibility action on a UI element (e.g., press, increment, decrement, confirm).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent context (e.g., applications/{id}/windows/{id})",
					},
					"element_id": map[string]interface{}{
						"type":        "string",
						"description": "Element ID from find_elements result",
					},
					"action": map[string]interface{}{
						"type":        "string",
						"description": "Action to perform (from element's actions list)",
					},
				},
				"required": []string{"parent", "element_id", "action"},
			},
			Handler: s.handlePerformElementAction,
		},
		"list_windows": {
			Name:        "list_windows",
			Description: "List all open windows across all tracked applications.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent application to filter windows (optional)",
					},
					"page_size": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of windows to return per page (default: 100)",
					},
					"page_token": map[string]interface{}{
						"type":        "string",
						"description": "Token for pagination (from previous response, opaque to client)",
					},
				},
			},
			Handler: s.handleListWindows,
		},
		"get_window": {
			Name:        "get_window",
			Description: "Get details of a specific window including title, bounds, visibility, and z-index.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetWindow,
		},
		"focus_window": {
			Name:        "focus_window",
			Description: "Focus (activate) a window, bringing it to the front.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleFocusWindow,
		},
		"move_window": {
			Name:        "move_window",
			Description: "Move a window to a new position in global display coordinates (top-left origin).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
					"x": map[string]interface{}{
						"type":        "number",
						"description": "New X position (global display coordinates)",
					},
					"y": map[string]interface{}{
						"type":        "number",
						"description": "New Y position (global display coordinates)",
					},
				},
				"required": []string{"name", "x", "y"},
			},
			Handler: s.handleMoveWindow,
		},
		"resize_window": {
			Name:        "resize_window",
			Description: "Resize a window to new dimensions.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
					"width": map[string]interface{}{
						"type":        "number",
						"description": "New width in pixels",
					},
					"height": map[string]interface{}{
						"type":        "number",
						"description": "New height in pixels",
					},
				},
				"required": []string{"name", "width", "height"},
			},
			Handler: s.handleResizeWindow,
		},
		"minimize_window": {
			Name:        "minimize_window",
			Description: "Minimize a window to the dock.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleMinimizeWindow,
		},
		"restore_window": {
			Name:        "restore_window",
			Description: "Restore a minimized window.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleRestoreWindow,
		},
		"close_window": {
			Name:        "close_window",
			Description: "Close a window.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
					"force": map[string]interface{}{
						"type":        "boolean",
						"description": "Force close without saving (default: false)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleCloseWindow,
		},
		"list_displays": {
			Name:        "list_displays",
			Description: "List all connected displays with their frame coordinates, visible areas, and scale factors.",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleListDisplays,
		},
		"get_display": {
			Name:        "get_display",
			Description: "Get details of a specific display including frame, visible area, and whether it's the main display.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Display resource name (e.g., displays/12345)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetDisplay,
		},
		"cursor_position": {
			Name:        "cursor_position",
			Description: "Get the current cursor position in Global Display Coordinates (top-left origin). Returns X/Y coordinates and which display the cursor is on.",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleCursorPosition,
		},
		"get_clipboard": {
			Name:        "get_clipboard",
			Description: "Get clipboard contents. Supports text, RTF, HTML, images, files, and URLs.",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleGetClipboard,
		},
		"write_clipboard": {
			Name:        "write_clipboard",
			Description: "Write content to the clipboard.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"text": map[string]interface{}{
						"type":        "string",
						"description": "Text content to write to clipboard",
					},
				},
				"required": []string{"text"},
			},
			Handler: s.handleWriteClipboard,
		},
		"clear_clipboard": {
			Name:        "clear_clipboard",
			Description: "Clear all clipboard contents.",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleClearClipboard,
		},
		"get_clipboard_history": {
			Name:        "get_clipboard_history",
			Description: "Get clipboard history (if available). Returns historical clipboard entries most recent first.",
			InputSchema: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Handler: s.handleGetClipboardHistory,
		},

		// === APPLICATION TOOLS ===
		"open_application": {
			Name:        "open_application",
			Description: "Open an application by name, bundle ID, or path. The application will be launched and tracked for automation.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"id": map[string]interface{}{
						"type":        "string",
						"description": "Application identifier: name (e.g., 'Calculator'), bundle ID (e.g., 'com.apple.calculator'), or path (e.g., '/Applications/Calculator.app')",
					},
					"background": map[string]interface{}{
						"type":        "boolean",
						"description": "If true, open the app without stealing focus. Default: false (activates).",
					},
				},
				"required": []string{"id"},
			},
			Handler: s.handleOpenApplication,
		},
		"list_applications": {
			Name:        "list_applications",
			Description: "List all applications currently being tracked for automation.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"page_size": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of applications to return per page",
					},
					"page_token": map[string]interface{}{
						"type":        "string",
						"description": "Token for pagination (from previous response)",
					},
				},
			},
			Handler: s.handleListApplications,
		},
		"get_application": {
			Name:        "get_application",
			Description: "Get details of a specific tracked application.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., 'applications/1234')",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetApplication,
		},
		"delete_application": {
			Name:        "delete_application",
			Description: "Stop tracking an application. Does not terminate the application process.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., 'applications/1234')",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleDeleteApplication,
		},

		// === SCRIPTING TOOLS ===
		"execute_apple_script": {
			Name:        "execute_apple_script",
			Description: "Execute AppleScript code. Useful for automating macOS apps that expose AppleScript dictionaries.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"script": map[string]interface{}{
						"type":        "string",
						"description": "AppleScript source code to execute",
					},
					"timeout": map[string]interface{}{
						"type":        "integer",
						"description": "Timeout in seconds (default: 30)",
					},
				},
				"required": []string{"script"},
			},
			Handler: s.handleExecuteAppleScript,
		},
		"execute_javascript": {
			Name:        "execute_javascript",
			Description: "Execute JavaScript for Automation (JXA) code. Modern alternative to AppleScript with JavaScript syntax.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"script": map[string]interface{}{
						"type":        "string",
						"description": "JavaScript source code to execute",
					},
					"timeout": map[string]interface{}{
						"type":        "integer",
						"description": "Timeout in seconds (default: 30)",
					},
				},
				"required": []string{"script"},
			},
			Handler: s.handleExecuteJavaScript,
		},
		"execute_shell_command": {
			Name:        "execute_shell_command",
			Description: "Execute a shell command. Returns stdout, stderr, and exit code.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"command": map[string]interface{}{
						"type":        "string",
						"description": "Command to execute",
					},
					"args": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Command arguments",
					},
					"timeout": map[string]interface{}{
						"type":        "integer",
						"description": "Timeout in seconds (default: 30)",
					},
				},
				"required": []string{"command"},
			},
			Handler: s.handleExecuteShellCommand,
		},
		"validate_script": {
			Name:        "validate_script",
			Description: "Validate a script without executing. Useful for checking syntax before running dangerous operations.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"type": map[string]interface{}{
						"type":        "string",
						"description": "Script type: applescript, javascript, or shell",
						"enum":        []string{"applescript", "javascript", "shell"},
					},
					"script": map[string]interface{}{
						"type":        "string",
						"description": "Script source code to validate",
					},
				},
				"required": []string{"type", "script"},
			},
			Handler: s.handleValidateScript,
		},

		// === OBSERVATION TOOLS ===
		"create_observation": {
			Name:        "create_observation",
			Description: "Create an observation to monitor UI changes in an application. Observations can track element changes, window changes, or attribute changes.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent application (e.g., applications/{id})",
					},
					"type": map[string]interface{}{
						"type":        "string",
						"description": "Observation type: element_changes, window_changes, application_changes, attribute_changes, or tree_changes",
						"enum":        []string{"element_changes", "window_changes", "application_changes", "attribute_changes", "tree_changes"},
					},
					"visible_only": map[string]interface{}{
						"type":        "boolean",
						"description": "Only observe visible elements (default: false)",
					},
					"poll_interval": map[string]interface{}{
						"type":        "number",
						"description": "Poll interval in seconds for polling-based observations",
					},
					"roles": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Specific element roles to observe (empty = all roles)",
					},
					"attributes": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Specific attributes to observe (for attribute change observations)",
					},
					"activate": map[string]interface{}{
						"type":        "boolean",
						"description": "Activate (bring to foreground) the target app on each poll cycle (default: false). When false, polling is passive and does not disturb window ordering.",
					},
				},
				"required": []string{"parent"},
			},
			Handler: s.handleCreateObservation,
		},
		"stream_observations": {
			Name:        "stream_observations",
			Description: "Stream observation events in real-time. Returns a stream of ObservationEvent messages until the observation completes or is cancelled.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Observation resource name to stream (e.g., applications/{id}/observations/{obs})",
					},
					"timeout": map[string]interface{}{
						"type":        "number",
						"description": "Timeout in seconds for streaming (default: 300, max: 3600)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleStreamObservations,
		},
		"get_observation": {
			Name:        "get_observation",
			Description: "Get the current status of an observation.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Observation resource name",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetObservation,
		},
		"list_observations": {
			Name:        "list_observations",
			Description: "List all observations for an application.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent application (e.g., applications/{id}) or empty for all",
					},
				},
			},
			Handler: s.handleListObservations,
		},
		"cancel_observation": {
			Name:        "cancel_observation",
			Description: "Cancel an active observation.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Observation resource name to cancel",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleCancelObservation,
		},

		// === ACCESSIBILITY TOOLS ===
		"traverse_accessibility": {
			Name:        "traverse_accessibility",
			Description: "Traverse the full accessibility tree of an application. Returns all UI elements with their roles, text, and positions. Essential for UI discovery.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., applications/1234)",
					},
					"visible_only": map[string]interface{}{
						"type":        "boolean",
						"description": "Only return visible elements (default: false)",
					},
					"activate": map[string]interface{}{
						"type":        "boolean",
						"description": "Bring the target app to foreground before traversal (default: false). When false, traversal is passive and does not disturb window ordering.",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleTraverseAccessibility,
		},
		"get_window_state": {
			Name:        "get_window_state",
			Description: "Get the detailed accessibility state of a window including focused element and all UI elements.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Window resource name (e.g., applications/123/windows/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetWindowState,
		},
		"find_region_elements": {
			Name:        "find_region_elements",
			Description: "Find UI elements within a screen region. Uses Global Display Coordinates (top-left origin).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Application or window resource name",
					},
					"x":      map[string]interface{}{"type": "number", "description": "X coordinate of region origin"},
					"y":      map[string]interface{}{"type": "number", "description": "Y coordinate of region origin"},
					"width":  map[string]interface{}{"type": "number", "description": "Width of region in pixels"},
					"height": map[string]interface{}{"type": "number", "description": "Height of region in pixels"},
					"selector": map[string]interface{}{
						"type":        "object",
						"description": "Optional selector for additional filtering",
					},
				},
				"required": []string{"parent", "x", "y", "width", "height"},
			},
			Handler: s.handleFindRegionElements,
		},
		"wait_element": {
			Name:        "wait_element",
			Description: "Wait for an element matching a selector to appear. Polls until found or timeout.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Application or window resource name",
					},
					"selector": map[string]interface{}{
						"type":        "object",
						"description": "Element selector: {role, text, or text_contains}",
					},
					"timeout": map[string]interface{}{
						"type":        "number",
						"description": "Maximum wait time in seconds (default: 30)",
					},
					"poll_interval": map[string]interface{}{
						"type":        "number",
						"description": "Poll interval in seconds (default: 0.5)",
					},
				},
				"required": []string{"parent", "selector"},
			},
			Handler: s.handleWaitElement,
		},
		"wait_element_state": {
			Name:        "wait_element_state",
			Description: "Wait for an element to reach a specific state (enabled, focused, text matches).",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Application or window resource name",
					},
					"element_id": map[string]interface{}{
						"type":        "string",
						"description": "Element ID to wait on",
					},
					"condition": map[string]interface{}{
						"type":        "string",
						"description": "State condition: enabled, focused, text_equals, text_contains",
						"enum":        []string{"enabled", "focused", "text_equals", "text_contains"},
					},
					"value": map[string]interface{}{
						"type":        "string",
						"description": "Value for text_equals or text_contains conditions",
					},
					"timeout": map[string]interface{}{
						"type":        "number",
						"description": "Maximum wait time in seconds (default: 30)",
					},
					"poll_interval": map[string]interface{}{
						"type":        "number",
						"description": "Poll interval in seconds (default: 0.5)",
					},
				},
				"required": []string{"parent", "element_id", "condition"},
			},
			Handler: s.handleWaitElementState,
		},
		"capture_element_screenshot": {
			Name:        "capture_element_screenshot",
			Description: "Capture a screenshot of a specific UI element. Useful for focused visual feedback.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., applications/123)",
					},
					"element_id": map[string]interface{}{
						"type":        "string",
						"description": "Element ID to capture",
					},
					"format": map[string]interface{}{
						"type":        "string",
						"description": "Image format: png, jpeg, tiff",
						"enum":        []string{"png", "jpeg", "tiff"},
					},
					"quality": map[string]interface{}{
						"type":        "integer",
						"description": "JPEG quality (1-100)",
					},
					"padding": map[string]interface{}{
						"type":        "integer",
						"description": "Padding around element in pixels",
					},
					"include_ocr": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to include OCR text extraction",
					},
				},
				"required": []string{"parent", "element_id"},
			},
			Handler: s.handleCaptureElementScreenshot,
		},

		// === FILE DIALOG TOOLS ===
		"automate_open_file_dialog": {
			Name:        "automate_open_file_dialog",
			Description: "Automate interacting with an open file dialog. Navigate to a directory, select files, and confirm the selection.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"application": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., applications/TextEdit)",
					},
					"file_path": map[string]interface{}{
						"type":        "string",
						"description": "File path to select (if known)",
					},
					"default_directory": map[string]interface{}{
						"type":        "string",
						"description": "Default directory to navigate to",
					},
					"file_filters": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "File type filters (e.g., ['*.txt', '*.pdf'])",
					},
					"timeout": map[string]interface{}{
						"type":        "number",
						"description": "Timeout for dialog to appear in seconds",
					},
					"allow_multiple": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to allow multiple file selection",
					},
				},
				"required": []string{"application"},
			},
			Handler: s.handleAutomateOpenFileDialog,
		},
		"automate_save_file_dialog": {
			Name:        "automate_save_file_dialog",
			Description: "Automate interacting with a save file dialog. Navigate to a directory, enter filename, and confirm the save.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"application": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name (e.g., applications/TextEdit)",
					},
					"file_path": map[string]interface{}{
						"type":        "string",
						"description": "Full file path to save to",
					},
					"default_directory": map[string]interface{}{
						"type":        "string",
						"description": "Default directory to navigate to",
					},
					"default_filename": map[string]interface{}{
						"type":        "string",
						"description": "Default filename",
					},
					"timeout": map[string]interface{}{
						"type":        "number",
						"description": "Timeout for dialog to appear in seconds",
					},
					"confirm_overwrite": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to confirm overwrite if file exists",
					},
				},
				"required": []string{"application", "file_path"},
			},
			Handler: s.handleAutomateSaveFileDialog,
		},
		"select_file": {
			Name:        "select_file",
			Description: "Programmatically select a file in a file browser or dialog context.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"application": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name",
					},
					"file_path": map[string]interface{}{
						"type":        "string",
						"description": "File path to select",
					},
					"reveal_finder": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to reveal file in Finder after selection",
					},
				},
				"required": []string{"application", "file_path"},
			},
			Handler: s.handleSelectFile,
		},
		"select_directory": {
			Name:        "select_directory",
			Description: "Programmatically select a directory in a directory browser or dialog context.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"application": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name",
					},
					"directory_path": map[string]interface{}{
						"type":        "string",
						"description": "Directory path to select",
					},
					"create_missing": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to create directory if it doesn't exist",
					},
				},
				"required": []string{"application", "directory_path"},
			},
			Handler: s.handleSelectDirectory,
		},
		"drag_files": {
			Name:        "drag_files",
			Description: "Drag and drop files onto a target UI element. Simulates file drop operation.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"application": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name",
					},
					"file_paths": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "File paths to drag",
					},
					"target_element_id": map[string]interface{}{
						"type":        "string",
						"description": "Target element ID to drop files onto",
					},
					"duration": map[string]interface{}{
						"type":        "number",
						"description": "Drag duration in seconds",
					},
				},
				"required": []string{"application", "file_paths", "target_element_id"},
			},
			Handler: s.handleDragFiles,
		},

		// === SESSION TOOLS ===
		"create_session": {
			Name:        "create_session",
			Description: "Create a new session for coordinating complex workflows. Sessions maintain context across multiple operations.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"session_id": map[string]interface{}{
						"type":        "string",
						"description": "Optional session ID. If not provided, server generates one.",
					},
					"display_name": map[string]interface{}{
						"type":        "string",
						"description": "Display name for the session",
					},
					"metadata": map[string]interface{}{
						"type":        "object",
						"description": "Session-scoped metadata (key-value pairs)",
					},
				},
			},
			Handler: s.handleCreateSession,
		},
		"get_session": {
			Name:        "get_session",
			Description: "Get details of a specific session.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name (e.g., sessions/123)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetSession,
		},
		"list_sessions": {
			Name:        "list_sessions",
			Description: "List all sessions.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"page_size": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of sessions to return",
					},
					"page_token": map[string]interface{}{
						"type":        "string",
						"description": "Page token from a previous list call",
					},
				},
			},
			Handler: s.handleListSessions,
		},
		"delete_session": {
			Name:        "delete_session",
			Description: "Delete a session.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name",
					},
					"force": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether to force delete active sessions",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleDeleteSession,
		},
		"get_session_snapshot": {
			Name:        "get_session_snapshot",
			Description: "Get a snapshot of session state including applications, observations, and operation history.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetSessionSnapshot,
		},
		"begin_transaction": {
			Name:        "begin_transaction",
			Description: "Begin a transaction within a session. Transactions group operations atomically.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"session": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name",
					},
				},
				"required": []string{"session"},
			},
			Handler: s.handleBeginTransaction,
		},
		"commit_transaction": {
			Name:        "commit_transaction",
			Description: "Commit a transaction, applying all queued operations.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name",
					},
					"transaction_id": map[string]interface{}{
						"type":        "string",
						"description": "Transaction ID to commit",
					},
				},
				"required": []string{"name", "transaction_id"},
			},
			Handler: s.handleCommitTransaction,
		},
		"rollback_transaction": {
			Name:        "rollback_transaction",
			Description: "Rollback a transaction, discarding all queued operations.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Session resource name",
					},
					"transaction_id": map[string]interface{}{
						"type":        "string",
						"description": "Transaction ID to rollback",
					},
					"revision_id": map[string]interface{}{
						"type":        "string",
						"description": "Optional revision ID to rollback to",
					},
				},
				"required": []string{"name", "transaction_id"},
			},
			Handler: s.handleRollbackTransaction,
		},

		// === MACRO TOOLS ===
		"create_macro": {
			Name:        "create_macro",
			Description: "Create a new macro for recording and replaying action sequences.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"macro_id": map[string]interface{}{
						"type":        "string",
						"description": "Optional macro ID. If not provided, server generates one.",
					},
					"display_name": map[string]interface{}{
						"type":        "string",
						"description": "Display name for the macro",
					},
					"description": map[string]interface{}{
						"type":        "string",
						"description": "Description of what the macro does",
					},
					"tags": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "Tags for categorization",
					},
				},
				"required": []string{"display_name"},
			},
			Handler: s.handleCreateMacro,
		},
		"get_macro": {
			Name:        "get_macro",
			Description: "Get details of a specific macro including its actions.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Macro resource name (e.g., macros/123)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetMacro,
		},
		"list_macros": {
			Name:        "list_macros",
			Description: "List all macros.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"page_size": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of macros to return",
					},
					"page_token": map[string]interface{}{
						"type":        "string",
						"description": "Page token from a previous list call",
					},
				},
			},
			Handler: s.handleListMacros,
		},
		"delete_macro": {
			Name:        "delete_macro",
			Description: "Delete a macro.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Macro resource name",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleDeleteMacro,
		},
		"execute_macro": {
			Name:        "execute_macro",
			Description: "Execute a macro. Returns a long-running operation that can be tracked.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"macro": map[string]interface{}{
						"type":        "string",
						"description": "Macro resource name to execute",
					},
					"parameter_values": map[string]interface{}{
						"type":        "object",
						"description": "Parameter values for parameterized macros",
					},
				},
				"required": []string{"macro"},
			},
			Handler: s.handleExecuteMacro,
		},
		"update_macro": {
			Name:        "update_macro",
			Description: "Update an existing macro's metadata.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Macro resource name to update",
					},
					"display_name": map[string]interface{}{
						"type":        "string",
						"description": "New display name",
					},
					"description": map[string]interface{}{
						"type":        "string",
						"description": "New description",
					},
					"tags": map[string]interface{}{
						"type":        "array",
						"items":       map[string]interface{}{"type": "string"},
						"description": "New tags for categorization",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleUpdateMacro,
		},

		// === INPUT QUERY TOOLS ===
		"get_input": {
			Name:        "get_input",
			Description: "Get details of a specific input action by resource name.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Input resource name (e.g., applications/123/inputs/456)",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleGetInput,
		},
		"list_inputs": {
			Name:        "list_inputs",
			Description: "List input history for an application with optional filtering.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"parent": map[string]interface{}{
						"type":        "string",
						"description": "Parent application (e.g., applications/123). Use applications/- for all.",
					},
					"page_size": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of inputs to return",
					},
					"page_token": map[string]interface{}{
						"type":        "string",
						"description": "Page token from a previous list call",
					},
					"filter": map[string]interface{}{
						"type":        "string",
						"description": "Filter inputs by state: PENDING, EXECUTING, COMPLETED, FAILED",
					},
				},
			},
			Handler: s.handleListInputs,
		},

		// === SCRIPTING DICTIONARY TOOL ===
		"get_scripting_dictionaries": {
			Name:        "get_scripting_dictionaries",
			Description: "Get available AppleScript dictionaries for scriptable applications.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Resource name (usually 'scriptingDictionaries')",
					},
				},
			},
			Handler: s.handleGetScriptingDictionaries,
		},

		// === ACCESSIBILITY WATCH TOOL ===
		"watch_accessibility": {
			Name:        "watch_accessibility",
			Description: "Watch accessibility tree changes for an application. Returns initial snapshot. For continuous streaming, use stream_observations instead.",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Application resource name to watch",
					},
					"poll_interval": map[string]interface{}{
						"type":        "number",
						"description": "Poll interval in seconds",
					},
					"visible_only": map[string]interface{}{
						"type":        "boolean",
						"description": "Only report changes to visible elements",
					},
				},
				"required": []string{"name"},
			},
			Handler: s.handleWatchAccessibility,
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

	// Validate and normalize protocol version
	protocolVersion := params.ProtocolVersion
	switch protocolVersion {
	case mcpProtocolVersionCurrent:
		// Current version - all good
	case mcpProtocolVersionPrevious:
		log.Printf("WARN: MCP client using old protocol version %s, consider upgrading to %s", protocolVersion, mcpProtocolVersionCurrent)
	case "":
		log.Printf("WARN: MCP client did not specify protocolVersion, defaulting to %s", mcpProtocolVersionCurrent)
		protocolVersion = mcpProtocolVersionCurrent
	default:
		// Unsupported version - return error
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &transport.ErrorObj{
				Code:    transport.ErrCodeInvalidRequest,
				Message: fmt.Sprintf("unsupported protocol version: %s; supported versions are %s, %s", protocolVersion, mcpProtocolVersionPrevious, mcpProtocolVersionCurrent),
			},
		}, nil
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
	return &transport.Message{
		JSONRPC: "2.0",
		ID:      msg.ID,
		Result:  []byte(fmt.Sprintf(`{"protocolVersion":"%s","capabilities":{"tools":{},"resources":{"subscribe":false,"listChanged":false},"prompts":{}},"serverInfo":{"name":"macos-use-sdk","version":"0.1.0"},"displayInfo":%s}`, mcpProtocolVersionCurrent, displayInfo)),
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
		// Could be used for session lifecycle management in the future
		return nil, nil
	}

	// Handle shutdown request
	if msg.Method == "shutdown" {
		go func() {
			// Delay shutdown slightly to allow response to be sent
			time.Sleep(shutdownResponseDelay)
			s.Shutdown()
		}()
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  []byte(`{}`),
		}, nil
	}

	// Handle exit notification
	if msg.Method == "exit" {
		s.Shutdown()
		return nil, nil
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

		result, err := json.Marshal(map[string]interface{}{"tools": tools})
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
		resources := []map[string]interface{}{
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
		result, _ := json.Marshal(map[string]interface{}{"resources": resources})
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

		content, mimeType, err := s.readResource(params.URI)
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

		result, _ := json.Marshal(map[string]interface{}{
			"contents": []map[string]interface{}{
				{"uri": params.URI, "mimeType": mimeType, "text": content},
			},
		})
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle prompts/list request
	if msg.Method == "prompts/list" {
		prompts := s.listPrompts()
		result, _ := json.Marshal(map[string]interface{}{"prompts": prompts})
		return &transport.Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  result,
		}, nil
	}

	// Handle prompts/get request
	if msg.Method == "prompts/get" {
		var params struct {
			Arguments map[string]interface{} `json:"arguments"`
			Name      string                 `json:"name"`
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

		result, _ := json.Marshal(prompt)
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
		var args map[string]interface{}
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
			args = make(map[string]interface{})
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

	// Unknown method
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

	// Handle shutdown request
	if msg.Method == "shutdown" {
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

	// Handle exit notification
	if msg.Method == "exit" {
		s.Shutdown()
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

		result, err := json.Marshal(map[string]interface{}{"tools": tools})
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
		resources := []map[string]interface{}{
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
		result, _ := json.Marshal(map[string]interface{}{"resources": resources})
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

		content, mimeType, err := s.readResource(params.URI)
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

		result, _ := json.Marshal(map[string]interface{}{
			"contents": []map[string]interface{}{
				{"uri": params.URI, "mimeType": mimeType, "text": content},
			},
		})
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
		result, _ := json.Marshal(map[string]interface{}{"prompts": prompts})
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
			Arguments map[string]interface{} `json:"arguments"`
			Name      string                 `json:"name"`
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

		result, _ := json.Marshal(prompt)
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
		var args map[string]interface{}
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
			args = make(map[string]interface{})
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
		resultMap := map[string]interface{}{
			"content": result.Content,
		}
		if result.IsError {
			resultMap["is_error"] = true
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

	// Handle unknown method
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
	screens := make([]map[string]interface{}, 0, len(resp.Displays))

	for i, d := range resp.Displays {
		// Use display ID or index as identifier
		id := fmt.Sprintf("display-%d", i)
		if d.IsMain {
			id = "main"
		}

		dInfo := map[string]interface{}{
			"id":            id,
			"width":         d.Frame.Width,
			"height":        d.Frame.Height,
			"pixel_density": d.Scale,
			"origin_x":      d.Frame.X,
			"origin_y":      d.Frame.Y,
		}
		screens = append(screens, dInfo)
	}

	info := map[string]interface{}{
		"screens": screens,
	}

	infoBytes, err := json.Marshal(info)
	if err != nil {
		log.Printf("Warning: failed to marshal display info: %v", err)
		return `{"screens":[]}`
	}
	return string(infoBytes)
}

// readResource reads content for a resource URI.
// Supported URI schemes:
//   - screen://main: captures screenshot of main display, returns base64 PNG
//   - accessibility://{pid}: returns element tree JSON for application with given PID
//   - clipboard://current: returns current clipboard text content
func (s *MCPServer) readResource(uri string) (content string, mimeType string, err error) {
	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
	defer cancel()

	// Parse URI scheme
	if strings.HasPrefix(uri, "screen://") {
		// Handle screen://main - capture screenshot
		suffix := strings.TrimPrefix(uri, "screen://")
		if suffix != "main" {
			return "", "", fmt.Errorf("unsupported screen resource: %s (only 'main' is supported)", suffix)
		}

		// Capture screenshot of main display
		resp, err := s.client.CaptureScreenshot(ctx, &pb.CaptureScreenshotRequest{
			Format: pb.ImageFormat_IMAGE_FORMAT_PNG,
		})
		if err != nil {
			return "", "", fmt.Errorf("failed to capture screenshot: %w", err)
		}

		// Return base64-encoded image
		encoded := base64.StdEncoding.EncodeToString(resp.ImageData)
		return encoded, "image/png", nil
	}

	if strings.HasPrefix(uri, "accessibility://") {
		// Handle accessibility://{pid} - return element tree
		pidStr := strings.TrimPrefix(uri, "accessibility://")
		if pidStr == "" {
			return "", "", fmt.Errorf("accessibility:// requires a PID (e.g., accessibility://1234)")
		}

		pid, err := strconv.ParseInt(pidStr, 10, 32)
		if err != nil {
			return "", "", fmt.Errorf("invalid PID in accessibility URI: %s", pidStr)
		}

		// Build application resource name and traverse accessibility tree
		appName := fmt.Sprintf("applications/%d", pid)
		resp, err := s.client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
			Name: appName,
		})
		if err != nil {
			return "", "", fmt.Errorf("failed to traverse accessibility tree: %w", err)
		}

		// Convert elements to JSON
		elements := make([]map[string]interface{}, 0, len(resp.Elements))
		for _, elem := range resp.Elements {
			elemMap := map[string]interface{}{
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
				elemMap["bounds"] = map[string]interface{}{
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

		result := map[string]interface{}{
			"application":  appName,
			"elementCount": len(elements),
			"elements":     elements,
		}

		jsonBytes, err := json.Marshal(result)
		if err != nil {
			return "", "", fmt.Errorf("failed to marshal accessibility tree: %w", err)
		}
		return string(jsonBytes), "application/json", nil
	}

	if strings.HasPrefix(uri, "clipboard://") {
		// Handle clipboard://current - return clipboard text
		suffix := strings.TrimPrefix(uri, "clipboard://")
		if suffix != "current" {
			return "", "", fmt.Errorf("unsupported clipboard resource: %s (only 'current' is supported)", suffix)
		}

		resp, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{})
		if err != nil {
			return "", "", fmt.Errorf("failed to get clipboard: %w", err)
		}

		// Return text content (or indicate if empty/non-text)
		content := resp.GetContent()
		if content == nil {
			return "", "text/plain", nil // Empty clipboard
		}
		if text := content.GetText(); text != "" {
			return text, "text/plain", nil
		}
		if html := content.GetHtml(); html != "" {
			return html, "text/html", nil
		}
		if rtf := content.GetRtf(); len(rtf) > 0 {
			return string(rtf), "text/rtf", nil
		}
		if files := content.GetFiles(); files != nil && len(files.GetPaths()) > 0 {
			filesJSON, _ := json.Marshal(files.GetPaths())
			return string(filesJSON), "application/json", nil
		}
		if url := content.GetUrl(); url != "" {
			return url, "text/plain", nil
		}
		return "", "text/plain", nil // Empty clipboard
	}

	return "", "", fmt.Errorf("unsupported resource URI scheme: %s", uri)
}

// listPrompts returns the list of available MCP prompt templates.
func (s *MCPServer) listPrompts() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"name":        "navigate_to_element",
			"description": "Navigate to and click an accessibility element",
			"arguments": []map[string]interface{}{
				{"name": "selector", "description": "Element selector (role, text, or path)", "required": true},
				{"name": "action", "description": "Action to perform: click, double_click, right_click", "required": false},
			},
		},
		{
			"name":        "fill_form",
			"description": "Find and fill form fields with values",
			"arguments": []map[string]interface{}{
				{"name": "fields", "description": "JSON object mapping field names/labels to values", "required": true},
			},
		},
		{
			"name":        "verify_state",
			"description": "Verify an element matches expected state",
			"arguments": []map[string]interface{}{
				{"name": "selector", "description": "Element selector", "required": true},
				{"name": "expected_state", "description": "Expected state: visible, enabled, focused, or text value", "required": true},
			},
		},
	}
}

// getPrompt returns a specific prompt with argument substitution.
// Prompts return messages with role "user" per MCP specification.
func (s *MCPServer) getPrompt(name string, args map[string]interface{}) (map[string]interface{}, error) {
	switch name {
	case "navigate_to_element":
		selector := ""
		if v, ok := args["selector"]; ok {
			selector = fmt.Sprintf("%v", v)
		}
		action := "click"
		if v, ok := args["action"]; ok && v != nil && fmt.Sprintf("%v", v) != "" {
			action = fmt.Sprintf("%v", v)
		}

		content := fmt.Sprintf(`Find and interact with a UI element using the accessibility tree.

1. First, use traverse_accessibility or find_elements to locate the element matching: %s
2. Once found, perform the "%s" action on the element using click_element or perform_element_action
3. Verify the action completed successfully by checking for state changes

If the element is not immediately visible, you may need to:
- Scroll to reveal it
- Wait for it to appear using wait_element
- Check if it's in a different window`, selector, action)

		return map[string]interface{}{
			"description": "Navigate to and click an accessibility element",
			"messages": []map[string]interface{}{
				{
					"role": "user",
					"content": map[string]interface{}{
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
3. Use write_element_value or type_text to enter the value
4. Verify the value was entered correctly by reading the element's value

Common field roles:
- AXTextField: Single-line text input
- AXTextArea: Multi-line text input
- AXCheckBox: Checkbox (use perform_element_action with "press" to toggle)
- AXPopUpButton: Dropdown menu
- AXComboBox: Combo box with text and dropdown`, fieldsStr)

		return map[string]interface{}{
			"description": "Find and fill form fields with values",
			"messages": []map[string]interface{}{
				{
					"role": "user",
					"content": map[string]interface{}{
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
2. Use get_element to retrieve the element's current properties
3. Compare the element's state against the expected value:
   - "visible": Check that the element exists and is not hidden
   - "enabled": Check AXEnabled attribute is true
   - "focused": Check AXFocused attribute is true
   - For text values: Check AXValue or AXTitle matches the expected text

4. Report whether the verification passed or failed with details

If using wait_element_state, you can poll until the condition is met or timeout.`, selector, expectedState)

		return map[string]interface{}{
			"description": "Verify an element matches expected state",
			"messages": []map[string]interface{}{
				{
					"role": "user",
					"content": map[string]interface{}{
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
