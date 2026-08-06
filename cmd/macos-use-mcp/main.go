// Copyright 2025 Joseph Cumines
//
// MCP tool for MacosUseSDK - provides JSON-RPC 2.0 over stdio or Streamable HTTP.

package main

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/server"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

func main() {
	if err := runMain(); err != nil {
		log.Printf("Server error: %v", err)
		os.Exit(1)
	}
}

func runMain() error {
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
