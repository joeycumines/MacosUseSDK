# Deployment Guide

This guide covers deploying the MacosUseServer in various environments.

## Prerequisites

- macOS 12+
- Swift 6.0+
- Network access for gRPC clients

## Local Development

### 1. Generate Proto Stubs

```bash
make proto
```

This will:
- Update buf dependencies
- Generate Swift server stubs
- Generate Go client stubs

### 2. Build and Run

```bash
# Build the server
make server-build

# Run with default configuration (localhost:8080)
make server-run
```

### 3. Test with grpcurl

```bash
# Install grpcurl
brew install grpcurl

# Test the server
grpcurl -plaintext -d '{"identifier": "Calculator"}' \
  localhost:8080 macosusesdk.v1.DesktopService/OpenApplication
```

## Production Deployment

### Configuration Options

The server is configured via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | IP address to bind to |
| `GRPC_PORT` | `8080` | TCP port number |
| `GRPC_UNIX_SOCKET` | (none) | Unix socket path (overrides TCP) |

### Deployment Methods

#### Option 1: Direct Execution

Build a release binary:

```bash
cd Server
swift build -c release
```

Run with custom configuration:

```bash
export GRPC_LISTEN_ADDRESS="0.0.0.0"
export GRPC_PORT="9090"
.build/release/MacosUseServer
```

#### Option 2: Unix Socket (Recommended for Local Access)

Using a Unix socket provides better security for local-only access:

```bash
export GRPC_UNIX_SOCKET="/var/run/macosuse.sock"
.build/release/MacosUseServer
```

Client connection:

```go
conn, err := grpc.NewClient(
    "unix:///var/run/macosuse.sock",
    grpc.WithTransportCredentials(insecure.NewCredentials()),
)
```

#### Option 3: launchd Service (macOS System Service)

Create `/Library/LaunchDaemons/com.macosusesdk.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macosusesdk.server</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/MacosUseServer</string>
    </array>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>GRPC_UNIX_SOCKET</key>
        <string>/var/run/macosuse.sock</string>
    </dict>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>StandardOutPath</key>
    <string>/var/log/macosuse.log</string>
    
    <key>StandardErrorPath</key>
    <string>/var/log/macosuse.error.log</string>
</dict>
</plist>
```

Install and start:

```bash
# Copy binary
sudo cp Server/.build/release/MacosUseServer /usr/local/bin/

# Load service
sudo launchctl load /Library/LaunchDaemons/com.macosusesdk.server.plist

# Check status
sudo launchctl list | grep macosusesdk
```

## Security Considerations

### 1. Network Access

**Localhost Only (Recommended)**:
```bash
export GRPC_LISTEN_ADDRESS="127.0.0.1"
export GRPC_PORT="8080"
```

**All Interfaces (Use with Caution)**:
```bash
export GRPC_LISTEN_ADDRESS="0.0.0.0"
export GRPC_PORT="8080"
```

### 2. TLS/SSL (Coming Soon)

For remote access, TLS should be enabled:

```swift
// Future implementation
let server = Server.usingTLS(
    certificateChain: [...],
    privateKey: [...]
).withServiceProviders([...])
```

### 3. Authentication (Coming Soon)

Implement authentication interceptors:

```swift
// Future implementation
struct AuthInterceptor: ServerInterceptor {
    func intercept(request: ...) async throws -> ... {
        // Validate API key, JWT, etc.
    }
}
```

### 4. macOS Permissions

The server requires:

1. **Accessibility Permissions**: System Settings > Privacy & Security > Accessibility
2. **Screen Recording** (for visual feedback): System Settings > Privacy & Security > Screen Recording

Grant these permissions to the terminal or application running the server.

## Monitoring

### Health Checks

Use grpcurl for health checks:

```bash
grpcurl -plaintext localhost:8080 list
```

Expected output:
```
macosusesdk.v1.DesktopService
macosusesdk.v1.TargetApplicationsService
```

### Logging

The server logs to stderr. Redirect for persistent logs:

```bash
MacosUseServer 2>&1 | tee /var/log/macosuse.log
```

### Metrics (Future)

Integration with OpenTelemetry or Prometheus for metrics collection.

## Scaling

### Horizontal Scaling

Each server instance can:
- Track multiple applications independently
- Serve multiple clients concurrently
- Handle streaming connections efficiently

For distributed setups:
- Run multiple server instances on different machines
- Use a load balancer for client connections
- Coordinate via shared state (future: Redis, etcd, etc.)

### Resource Limits

Each target application adds minimal overhead:
- ~KB of memory for state tracking
- All SDK calls serialized on main thread (macOS requirement)
- Watch streams poll at configurable intervals

Typical limits:
- 100s of concurrent clients: No problem
- 10s of target applications: No problem
- Combining both: Monitor main thread saturation

## Troubleshooting

### Server Won't Start

1. Check permissions:
   ```bash
   xattr -d com.apple.quarantine MacosUseServer
   ```

2. Check accessibility:
   - System Settings > Privacy & Security > Accessibility
   - Add Terminal or your application

3. Check port availability:
   ```bash
   lsof -i :8080
   ```

### Client Connection Errors

1. Verify server is running:
   ```bash
   grpcurl -plaintext localhost:8080 list
   ```

2. Check firewall settings:
   ```bash
   sudo pfctl -s rules | grep 8080
   ```

3. Verify network configuration:
   ```bash
   netstat -an | grep 8080
   ```

### Performance Issues

1. Disable animations for throughput:
   ```protobuf
   options {
     show_animation: false
   }
   ```

2. Reduce watch polling frequency:
   ```protobuf
   watch_request {
     poll_interval_seconds: 2.0  // Increase from 1.0
   }
   ```

3. Filter to visible elements only:
   ```protobuf
   options {
     only_visible_elements: true
   }
   ```

## Backup and Recovery

### State Persistence

Currently, state is in-memory only. Tracked applications are:
- Lost on server restart
- Not shared between server instances

Future improvements:
- Persistent state storage
- State synchronization between instances
- Automatic reconnection to previously tracked apps

### Recovery Procedures

1. Server crash: Clients should reconnect automatically
2. App crash: Target becomes invalid, client gets error
3. Network partition: Clients should implement retry logic

## Updates and Rollbacks

### Updating the Server

1. Build new version:
   ```bash
   make server-build
   ```

2. Test in staging:
   ```bash
   GRPC_PORT=9090 make server-run
   ```

3. Graceful shutdown:
   ```bash
   kill -TERM $(pgrep MacosUseServer)
   ```

4. Deploy new version

### Rolling Back

Keep previous binary:

```bash
cp .build/release/MacosUseServer MacosUseServer.backup
# After update, if needed:
cp MacosUseServer.backup .build/release/MacosUseServer
```

## Production Checklist

- [ ] Proto stubs generated and committed
- [ ] Server builds successfully
- [ ] Accessibility permissions granted
- [ ] Screen recording permission granted (if using animations)
- [ ] Configuration tested (TCP or Unix socket)
- [ ] Health checks working
- [ ] Logging configured
- [ ] Monitoring in place
- [ ] Backup procedures documented
- [ ] Client libraries available
- [ ] Documentation up to date
