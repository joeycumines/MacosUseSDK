# MacosUseServer

A production-ready gRPC server providing a resource-oriented API layer around the MacosUseSDK.

## Architecture

The server follows a CQRS-style architecture with a central control loop:

### Core Components

1. **AutomationCoordinator** (`@MainActor`)
   - Central control loop running on the main thread
   - Coordinates ALL SDK interactions
   - Ensures thread-safety for UI operations
   - Processes commands and events asynchronously

2. **AppStateStore** (`actor`)
   - Thread-safe state management
   - Copy-on-write "view" of server state
   - Tracks all active target applications

3. **gRPC Service Providers**
   - `DesktopService`: Global desktop interactions
   - `TargetApplicationsService`: Per-application automation

### Concurrency Model

- **Main Actor**: All SDK calls execute on the main thread via `AutomationCoordinator`
- **Actor-based State**: `AppStateStore` provides serial access to shared state
- **gRPC Handlers**: Can run on any thread, coordinate through actors
- **Watch Streams**: Long-running streaming RPCs with periodic polling

## API Design

The gRPC API follows [Google's API Improvement Proposals (AIPs)](https://google.aip.dev/):

- **Resource-oriented**: `TargetApplication` resource with standard methods
- **Custom methods**: `:performAction` and `:watch` for specialized operations
- **Streaming**: Server-side streaming for real-time UI change detection

### Resources

#### TargetApplication

Represents a running application instance tracked by the server.

- Resource pattern: `targetApplications/{pid}`
- Standard methods: Get, List, Delete
- Custom methods: PerformAction, Watch

## Configuration

The server is configured via environment variables:

- `GRPC_LISTEN_ADDRESS`: IP address to bind to (default: `127.0.0.1`)
- `GRPC_PORT`: TCP port to listen on (default: `8080`)
- `GRPC_UNIX_SOCKET`: Unix socket path (overrides TCP if set)

## Building

### Prerequisites

- macOS 12+
- Swift 6.0+
- Xcode 15.2+ (for development)

### Build Steps

1. Generate gRPC stubs from protobuf definitions:
   ```bash
   cd ..
   buf generate
   ```

2. Build the server:
   ```bash
   swift build -c release
   ```

3. Run the server:
   ```bash
   .build/release/MacosUseServer
   ```

## Development

### Project Structure

```
Server/
├── Package.swift              # Swift package manifest
└── Sources/
    └── MacosUseServer/
        ├── main.swift                              # Server entry point
        ├── ServerConfig.swift                      # Configuration
        ├── AppStateStore.swift                     # State management
        ├── AutomationCoordinator.swift             # Main actor coordinator
        ├── DesktopServiceProvider.swift            # Desktop service impl
        └── TargetApplicationsServiceProvider.swift # Targets service impl
```

### Testing

Run tests with:
```bash
swift test
```

## Usage Examples

### Opening an Application

```bash
grpcurl -plaintext -d '{
  "identifier": "Calculator"
}' localhost:8080 macosusesdk.v1.DesktopService/OpenApplication
```

### Performing an Action

```bash
grpcurl -plaintext -d '{
  "name": "targetApplications/12345",
  "action": {
    "input": {
      "type_text": "1+2="
    }
  },
  "options": {
    "show_animation": true
  }
}' localhost:8080 macosusesdk.v1.TargetApplicationsService/PerformAction
```

### Watching for Changes

```bash
grpcurl -plaintext -d '{
  "name": "targetApplications/12345",
  "poll_interval_seconds": 1.0
}' localhost:8080 macosusesdk.v1.TargetApplicationsService/Watch
```

## Multi-Application Support

The server can track and automate multiple applications simultaneously:

1. Each `OpenApplication` call creates a new `TargetApplication` resource
2. Multiple clients can interact with different targets concurrently
3. The `AutomationCoordinator` serializes all SDK calls for thread-safety
4. State is maintained per-PID in the `AppStateStore`

## Performance Considerations

- All SDK calls are serialized on the main thread (macOS requirement)
- State queries are cheap (actor-based, copy-on-write)
- Watch streams use efficient differential updates
- Animation/visualization can be disabled for maximum throughput

## Security

- The server should only be exposed on localhost by default
- Use Unix sockets for local-only access
- TLS support can be added for remote access (requires certificates)

## Deployment

See the main [README](../README.md) for CI/CD and deployment information.
