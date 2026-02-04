// Copyright 2025 Joseph Cumines
//
// MCP tool for MacosUseSDK - provides JSON-RPC 2.0 interface over stdio or HTTP/SSE

package main

import (
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

	// Start serving based on transport type
	wg.Add(1)
	go func() {
		defer wg.Done()
		var serveErr error
		switch cfg.Transport {
		case config.TransportHTTP:
			serveErr = runHTTPTransport(cfg, mcpServer)
		default:
			serveErr = runStdioTransport(cfg, mcpServer)
		}
		if serveErr != nil {
			errChan <- serveErr
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

// runStdioTransport runs the MCP server with stdio transport
func runStdioTransport(_ *config.Config, mcpServer *server.MCPServer) error {
	tr := transport.NewStdioTransport(os.Stdin, os.Stdout)
	return mcpServer.Serve(tr)
}

// runHTTPTransport runs the MCP server with HTTP/SSE transport
func runHTTPTransport(cfg *config.Config, mcpServer *server.MCPServer) error {
	httpCfg := &transport.HTTPTransportConfig{
		Address:           cfg.HTTPAddress,
		SocketPath:        cfg.HTTPSocketPath,
		HeartbeatInterval: cfg.HeartbeatInterval,
		CORSOrigin:        cfg.CORSOrigin,
		ReadTimeout:       cfg.HTTPReadTimeout,
		WriteTimeout:      cfg.HTTPWriteTimeout,
	}
	tr := transport.NewHTTPTransport(httpCfg)
	return mcpServer.ServeHTTP(tr)
}
