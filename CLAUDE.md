# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MacosUseSDK is a macOS accessibility automation framework consisting of:
- **Swift library**: Core SDK using Accessibility APIs for UI traversal and input simulation
- **Command-line tools**: Standalone executables for common automation tasks
- **Swift gRPC server**: Production server with 77 MCP tools for AI agent integration
- **Go MCP server**: MCP proxy layer exposing functionality via Model Context Protocol

## Common Commands

### Building
```bash
# Full build (Swift + Go + Proto)
make all

# Via custom target (preferred - limits output)
make make-all-with-log  # Output logged to build.log, last 15 lines shown
```

### Testing
```bash
# All tests
make test

# Swift unit tests only
swift test
swift test --filter TestClassName/testMethodName

# Go unit tests only
make go.test

# Integration tests (requires macOS accessibility permissions)
make go.test.integration
```

### Code Generation
```bash
# Generate protobuf code
make generate
# or
make buf.generate

# Generate descriptor sets for reflection
make proto-generate-descriptors
```

### Linting and Formatting
```bash
# Format all
make fmt

# Lint all
make lint

# Run all linters (Go-specific)
make lint-all

# IMPORTANT: Use gmake for Go linters (not direct staticcheck invocation)
gmake go.staticcheck  # NOT: staticcheck ./...
gmake go.vet          # Runs go vet with proper flags
```

### Running the gRPC Server
```bash
cd Server && swift build -c release
./Server/.build/release/MacosUseServer

# With custom configuration
MCP_HTTP_ADDR=0.0.0.0:8080 MCP_API_KEY=secret ./Server/.build/release/MacosUseServer
```

## Critical Constraints (from AGENTS.md)

### Execution Protocol
- **NO DIRECT SHELL COMMANDS**: Use `config.mk` to define custom targets, then run via Make
- **CRITICAL**: Never specify the `file` option when invoking make - rely on repository's default Makefile discovery
- All `config.mk` recipes producing significant output MUST pipe to `tail` to avoid context window flooding
- Use `| tee $(PROJECT_ROOT)/build.log | tail -n 15` pattern for logging

### Testing Requirements
- **DO NOT BREAK THE BUILD**: Run `make make-all-with-log` after every file change
- **NO time.Sleep in tests**: Use `PollUntil` pattern for async verification
- Integration tests must ensure proper cleanup of observations and connections
- All new behavior MUST include automated tests in the same change set

### Logging Privacy
- **AVOID `fputs` or unannotated `print`** in Swift server components (`Server/Sources/MacosUseServer/`) and SDK (`Sources/MacosUseSDK/`)
- Use `Logger` with explicit `privacy` annotations for all interpolated values
- `print` is only allowed for static help text outside server/SDK directories

### API Design Standards
- Follow **Google's AIPs** (2025 standards) - when in doubt, Google's AIPs take precedence over `buf lint`
- Implement pagination (AIP-158) for ALL List/Find RPCs with opaque page tokens
- Tests MUST verify state deltas (accessor RPC after mutator RPC)
- Document coordinate systems explicitly: "Global Display Coordinates (top-left origin)" or "AppKit Coordinates (bottom-left origin)"

## High-Level Architecture

### Language Distribution
- **Swift**: Core library, gRPC server, command-line tools, AppKit integration
- **Go**: MCP server, config management, protobuf handling
- **Protocol Buffers**: gRPC API definitions

### State Management Architecture
The server uses a CQRS-style state management pattern:
- **AppStateStore**: Copy-on-write views for queries
- **WindowRegistry**: Window state tracking via Quartz/CGWindowListCopyWindowInfo
- **ObservationManager**: Real-time UI change monitoring
- **SessionManager**: Client session handling

### Hybrid Authority Model (Window State)
macOS provides two non-interoperable window APIs:
- **Quartz (CoreGraphics)**: Global, high-performance, read-only - authoritative for enumeration, metadata, window IDs
- **Accessibility (AX)**: Process-specific, synchronous - authoritative for geometry, visibility, mutations

Key architectural decisions:
- `ListWindows` uses Quartz only (fast, may lag 10-100ms)
- `GetWindow`/mutations use AX for correctness (fresh geometry)
- Bridging via private API `_AXUIElementGetWindow` with 1000px heuristic fallback

### Coordinate Systems (CRITICAL)
- **Global Display Coordinates**: Top-left origin, used by CGWindowList, AX, CGEvent, input APIs
- **AppKit Coordinates**: Bottom-left origin, used by NSWindow, NSScreen
- Window bounds and input positions BOTH use Global Display Coordinates (no conversion needed between them)
- Secondary displays can have negative coordinates (left/above main display)

### MCP Integration
- **77 MCP tools** exposed via HTTP/SSE or stdio transport
- Resource-oriented API following Google's AIPs
- Supports TLS, API key authentication, rate limiting, audit logging
- See `docs/05-mcp-integration.md` for protocol details

## Key Directories

- `Server/` - Swift gRPC server with Accessibility API integration
- `Sources/` - Swift SDK and command-line tools
- `internal/` - Go modules for config, server, transport
- `proto/` - Protocol buffer definitions (must mirror package structure)
- `integration/` - Integration tests (target Calculator, TextEdit, Finder)
- `make/` - Make build system modules
- `docs/` - Comprehensive documentation

## Important Files

- `AGENTS.md` - Implementation constraints and directives (READ THIS FIRST)
- `blueprint.json` - Master planning document (single source of truth for status)
- `CONTRIBUTING.md` - Development guidelines
- `Makefile` - Build orchestration
- `config.mk` - Custom build targets (create your own here)
- `docs/02-window-state-management.md` - Window state architecture (living document)

## Testing Philosophy

- **Atomic Testing**: All new behavior includes tests
- **Golden Applications**: Integration tests target TextEdit, Calculator, Finder
- **PollUntil Pattern**: Never use `time.Sleep` in tests; use `PollUntil` for async verification
- **State-Difference Assertions**: Verify state changes, not just "OK" status
- **Fixture Lifecycle**: Clean state (SIGKILL apps) before, aggressive cleanup after

## Proto API Structure

- Location: `proto/macosusesdk/v1/`
- Common types: `proto/macosusesdk/type/`
- Resource definitions separate from service definitions
- Naming follows Google AIPs 121, 190, 191
- Use `buf` for generation, `api-linter` for design validation

## CI/CD

- Entry point: `.github/workflows/ci.yaml`
- Uses reusable workflow patterns (`workflow_call`)
- Scripts must use explicit chaining (`&&`), not `set -e`
- Runs: lint, build, test, integration tests
