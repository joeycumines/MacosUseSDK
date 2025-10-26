# Protobuf API Documentation

This directory contains the gRPC API definitions for MacosUseSDK.

## Overview

The API follows Google's [API Improvement Proposals (AIPs)](https://google.aip.dev/) and provides a resource-oriented interface for macOS UI automation.

## Structure

```
proto/
└── v1/
    ├── desktop.proto      # Desktop-level operations
    └── targets.proto      # Application target management
```

## Services

### DesktopService

Global desktop operations not tied to a specific application.

**Methods:**
- `OpenApplication`: Opens or activates an application, returning a TargetApplication resource
- `ExecuteGlobalInput`: Executes input actions globally (e.g., mouse clicks anywhere)

### TargetApplicationsService

Manages and automates specific application instances (PIDs).

**Standard Methods:**
- `GetTargetApplication`: Retrieves a specific target by resource name
- `ListTargetApplications`: Lists all tracked targets
- `DeleteTargetApplication`: Stops tracking a target (doesn't quit the app)

**Custom Methods:**
- `PerformAction`: Executes automation actions with optional before/after traversals and diffing
- `Watch`: Server-streaming RPC that streams accessibility tree changes in real-time

## Resources

### TargetApplication

Represents a running application instance being tracked by the server.

**Pattern:** `targetApplications/{pid}`

**Fields:**
- `name` (string): Resource name, e.g., "targetApplications/12345"
- `pid` (int32): Process ID (output only)
- `app_name` (string): Localized application name (output only)

## Message Types

### Input Actions

All input simulation types supported by the SDK:

- `Point`: Screen coordinates (x, y)
- `InputAction`: Click, double-click, right-click, type text, press key, move mouse
- `KeyPress`: Key combination (e.g., "cmd+c", "return")
- `PrimaryAction`: Input action or traverse-only operation

### Options and Results

- `ActionOptions`: Configuration for action execution (traversals, diffing, animations, delays)
- `ActionResult`: Complete result including traversal data and errors
- `ResponseData`: Accessibility tree traversal output
- `ElementData`: Individual UI element information
- `Statistics`: Traversal statistics (counts, role distribution)

### Diffing

- `TraversalDiff`: Changes between two traversals (added, removed, modified)
- `ModifiedElement`: Element that changed with detailed attribute changes
- `AttributeChangeDetail`: Specific attribute change (text, position, size)

## Code Generation

### For Swift (Server)

```bash
buf generate
```

Generates server stubs in `gen/swift/`

### For Go (Client)

```bash
buf generate
```

Generates client stubs in `gen/go/`

The Go module is `github.com/joeycumines/MacosUseSDK`.

## Linting

The API is validated using both `buf lint` and `api-linter` (Google's AIP linter).

```bash
# Buf linting
buf lint

# API linting (requires api-linter)
api-linter proto/**/*.proto
```

## Breaking Changes

Breaking changes are detected in CI:

```bash
buf breaking --against '.git#branch=main'
```

## Dependencies

- `buf.build/googleapis/googleapis`: Google API common protos (annotations, resources, etc.)

## Versioning

The API is versioned as `v1`. Breaking changes will result in a new version (v2, etc.).

## HTTP/JSON Mapping

All RPCs include HTTP annotations for gRPC-Gateway compatibility, enabling JSON/REST access:

```bash
# Example: Open application via HTTP/JSON
curl -X POST http://localhost:8080/v1/desktop:openApplication \
  -H "Content-Type: application/json" \
  -d '{"identifier": "Calculator"}'
```

(Note: HTTP/JSON transcoding requires additional configuration)
