# Integration Tests

This directory contains end-to-end integration tests for the ExactMac gRPC server.

## Overview

These tests verify the complete system works correctly by:

1. Starting the ExactMac gRPC server
2. Connecting to it via gRPC
3. Controlling real macOS applications
4. Verifying the results

## Running the Tests

Integration tests are gated by `TestMain`. Ordinary `go test` discovery compiles the package but does not launch the server or golden applications; pass `-integration` to run the suite.

### Via Makefile

```sh
gmake go.test.integration GO_TEST_FLAGS="-integration"
```

### Manually

```sh
go -C integration test -integration -v -timeout 5m
```

### Using an External Server

If you want to test against a server that's already running:

```sh
export INTEGRATION_SERVER_ADDR=localhost:50051
go -C integration test -integration -v -timeout 5m
```

## Requirements

- macOS (these tests automate real macOS applications)
- Calculator app installed (standard macOS app)
- TextEdit app installed (standard macOS app)
- Accessibility permissions for the terminal/IDE running the tests
- Swift toolchain (for building the server)
