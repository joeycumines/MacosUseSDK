# Deployment Guide

This guide covers deploying the **MacosUseServer** (gRPC Swift server) in various environments.

## Prerequisites

- macOS 15+ (required to build/run the gRPC Swift server - Swift 6 concurrency features).
- Swift 6.0+ (toolchain matching `// swift-tools-version: 6.0` in `Server/Package.swift`).
- **GNU Make 4.x+** (required by the project's Makefile):
  ```sh
  brew install make
  ```
  The Makefile uses `gmake` as the command name. On macOS, install GNU make via Homebrew and ensure `gmake` is in your PATH.

## Build Commands Quick Reference

```sh
# View available Make targets (this is `gmake help`)
gmake help

# Build the release binary (default configuration: release)
gmake swift.build

# The binary will be at:
Server/.build/release/MacosUseServer
```

## Local Development

### 1. Generate Proto Stubs

Preferred (explicit):

```sh
buf generate
```

Alternative (project Makefile wrapper):

```sh
gmake generate # or: gmake regenerate-proto
```

This will update buf dependencies and generate Swift server stubs and Go client stubs.

### 2. Build and Run (Local development)

Build the release binary:

```sh
gmake swift.build
```

The default build configuration is `release` (defined in `make/swift.mk` as `SWIFT_CONFIGURATION ?= release`).

You can run the server directly (default: loopback + port 8080):

```sh
./Server/.build/release/MacosUseServer
```

### 3. Test with grpcurl

```sh
# Install grpcurl
brew install grpcurl

# Test the server
grpcurl -plaintext -d '{"identifier": "Calculator"}' \
  localhost:8080 macosusesdk.v1.DesktopService/OpenApplication
```

## Production Deployment

### Configuration Options

The server is configured via environment variables:

| Variable              | Default     | Description                                 |
|-----------------------|-------------|---------------------------------------------|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | IP address to bind to (loopback by default) |
| `GRPC_PORT`           | `8080`      | TCP port number                             |
| `GRPC_UNIX_SOCKET`    | (none)      | Unix socket path (overrides TCP)            |

**Loopback Listening (Default)**:
By default, the server binds to `127.0.0.1` (loopback), accepting only local connections:

```sh
# Default: listens on loopback interface only
./Server/.build/release/MacosUseServer
```

### Deployment Methods

#### Option 1: Direct Execution

Build a release binary:

```sh
gmake swift.build
```

Run with custom configuration:

```sh
# Explicitly set loopback address (redundant, but clear)
export GRPC_LISTEN_ADDRESS="127.0.0.1"
export GRPC_PORT="9090"
./Server/.build/release/MacosUseServer
```

#### Option 2: Unix Socket (Recommended for Local Access)

Using a Unix socket provides better security for local-only access:

```sh
export GRPC_UNIX_SOCKET="/var/run/macosuse.sock"
./Server/.build/release/MacosUseServer
```

Client connection (Go example using grpc-go):

```go
conn, err := grpc.Dial("unix:///var/run/macosuse.sock", grpc.WithTransportCredentials(insecure.NewCredentials()))
if err != nil {
// handle error
}
defer conn.Close()
client := macosusesdkv1.NewDesktopServiceClient(conn)
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

Install and start (ensure plist ownership and permissions):

```sh
# Copy binary
sudo cp Server/.build/release/MacosUseServer /usr/local/bin/

# Place the plist and set ownership/permissions
sudo cp com.macosusesdk.server.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.macosusesdk.server.plist
sudo chmod 644 /Library/LaunchDaemons/com.macosusesdk.server.plist

# Load service
sudo launchctl bootstrap system /Library/LaunchDaemons/com.macosusesdk.server.plist

# Check status
sudo launchctl list | grep -i macosusesdk
```

## Security Considerations

### 1. Network Access

**Localhost Only (Recommended - Default)**:

```sh
# Already the default - no configuration needed
./Server/.build/release/MacosUseServer
```

**All Interfaces (Use with Caution)**:

```sh
export GRPC_LISTEN_ADDRESS="0.0.0.0"
export GRPC_PORT="8080"
./Server/.build/release/MacosUseServer
```

### 2. TLS/SSL

For remote access, TLS should be enabled. The server is configured with plaintext by default for local development; production deployments should enable TLS using the gRPC Swift transport security options.

Example (conceptual):

```swift
// Configure transportSecurity with certificates (gRPC Swift transport options vary by version)
// See gRPC Swift docs for exact APIs when enabling TLS.
```

### 3. Authentication

Authentication is not implemented in this example server. For production, add server-side interceptors (API keys, JWT/OAuth, mTLS) using gRPC Swift interceptor APIs.

### 4. macOS Permissions

The server requires:

1. **Accessibility Permissions**: System Settings > Privacy & Security > Accessibility
2. **Screen Recording** (for visual feedback): System Settings > Privacy & Security > Screen Recording

Grant these permissions to the terminal or application running the server.

## Monitoring

### Health Checks

Use `grpcurl` for simple health checks and listing services:

```sh
grpcurl -plaintext localhost:8080 list
```

Expected output (example):

```
macosusesdk.v1.DesktopService
macosusesdk.v1.TargetApplicationsService
```

### Logging

The server logs to stderr. Redirect for persistent logs:

```sh
./Server/.build/release/MacosUseServer 2>&1 | tee /var/log/macosuse.log
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
   ```sh
   xattr -d com.apple.quarantine MacosUseServer
   ```

2. Check accessibility:
    - System Settings > Privacy & Security > Accessibility
    - Add Terminal or your application

3. Check port availability:
   ```sh
   lsof -i :8080
   ```

### Client Connection Errors

1. Verify server is running:
   ```sh
   grpcurl -plaintext localhost:8080 list
   ```

2. Check firewall settings:
   ```sh
   sudo pfctl -s rules | grep 8080
   ```

3. Verify network configuration:
   ```sh
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
   ```sh
   gmake swift.build
   ```

2. Test in staging:
   ```sh
   GRPC_PORT=9090 ./Server/.build/release/MacosUseServer
   ```

3. Graceful shutdown:
   ```sh
   kill -TERM $(pgrep MacosUseServer)
   ```

4. Deploy new version

### Rolling Back

Keep previous binary:

```sh
cp Server/.build/release/MacosUseServer MacosUseServer.backup
# After update, if needed:
cp MacosUseServer.backup Server/.build/release/MacosUseServer
```
