package main

import (
	"errors"
	"os"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/config"
)

func TestSuperviseReturnsServeAndShutdownErrors(t *testing.T) {
	serveErr := errors.New("serve failed")
	shutdownErr := errors.New("shutdown failed")
	var shutdownCalls atomic.Int32

	err := supervise(
		func() error { return serveErr },
		func() error {
			shutdownCalls.Add(1)
			return shutdownErr
		},
		make(chan os.Signal),
	)

	if !errors.Is(err, serveErr) || !errors.Is(err, shutdownErr) {
		t.Fatalf("supervise error=%v, want joined serve and shutdown failures", err)
	}
	if got := shutdownCalls.Load(); got != 1 {
		t.Fatalf("shutdown calls=%d, want 1", got)
	}
}

func TestSuperviseSignalShutsDownAndReturnsSuccess(t *testing.T) {
	releaseServe := make(chan struct{})
	serveStarted := make(chan struct{})
	signals := make(chan os.Signal, 1)
	result := make(chan error, 1)
	var shutdownCalls atomic.Int32

	go func() {
		result <- supervise(
			func() error {
				close(serveStarted)
				<-releaseServe
				return nil
			},
			func() error {
				shutdownCalls.Add(1)
				close(releaseServe)
				return nil
			},
			signals,
		)
	}()

	select {
	case <-serveStarted:
	case <-time.After(time.Second):
		t.Fatal("serve did not start")
	}
	signals <- syscall.SIGTERM
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("signal-driven supervise returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("signal-driven supervise did not complete")
	}
	if got := shutdownCalls.Load(); got != 1 {
		t.Fatalf("shutdown calls=%d, want 1", got)
	}
}

func TestRunRejectsMissingCommand(t *testing.T) {
	if err := run(nil); err == nil {
		t.Fatal("run with no command returned nil error")
	}
}

func TestRunRejectsUnknownCommand(t *testing.T) {
	if err := run([]string{"bogus"}); err == nil {
		t.Fatal("run with unknown command returned nil error")
	}
}

func TestRunRejectsMCPArgs(t *testing.T) {
	if err := run([]string{"mcp", "extra"}); err == nil {
		t.Fatal("run mcp with extra args returned nil error")
	}
}

func TestRunHelpAndVersionSucceed(t *testing.T) {
	for _, args := range [][]string{{"help"}, {"version"}} {
		if err := run(args); err != nil {
			t.Fatalf("run %v returned error: %v", args, err)
		}
	}
}

func TestHTTPTransportConfigPreservesLoadedSecurityControls(t *testing.T) {
	loaded := &config.Config{
		HTTPAddress:      "127.0.0.1:9443",
		HTTPSocketPath:   "/tmp/exactmac-test.sock",
		CORSOrigin:       "https://trusted.example",
		HTTPReadTimeout:  19 * time.Second,
		HTTPWriteTimeout: 23 * time.Second,
		TLSCertFile:      "/secure/server.crt",
		TLSKeyFile:       "/secure/server.key",
		APIKey:           "secret-token",
		RateLimit:        7.5,
	}

	got := httpTransportConfig(loaded)

	if got.Address != loaded.HTTPAddress || got.SocketPath != loaded.HTTPSocketPath {
		t.Fatalf("listener identity was not preserved: got address=%q socket=%q", got.Address, got.SocketPath)
	}
	if got.CORSOrigin != loaded.CORSOrigin ||
		got.ReadTimeout != loaded.HTTPReadTimeout ||
		got.WriteTimeout != loaded.HTTPWriteTimeout {
		t.Fatalf("HTTP behavior was not preserved: got=%+v", got)
	}
	if got.TLSCertFile != loaded.TLSCertFile || got.TLSKeyFile != loaded.TLSKeyFile {
		t.Fatalf("TLS configuration was discarded: cert=%q key=%q", got.TLSCertFile, got.TLSKeyFile)
	}
	if got.APIKey != loaded.APIKey {
		t.Fatalf("API key was discarded: got=%q", got.APIKey)
	}
	if got.RateLimit != loaded.RateLimit {
		t.Fatalf("rate limit was discarded: got=%v want=%v", got.RateLimit, loaded.RateLimit)
	}
}
