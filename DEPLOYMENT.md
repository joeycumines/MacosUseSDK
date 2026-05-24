# Deployment Guide

This guide covers deploying the **MacosUseServer** (gRPC Swift server) locally
with macOS TCC permissions (Accessibility + Screen Recording) and connecting an
MCP client (opencode) to it.

## Prerequisites

- **macOS 15+** (Sequoia — required for Swift 6 concurrency features)
- **Swift 6.0+** (matching `// swift-tools-version: 6.0` in `Server/Package.swift`)
- **Go 1.22+** (for the MCP proxy `cmd/macos-use-mcp`)
- **GNU Make 4.x+** (`brew install make`; invoked as `gmake`)
- **grpcurl** (`brew install grpcurl`; for manual testing)

## Architecture

```
┌───────────┐     stdio/SSE     ┌──────────────────┐     gRPC      ┌──────────────────┐
│  opencode │◄─────────────────►│  macos-use-mcp   │◄─────────────►│  MacosUseServer  │
│  (AI)     │                   │  (Go binary)     │  unix socket  │  (Swift binary)  │
└───────────┘                   └──────────────────┘               └──────────────────┘
```

Two separate processes:
1. **MacosUseServer** — Swift gRPC server that talks to macOS Accessibility,
   ScreenCaptureKit, and CGEvent APIs. Must run inside an `.app` bundle for
   TCC to track its bundle identifier.
2. **macos-use-mcp** — Go MCP proxy that translates MCP tool calls into gRPC
   requests to the Swift server. No macOS permissions needed.

## Step-by-Step Local Deployment

### Step 1: Build the Swift Server

```sh
gmake swift.build
```

Binary location: `Server/.build/release/MacosUseServer`

### Step 2: Build the Go MCP Proxy

```sh
go build -o /Users/YOU/go/bin/macos-use-mcp ./cmd/macos-use-mcp
```

### Step 3: Create the .app Bundle

The Swift server **must** run inside a proper `.app` bundle so that macOS TCC
(Transparency, Consent, and Control) can identify it by bundle identifier.
Without the `.app` wrapper, TCC has no stable identity to grant permissions to.

```sh
# Create the minimal .app bundle structure
mkdir -p ~/Applications/MacosUseServer.app/Contents/MacOS
mkdir -p ~/Applications/MacosUseServer.app/Contents/Resources

# Copy the release binary
cp Server/.build/release/MacosUseServer \
   ~/Applications/MacosUseServer.app/Contents/MacOS/MacosUseServer

# Create Info.plist with a stable bundle identifier
cat > ~/Applications/MacosUseServer.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacosUseServer</string>
    <key>CFBundleIdentifier</key>
    <string>com.macosusesdk.server</string>
    <key>CFBundleName</key>
    <string>MacosUseServer</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Register the bundle identifier with LaunchServices
# This is REQUIRED for TCC to recognize the bundle identifier
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f ~/Applications/MacosUseServer.app
```

**Why `LSUIElement` is `true`:** The server has no GUI. Setting this prevents
it from appearing in the Dock or Cmd+Tab switcher.

### Step 4: Ad-Hoc Code Sign the .app

```sh
codesign --force --deep --sign - ~/Applications/MacosUseServer.app
```

### Step 5: Grant macOS Permissions

The server needs two TCC permissions. After starting the server (Step 6),
macOS will prompt for each on first use:

| Permission       | Triggered By              | Purpose                                    |
|------------------|---------------------------|-------------------------------------------|
| Accessibility    | `TraverseAccessibility`  | Reading and controlling UI elements via AX |
| Screen Recording | `CaptureScreenshot`       | Capturing screen/window/region screenshots |

**To grant manually (or if the prompt was dismissed):**

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click **+**, navigate to `~/Applications/MacosUseServer.app`, add it
3. Toggle the switch **ON**
4. Repeat for **Screen Recording**

**To reset a previously-denied permission:**

```sh
# Reset Accessibility permission (requires re-granting)
tccutil reset Accessibility com.macosusesdk.server

# Reset Screen Recording permission
tccutil reset ScreenCapture com.macosusesdk.server
```

**NOTE:** `tccutil reset` only works after `lsregister -f` has registered the
bundle identifier. If you get "No matching bundle identifier found", re-run
the `lsregister` command from Step 3.

### Step 6: Create the launchd Service

Create `~/Library/LaunchAgents/com.macosusesdk.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macosusesdk.server</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOU/Applications/MacosUseServer.app/Contents/MacOS/MacosUseServer</string>
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

**Socket permissions (0600) are enforced by the server code** — the launchd
`Umask` key is unreliable for socket permissions and is intentionally omitted.

```sh
# Load the service (modern API)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.macosusesdk.server.plist

# Verify it's running
launchctl print gui/$(id -u) | grep com.macosusesdk.server

# Verify the socket exists with correct permissions
ls -la "$HOME/Library/Caches/macosuse.sock"
# Expected: srw------- (0600 — owner read/write only, no execute)
```

### Step 7: Verify the Server is Running

Use the MCP tools (Step 9) to verify. The gRPC server does not support
reflection from the `.app` bundle (the `Bundle.module` resource accessor
cannot find the descriptor sets), so `grpcurl` cannot be used for
discovery or listing.

If the MCP tools return data, the server is working. If you get connection
errors, check the logs:

```sh
cat ~/Library/Logs/macosuse.error.log
```

### Step 8: Configure the MCP Client (opencode)

Create a project-level `opencode.jsonc` in the repo root:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "macos-use": {
      "type": "local",
      "command": ["/Users/YOU/go/bin/macos-use-mcp"],
      "enabled": true,
      "environment": {
        "MACOS_USE_SERVER_SOCKET_PATH": "/Users/YOU/Library/Caches/macosuse.sock"
      },
      "timeout": 10000
    }
  }
}
```

**Why project-level?** This keeps MCP tools scoped to this repo only. The
global `~/.config/opencode/opencode.jsonc` should NOT contain the `macos-use`
entry — otherwise the tools activate in every project.

**Key env vars for `macos-use-mcp`:**

| Variable                        | Default             | Description                                    |
|---------------------------------|---------------------|------------------------------------------------|
| `MACOS_USE_SERVER_SOCKET_PATH`  | (none)              | Unix socket path to the Swift gRPC server       |
| `MACOS_USE_SERVER_ADDR`         | `localhost:50051`   | TCP address (used if socket path is empty)       |
| `MCP_TRANSPORT`                 | `stdio`             | MCP transport: `stdio` or `sse`                 |
| `MCP_HTTP_ADDRESS`              | `:8080`             | HTTP listen address (SSE transport only)        |
| `MCP_API_KEY`                   | (none)              | Bearer token auth (if set, all requests need it)|
| `MCP_RATE_LIMIT`                | `0` (disabled)      | Rate limit in requests/second                   |

When `MACOS_USE_SERVER_SOCKET_PATH` is set, `MACOS_USE_SERVER_ADDR` is ignored.

### Step 9: Verify End-to-End

Open an opencode session in this repo and test the MCP tools:

1. **No-permission test** (uses Quartz/CGWindowList, no TCC needed):
   ```
   macos-use_list_applications
   macos-use_list_windows
   macos-use_list_displays
   ```

2. **Accessibility test** (triggers AX permission prompt on first use):
   ```
   macos-use_open_application  (id: "Calculator")
   macos-use_traverse_accessibility  (name: "applications/{pid}")
   ```

3. **Screen Recording test** (triggers Screen Recording prompt on first use):
   ```
   macos-use_capture_screenshot
   ```

## Swift Server Configuration

The Swift server (`MacosUseServer`) is configured via environment variables:

| Variable              | Default     | Description                                 |
|-----------------------|-------------|---------------------------------------------|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | IP address to bind to (loopback by default) |
| `GRPC_PORT`           | `8080`      | TCP port number                             |
| `GRPC_UNIX_SOCKET`    | (none)      | Unix socket path (overrides TCP if set)      |

When `GRPC_UNIX_SOCKET` is set, the server ignores `GRPC_LISTEN_ADDRESS` and
`GRPC_PORT` and listens only on the Unix socket.

## Updating After a Rebuild

After rebuilding the Swift server:

```sh
# 1. Stop the service
launchctl bootout gui/$(id -u)/com.macosusesdk.server

# 2. Copy the new binary into the .app
cp Server/.build/release/MacosUseServer \
   ~/Applications/MacosUseServer.app/Contents/MacOS/MacosUseServer

# 3. Re-sign
codesign --force --deep --sign - ~/Applications/MacosUseServer.app

# 4. Start the service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.macosusesdk.server.plist
```

## Uninstallation

```sh
# Stop the service
launchctl bootout gui/$(id -u)/com.macosusesdk.server

# Remove files
rm -rf ~/Applications/MacosUseServer.app
rm -f  ~/Library/LaunchAgents/com.macosusesdk.server.plist
rm -f  "$HOME/Library/Caches/macosuse.sock"
rm -f  ~/Library/Logs/macosuse.log
rm -f  ~/Library/Logs/macosuse.error.log

# Revoke TCC permissions (optional)
tccutil reset Accessibility com.macosusesdk.server
tccutil reset ScreenCapture com.macosusesdk.server
```

## Security Considerations

### Network Access

The server defaults to **loopback only** (`127.0.0.1`). For local MCP use,
Unix sockets are recommended — they bypass the network stack entirely and
enforce filesystem permissions.

### macOS Permissions

Both Accessibility and Screen Recording are **powerful** permissions. Only
grant them to the `MacosUseServer.app` bundle you built yourself. Do not grant
them to arbitrary Terminal applications — the `.app` bundle approach isolates
the permission to a single, auditable binary.

### Socket Permissions

The server enforces `0600` (owner read/write only) on the Unix socket. Only
the user running the server can connect.

## Monitoring

### Health Checks

Use the MCP tools to verify the server is responsive:

```
macos-use_list_displays
```

Or check the launchd status:

```sh
launchctl print gui/$(id -u) | grep com.macosusesdk.server
```

### Logging

When running via launchd, logs go to:

```
~/Library/Logs/macosuse.log        (stdout)
~/Library/Logs/macosuse.error.log  (stderr)
```

When running manually, the server logs to stderr. Redirect as needed:

```sh
Server/.build/release/MacosUseServer 2>&1 | tee ~/macosuse.log
```

## Troubleshooting

### Server Crashes on Startup (Resource Bundle Error)

**Symptom:** `Fatal error: could not load resource bundle: from .../MacosUseServer_MacosUseServer.bundle`

**Cause:** SPM's generated `resource_bundle_accessor.swift` calls `fatalError`
when the resource bundle (containing protobuf descriptor sets for gRPC
reflection) cannot be found. This only affects gRPC reflection — the
server's core functionality (AX, screenshots, input) does not require it.

**Fix:** Ensure the build directory still exists at the hardcoded fallback
path inside `resource_bundle_accessor.swift`. For local deployment where the
source tree is present, this works automatically.

**Note:** Do NOT place the `.bundle` at the `.app` root — it breaks codesign
("unsealed contents"). A future code change should replace `Bundle.module`
with `Bundle.main.paths(forResourcesOfType:inDirectory:)` to make
reflection work from `.app` bundles without the build directory.

### `tccutil reset` Says "No Matching Bundle Identifier"

**Cause:** The bundle identifier hasn't been registered with LaunchServices.

**Fix:** Re-run `lsregister -f ~/Applications/MacosUseServer.app`, then retry.

### AX Permission Prompt Doesn't Appear

**Cause:** TCC doesn't know about the `.app` bundle.

**Fix:** Ensure `lsregister -f` has been run (Step 3) and the server is
actually running from inside the `.app` bundle (not a bare binary). Check
System Settings → Privacy & Security → Accessibility for
`com.macosusesdk.server` and add it manually if needed.

### Screen Recording Permission Denied

**Symptom:** `CaptureScreenshot` returns an error, or `SCShareableContent` hangs.

**Fix:** Grant Screen Recording permission in System Settings → Privacy &
Security → Screen Recording. Add `MacosUseServer.app` and toggle it ON.
Restart the server after toggling (launchd needs a fresh process for TCC
to pick up the change).

**Note:** Every time the `.app` binary is replaced (e.g. after a rebuild),
the code signature changes and TCC invalidates the permission. You must
re-grant Screen Recording (and Accessibility) after each binary update.

### Screenshot Returns "invalid width 0 and height 0"

**Symptom:** `CaptureScreenshot` fails with OSLog error:
`-[SCStream serializeStreamProperties]: invalid width 0 and height 0`

**Cause:** ScreenCaptureKit's `SCStreamConfiguration` does not accept
`width=0`/`height=0` (the "use source dimension" sentinel). This was a
bug in `ScreenshotCapture.swift` where `config.width = 0` and
`config.height = 0` were set. The fix computes pixel dimensions from the
target display/window and the `NSScreen.backingScaleFactor`, then sets
explicit `config.width` and `config.height` values in pixels.

### Client Connection Refused

1. Verify the server process is running:
   ```sh
   pgrep -fl MacosUseServer
   ```

2. Verify the socket exists:
   ```sh
   ls -la "$HOME/Library/Caches/macosuse.sock"
   # Expected: srw------- (0600 — owner read/write only, no execute)
   ```

3. Check launchd status:
   ```sh
   launchctl print gui/$(id -u) | grep com.macosusesdk.server
   ```

4. Check the error log:
   ```sh
   cat ~/Library/Logs/macosuse.error.log
   ```

### Quarantine Attribute Blocking Execution

```sh
xattr -d com.apple.quarantine ~/Applications/MacosUseServer.app
```
