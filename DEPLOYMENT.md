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

# Test with TCP (default server)
grpcurl -plaintext -d '{}' \
  localhost:8080 macosusesdk.v1.MacosUse/ListApplications

# Test with Unix socket
SOCKET="$HOME/Library/Caches/macosuse.sock"
grpcurl -plaintext -d '{}' \
  "unix://$SOCKET" \
  macosusesdk.v1.MacosUse/ListApplications

# List all available services
grpcurl -plaintext "unix://$SOCKET" list

# Get service reflection info (if enabled)
grpcurl -plaintext "unix://$SOCKET" grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo
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
# Use a user-writable location (recommended)
export GRPC_UNIX_SOCKET="$HOME/Library/Caches/macosuse.sock"
./Server/.build/release/MacosUseServer
```

**Socket Location Considerations:**

| Location                             | Notes                                                    |
|--------------------------------------|----------------------------------------------------------|
| `$HOME/Library/Caches/`              | User-writable, persists across reboots, easy permissions |
| `$HOME/Library/Application Support/` | User-writable, persists                                  |
| `/tmp/`                              | World-writable, ephemeral (deleted on reboot)            |
| `/var/run/`                          | Typically root-only, requires special handling           |

**Socket Permissions:**

The socket is created with permissions based on the server's `umask`. For security:

```sh
# Restrict to owner-only (most secure)
umask 0077 && ./Server/.build/release/MacosUseServer

# Allow owner and group (if clients share a group)
umask 0007 && ./Server/.build/release/MacosUseServer
```

Verify permissions after creation:

```sh
ls -la "$HOME/Library/Caches/macosuse.sock"
# Expected: srwx------  (600) for owner-only access
```

Test the Unix socket with grpcurl:

```sh
SOCKET="$HOME/Library/Caches/macosuse.sock"

# List available RPCs
grpcurl -plaintext "unix://$SOCKET" list

# Call a simple RPC
grpcurl -plaintext -d '{}' \
  "unix://$SOCKET" \
  macosusesdk.v1.DesktopService/GetHostname

# Call ListWindows with application filter
grpcurl -plaintext -d '{"application_name": "Finder"}' \
  "unix://$SOCKET" \
  macosusesdk.v1.DesktopService/ListWindows
```

Client connection (Go example using grpc-go):

```go
conn, err := grpc.Dial("unix://$HOME/Library/Caches/macosuse.sock", grpc.WithTransportCredentials(insecure.NewCredentials()))
if err != nil {
// handle error
}
defer conn.Close()
client := macosusesdkv1.NewDesktopServiceClient(conn)
```

#### Option 3: launchd Service (macOS System Service~/Library/Launch)

Create `Agents/com.macosusesdk.server.plist` (user agent, not system):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.macosusesdk.server</string>

        <key>ProgramArguments</key>
        <array>
            <string>/Users/YOU/bin/MacosUseServer</string>
        </array>

        <key>EnvironmentVariables</key>
        <dict>
            <key>GRPC_UNIX_SOCKET</key>
            <string>/Users/YOU/Library/Caches/macosuse.sock</string>
        </dict>

        <key>RunAtLoad</key>
        <true/>

        <key>KeepAlive</key>
        <true/>

        <key>StandardOutPath</key>
        <string>/Users/YOU/Library/Logs/macosuse.log</string>

        <key>StandardErrorPath</key>
        <string>/Users/YOU/Library/Logs/macosuse.error.log</string>
    </dict>
</plist>
```

Install and start:

```sh
# Copy binary to user bin
mkdir -p ~/bin
cp Server/.build/release/MacosUseServer ~/bin/

# Place the plist in user's LaunchAgents
cp com.macosusesdk.server.plist ~/Library/LaunchAgents/
chmod 600 ~/Library/LaunchAgents/com.macosusesdk.server.plist

# Load service
launchctl load ~/Library/LaunchAgents/com.macosusesdk.server.plist

# Check status
launchctl list | grep -i macosusesdk
```

**Note:** Use `~/Library/LaunchAgents/` (per-user) not `/Library/LaunchDaemons/` (system-wide) unless you need system-wide accessibility permissions. The server will use your user's socket location and permissions.

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
# TCP health check
grpcurl -plaintext localhost:8080 list

# Unix socket health check
SOCKET="$HOME/Library/Caches/macosuse.sock"
grpcurl -plaintext "unix://$SOCKET" list

# Quick connectivity test with GetHostname
grpcurl -plaintext -d '{}' \
  "unix://$SOCKET" \
  macosusesdk.v1.DesktopService/GetHostname
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
   # TCP
   grpcurl -plaintext localhost:8080 list

   # Unix socket
   SOCKET="$HOME/Library/Caches/macosuse.sock"
   grpcurl -plaintext "unix://$SOCKET" list
   ```

2. Check socket file exists and permissions:
   ```sh
   ls -la "$SOCKET"
   # Expected format: srwxr-xr-x (with 's' indicating socket)
   # Permissions should match umask used when server started
   ```

3. Socket permission denied:
   ```sh
   SOCKET="$HOME/Library/Caches/macosuse.sock"

   # If socket is world-writable, check group ownership
   chgrp staff "$SOCKET"  # Change group if needed
   chmod 660 "$SOCKET"    # Adjust as needed

   # Or restart server with restrictive umask
   umask 0077 && GRPC_UNIX_SOCKET="$SOCKET" ./MacosUseServer
   ```

4. Check firewall settings (TCP only):
   ```sh
   sudo pfctl -s rules | grep 8080
   ```

5. Verify network configuration (TCP only):
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

## Uninstallation

### Stop the Server

If running via launchd:

```sh
# User agent
launchctl unload ~/Library/LaunchAgents/com.macosusesdk.server.plist

# System daemon (if installed)
sudo launchctl unload /Library/LaunchDaemons/com.macosusesdk.server.plist
```

If running manually:

```sh
kill $(pgrep MacosUseServer)
```

### Remove Files

```sh
# Remove binary
rm -f ~/bin/MacosUseServer # User binary
sudo rm -f /usr/local/bin/MacosUseServer # System binary (if installed)

# Remove launchd plist
rm -f ~/Library/LaunchAgents/com.macosusesdk.server.plist
sudo rm -f /Library/LaunchDaemons/com.macosusesdk.server.plist

# Remove socket (may still exist if server didn't clean up)
rm -f "$HOME/Library/Caches/macosuse.sock"

# Remove logs
rm -f "$HOME/Library/Logs/macosuse.log"
rm -f "$HOME/Library/Logs/macosuse.error.log"

# Remove build artifacts (optional - source remains in repo)
rm -rf Server/.build/
```

### Remove Accessibility Permissions

If you want to revoke the server's accessibility access:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**
2. Remove **Terminal** or **iTerm2** (or whichever app you used to run the server)

### Remove Screen Recording Permission

1. Open **System Settings** > **Privacy & Security** > **Screen Recording**
2. Remove the application you used to run the server
