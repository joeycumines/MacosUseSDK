# Implementation Notes

## Current Status

The gRPC server infrastructure is in place with:

1. ✅ Protobuf API definitions (desktop.proto, targets.proto)
2. ✅ Buf configuration (v2) with googleapis dependency
3. ✅ Swift server package structure
4. ✅ Core components (AppStateStore, AutomationCoordinator)
5. ✅ CI/CD workflows (buf, Swift, api-linter)

## Next Steps (Post Stub Generation)

The following will be completed once `buf generate` runs in CI with network access:

### 1. Proto Stub Generation

Run in CI:
```bash
buf dep update  # Resolves googleapis dependency
buf generate    # Generates Swift server stubs and Go client stubs
```

This will populate:
- `gen/swift/` - Swift server implementation files
- `gen/go/` - Go client library files
- `buf.lock` - Dependency lock file

### 2. Service Implementation

Update the following files to use generated proto types:

**DesktopServiceProvider.swift:**
```swift
import GRPC

final class DesktopServiceProvider: Macosusesdk_V1_DesktopServiceAsyncProvider {
    let stateStore: AppStateStore
    
    func openApplication(
        request: Macosusesdk_V1_OpenApplicationRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Macosusesdk_V1_TargetApplication {
        let target = try await AutomationCoordinator.shared.handleOpenApplication(
            identifier: request.identifier
        )
        await stateStore.addTarget(target)
        return convertToProto(target)
    }
    
    func executeGlobalInput(
        request: Macosusesdk_V1_ExecuteGlobalInputRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Google_Protobuf_Empty {
        try await AutomationCoordinator.shared.handleGlobalInput(
            action: convertFromProto(request.input),
            showAnimation: request.showAnimation,
            animationDuration: request.animationDuration
        )
        return Google_Protobuf_Empty()
    }
}
```

**TargetApplicationsServiceProvider.swift:**
```swift
import GRPC

final class TargetApplicationsServiceProvider: Macosusesdk_V1_TargetApplicationsServiceAsyncProvider {
    let stateStore: AppStateStore
    
    func getTargetApplication(...) async throws -> Macosusesdk_V1_TargetApplication { ... }
    func listTargetApplications(...) async throws -> Macosusesdk_V1_ListTargetApplicationsResponse { ... }
    func deleteTargetApplication(...) async throws -> Google_Protobuf_Empty { ... }
    func performAction(...) async throws -> Macosusesdk_V1_ActionResult { ... }
    func watch(..., responseStream: ...) async throws { ... }
}
```

**main.swift:**
```swift
import GRPC
import NIOCore
import NIOPosix

@main
struct MacosUseServer {
    static func main() async throws {
        let app = NSApplication.shared
        let config = ServerConfig.fromEnvironment()
        let stateStore = AppStateStore()
        
        let desktopService = DesktopServiceProvider(stateStore: stateStore)
        let targetsService = TargetApplicationsServiceProvider(stateStore: stateStore)
        
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer { try! group.syncShutdownGracefully() }
        
        var server = Server.insecure(group: group)
            .withServiceProviders([desktopService, targetsService])
        
        if let socketPath = config.unixSocketPath {
            try await server.bind(unixDomainSocketPath: socketPath).get()
        } else {
            try await server.bind(host: config.listenAddress, port: config.port).get()
        }
        
        RunLoop.main.run()
    }
}
```

### 3. Type Conversions

Create `ProtoMapper.swift` to convert between proto and SDK types:

```swift
enum ProtoMapper {
    static func convertToSDK(_ proto: Macosusesdk_V1_InputAction) -> MacosUseSDK.InputAction { ... }
    static func convertFromSDK(_ sdk: MacosUseSDK.ActionResult) -> Macosusesdk_V1_ActionResult { ... }
    // etc.
}
```

### 4. Integration Tests

Create integration tests using the generated Go client:

```go
package integration_test

import (
    "context"
    "testing"
    pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
    "google.golang.org/grpc"
)

func TestOpenApplication(t *testing.T) {
    conn, _ := grpc.Dial("localhost:8080", grpc.WithInsecure())
    defer conn.Close()
    
    client := pb.NewDesktopServiceClient(conn)
    resp, err := client.OpenApplication(context.Background(), &pb.OpenApplicationRequest{
        Identifier: "Calculator",
    })
    // assertions...
}
```

## CI/CD Flow

1. **Pull Request**: 
   - Buf lint and breaking change detection
   - API linter checks
   - Swift builds (SDK only, server waits for stubs)

2. **Main Branch Merge**:
   - All PR checks pass
   - `buf generate` runs, commits generated stubs
   - Server builds with generated stubs
   - Integration tests run

3. **Continuous**:
   - Generated stubs are committed to the repo
   - All developers have access to up-to-date types
   - No build breaks due to missing stubs

## Local Development

For local development without network access to BSR:

1. Wait for CI to generate stubs (first merge to main)
2. Pull the generated stubs from main
3. Develop against the generated types
4. Submit PRs with implementation changes

Alternatively, if you have BSR access:

```bash
buf dep update
buf generate
cd Server && swift build
```

## Architecture Benefits

- **Thread Safety**: All SDK calls serialized on main thread via AutomationCoordinator
- **Scalability**: Actor-based state management supports concurrent clients
- **Maintainability**: Clear separation between gRPC layer and SDK
- **Testability**: Each component can be tested independently
- **Resource-Oriented**: Clean API following industry best practices (AIPs)

## Performance Considerations

- State queries are fast (actor + copy-on-write)
- Watch streams use efficient polling with diffs
- Animation can be disabled for max throughput
- Multiple clients can share a single server instance
- Each target app can be automated concurrently (serialized by coordinator)
