# Integration Tests

This directory contains end-to-end integration tests for the MacosUseSDK gRPC server.

## Overview

These tests verify the complete system works correctly by:
1. Starting the MacosUse gRPC server
2. Connecting to it via gRPC
3. Controlling real macOS applications
4. Verifying the results

## Test Cases

### TestCalculatorAddition
- Opens the Calculator app
- Types "2+3="
- Reads the result from the UI
- Verifies the result is "5"

### TestCalculatorMultiplication
- Opens the Calculator app
- Types "7*8="
- Reads the result from the UI
- Verifies the result is "56"

### TestServerHealthCheck
- Verifies the server starts and responds to basic requests
- Lists tracked applications

## Running the Tests

### Via Makefile (Recommended)
```bash
make integration-test
```

### Manually
```bash
cd integration_test
go test -v -timeout 5m
```

### Using an External Server
If you want to test against a server that's already running:
```bash
export INTEGRATION_SERVER_ADDR=localhost:50051
cd integration_test
go test -v -timeout 5m
```

### Skipping Integration Tests
Set the `SKIP_INTEGRATION_TESTS` environment variable to skip these tests:
```bash
export SKIP_INTEGRATION_TESTS=1
```

## Requirements

- macOS (these tests automate real macOS applications)
- Calculator app installed (standard macOS app)
- Accessibility permissions for the terminal/IDE running the tests
- Swift toolchain (for building the server)

## Implementation Details

The tests demonstrate all major features of the MacosUseSDK API:
- Long-running operations (OpenApplication)
- Application lifecycle management (GetApplication, DeleteApplication)
- Input actions (CreateInput with text input)
- Accessibility tree traversal (TraverseAccessibility)
- Resource naming and hierarchy

The tests use a retry mechanism for server connection and poll-based waiting for long-running operations, making them resilient to timing variations.
