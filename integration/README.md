# Integration Tests

This directory contains end-to-end integration tests for the MacosUseSDK gRPC server.

## Overview

These tests verify the complete system works correctly by:

1. Starting the MacosUse gRPC server
2. Connecting to it via gRPC
3. Controlling real macOS applications
4. Verifying the results

## Running the Tests

### Via Makefile

```sh
make go.test.integration
```

### Manually

```sh
go -C integration test -v -timeout 5m
```

### Using an External Server

If you want to test against a server that's already running:

```sh
export INTEGRATION_SERVER_ADDR=localhost:50051
cd integration_test
go test -v -timeout 5m
```

### Skipping Integration Tests

Set the `SKIP_INTEGRATION_TESTS` environment variable to skip these tests:

```sh
export SKIP_INTEGRATION_TESTS=1
```

## Requirements

- macOS (these tests automate real macOS applications)
- Calculator app installed (standard macOS app)
- TextEdit app installed (standard macOS app)
- Accessibility permissions for the terminal/IDE running the tests
- Swift toolchain (for building the server)
