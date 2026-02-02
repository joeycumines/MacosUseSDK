// Copyright 2025 Joseph Cumines
//
// MCP tool for MacosUseSDK - provides JSON-RPC 2.0 interface over stdio

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/server"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

func main() {
	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Create transport
	tr := transport.NewStdioTransport(os.Stdin, os.Stdout)

	// Create MCP server
	mcpServer, err := server.NewMCPServer(cfg)
	if err != nil {
		log.Fatalf("Failed to create MCP server: %v", err)
	}

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	var wg sync.WaitGroup
	errChan := make(chan error, 1)

	// Start serving
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := mcpServer.Serve(tr); err != nil {
			errChan <- err
		}
	}()

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Printf("Received signal %v, shutting down...", sig)
		mcpServer.Shutdown()
	case err := <-errChan:
		log.Printf("Server error: %v", err)
	}

	// Wait for graceful shutdown
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Println("Server shutdown complete")
	case <-sigChan:
		log.Println("Forced shutdown")
	}
}

// Message represents a JSON-RPC 2.0 message
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Message struct {
	Error   *ErrorObj
	JSONRPC string
	Method  string
	ID      json.RawMessage
	Params  json.RawMessage
	Result  json.RawMessage
}

// ErrorObj represents a JSON-RPC 2.0 error
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type ErrorObj struct {
	Message string
	Data    json.RawMessage
	Code    int
}

// ParseMessage parses a JSON-RPC 2.0 message
func ParseMessage(data []byte) (*Message, error) {
	var msg Message
	if err := json.Unmarshal(data, &msg); err != nil {
		return nil, fmt.Errorf("failed to parse message: %w", err)
	}
	return &msg, nil
}

// NewErrorResponse creates a new error response
func NewErrorResponse(id json.RawMessage, code int, message string) *Message {
	return &Message{
		JSONRPC: "2.0",
		ID:      id,
		Error: &ErrorObj{
			Code:    code,
			Message: message,
		},
	}
}

// NewResultResponse creates a new result response
func NewResultResponse(id json.RawMessage, result interface{}) (*Message, error) {
	resultBytes, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal result: %w", err)
	}
	return &Message{
		JSONRPC: "2.0",
		ID:      id,
		Result:  resultBytes,
	}, nil
}

// ReadMessage reads a JSON-RPC 2.0 message from a reader
func ReadMessage(r io.Reader) (*Message, error) {
	decoder := json.NewDecoder(r)
	var msg Message
	if err := decoder.Decode(&msg); err != nil {
		return nil, fmt.Errorf("failed to decode message: %w", err)
	}
	return &msg, nil
}

// WriteMessage writes a JSON-RPC 2.0 message to a writer
func WriteMessage(w io.Writer, msg *Message) error {
	encoder := json.NewEncoder(w)
	if err := encoder.Encode(msg); err != nil {
		return fmt.Errorf("failed to encode message: %w", err)
	}
	return nil
}
