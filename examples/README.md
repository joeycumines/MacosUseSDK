# Examples

This directory contains example clients demonstrating how to use the MacosUseSDK gRPC API.

## Go Client Example

A comprehensive Go client example showing all major API features.

### Prerequisites

1. Start the MacosUseServer:
   ```bash
   cd ../..
   make server-run
   ```

2. Ensure proto stubs are generated:
   ```bash
   cd ../..
   make proto
   ```

### Running the Example

```bash
cd go-client
go run main.go
```

### What It Demonstrates

1. **Opening Applications**: Using `DesktopService.OpenApplication`
2. **Listing Targets**: Using `TargetApplicationsService.ListTargetApplications`
3. **Performing Actions**: Using `TargetApplicationsService.PerformAction` with options
4. **Watching for Changes**: Using `TargetApplicationsService.Watch` (streaming)
5. **Global Input**: Using `DesktopService.ExecuteGlobalInput`
6. **Resource Management**: Using `TargetApplicationsService.DeleteTargetApplication`

### Example Output

```
=== Example 1: Opening Calculator ===
Opened Calculator: Calculator (PID: 12345)

=== Example 2: Listing Tracked Applications ===
- Calculator (PID: 12345)

=== Example 3: Typing into Calculator ===
Diff - Added: 5, Removed: 0, Modified: 2

=== Example 4: Watching for UI changes ===
Watching for changes (press Ctrl+C to stop)...
Change detected - Added: 1, Removed: 0, Modified: 3
Change detected - Added: 0, Removed: 0, Modified: 1
...

=== Example 5: Global Mouse Click ===
Clicked at (500, 500)

=== Example 6: Cleanup ===
Removed targetApplications/12345 from tracking

=== All examples completed successfully ===
```

## Creating Your Own Client

### Go

1. Add dependency:
   ```bash
   go get github.com/joeycumines/MacosUseSDK
   ```

2. Import and use:
   ```go
   import (
       pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
       "google.golang.org/grpc"
   )

   conn, _ := grpc.NewClient("localhost:8080", grpc.WithTransportCredentials(insecure.NewCredentials()))
   client := pb.NewDesktopServiceClient(conn)
   ```

### Python

```bash
pip install grpcio grpcio-tools

# Generate stubs
python -m grpc_tools.protoc \
    -I../../proto \
    -I$(buf export buf.build/googleapis/googleapis --output -) \
    --python_out=. \
    --grpc_python_out=. \
    ../../proto/v1/*.proto
```

### Other Languages

See the [buf documentation](https://buf.build/docs/bsr/remote-generation/overview) for generating stubs in other languages.

## API Documentation

See [proto/README.md](../../proto/README.md) for detailed API documentation.

## Testing

All examples include error handling and demonstrate best practices for:
- Connection management
- Context usage
- Streaming RPC handling
- Resource lifecycle management
