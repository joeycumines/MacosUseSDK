// Copyright 2025 Joseph Cumines
//
// ExactMac CLI - one Go binary. `exactmac mcp` serves the 29 CUA-aligned
// macOS automation tools over MCP (stdio by default, Streamable HTTP via
// MCP_TRANSPORT=streamable-http).

package main

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/joeycumines/ExactMac/internal/config"
	"github.com/joeycumines/ExactMac/internal/server"
	"github.com/joeycumines/ExactMac/internal/transport"
)

const usageText = `Usage: exactmac <command>

Commands:
  mcp         Run the MCP server (stdio by default; Streamable HTTP when
              MCP_TRANSPORT=streamable-http)
  help        Show this help
  version     Show version
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Printf("Server error: %v", err)
		os.Exit(1)
	}
}

// run dispatches the CLI. args is os.Args without the program name, so tests
// can drive dispatch without spawning a process.
func run(args []string) error {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usageText)
		return errors.New("no command provided")
	}
	switch args[0] {
	case "mcp":
		if len(args) > 1 {
			return fmt.Errorf("unknown arguments for mcp: %v", args[1:])
		}
		return runMCP()
	case "help", "-h", "--help":
		fmt.Fprint(os.Stderr, usageText)
		return nil
	case "version", "-v", "--version":
		fmt.Fprintln(os.Stderr, "exactmac 0.1.0")
		return nil
	default:
		fmt.Fprint(os.Stderr, usageText)
		return fmt.Errorf("unknown command: %q", args[0])
	}
}

func runMCP() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("failed to load configuration: %w", err)
	}

	mcpServer, err := server.NewMCPServer(cfg)
	if err != nil {
		return fmt.Errorf("failed to create MCP server: %w", err)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigChan)

	serve := func() error {
		switch cfg.Transport {
		case config.TransportHTTP:
			return runHTTPTransport(cfg, mcpServer)
		default:
			return runStdioTransport(cfg, mcpServer)
		}
	}
	return supervise(serve, mcpServer.Shutdown, sigChan)
}

func supervise(serve func() error, shutdown func() error, signals <-chan os.Signal) error {
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- serve()
	}()

	select {
	case sig := <-signals:
		log.Printf("Received signal %v, shutting down...", sig)
		shutdownErr := shutdown()
		select {
		case serveErr := <-serveDone:
			log.Println("Server shutdown complete")
			return errors.Join(serveErr, shutdownErr)
		case <-signals:
			log.Println("Forced shutdown")
			return shutdownErr
		}
	case serveErr := <-serveDone:
		if serveErr == nil {
			log.Println("Transport closed, shutting down...")
		}
		shutdownErr := shutdown()
		log.Println("Server shutdown complete")
		return errors.Join(serveErr, shutdownErr)
	}
}

// runStdioTransport runs the MCP server with stdio transport
func runStdioTransport(_ *config.Config, mcpServer *server.MCPServer) error {
	tr := transport.NewStdioTransport(os.Stdin, os.Stdout)
	return mcpServer.Serve(tr)
}

// runHTTPTransport runs the MCP server with Streamable HTTP transport.
func runHTTPTransport(cfg *config.Config, mcpServer *server.MCPServer) error {
	tr := transport.NewHTTPTransport(httpTransportConfig(cfg))
	return mcpServer.ServeHTTP(tr)
}

func httpTransportConfig(cfg *config.Config) *transport.HTTPTransportConfig {
	return &transport.HTTPTransportConfig{
		Address:      cfg.HTTPAddress,
		SocketPath:   cfg.HTTPSocketPath,
		CORSOrigin:   cfg.CORSOrigin,
		ReadTimeout:  cfg.HTTPReadTimeout,
		WriteTimeout: cfg.HTTPWriteTimeout,
		TLSCertFile:  cfg.TLSCertFile,
		TLSKeyFile:   cfg.TLSKeyFile,
		APIKey:       cfg.APIKey,
		RateLimit:    cfg.RateLimit,
	}
}
