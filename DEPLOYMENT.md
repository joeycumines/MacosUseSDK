# Deployment Guide

This guide covers deploying the **MacosUseServer** (gRPC Swift server) locally
with macOS TCC permissions (Accessibility + Screen Recording) and connecting an
MCP client (opencode) to it.

## Quick Start (2 commands)

```sh
gmake macos-use.install          # Build + bundle + sign + launchd + socket check
# Then grant TCC permissions in System Settings (see Step 2 below)
gmake macos-use.restart          # Restart so the server picks up the new TCC grants
```

All deployment targets live in [`make/macos-use.mk`](make/macos-use.mk).
Run `gmake help` and look for the `[MacosUse]` section to see every target.

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

## About Code Signing

The `.app` bundle is signed with an **ad-hoc identity** (`codesign --force --deep
--sign -`). This is sufficient for local deployment — macOS TCC tracks the app
by its bundle identifier (`com.macosusesdk.server`) and grants permissions when
the user adds it in System Settings.

The `macos-use.sign` target clears extended attributes (`xattr -cr`) before
signing to ensure a clean signature, then verifies with
`codesign --verify --deep --strict`.

### Apple Documentation References

| Topic | Link |
|-------|------|
| Hardened Runtime | <https://developer.apple.com/documentation/security/hardened_runtime> |
| Notarizing macOS software | <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution> |
| Entitlements | <https://developer.apple.com/documentation/bundleresources/entitlements> |
| codesign(1) man page | <https://www.unix.com/man-page/osx/1/codesign/> |
| SCScreenshotManager | <https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager> |
| SCContentFilter.contentRect | <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect> |
| SCContentFilter.pointPixelScale | <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale> |
| Capturing screen content in macOS | <https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos> |

## Step-by-Step Local Deployment

### Step 1: Build + Bundle + Sign + Install (one command)

```sh
gmake macos-use.install
```

This single target performs all of the following:

1. **Builds** the Swift server (release) and the Go MCP proxy
2. **Deletes** any existing `.app` bundle in full (`rm -rf`)
3. **Creates** the `.app` bundle structure with `Info.plist`
4. **Clears** extended attributes (`xattr -cr`) — required for a clean signature
5. **Signs** with ad-hoc identity (`codesign --force --deep --sign -`)
6. **Registers** with LaunchServices (`lsregister -f`)
7. **Creates** and **loads** the launchd service
8. **Checks** that the socket appears (the `launchd` target polls for it)

Binary locations after install:
- Server: `~/Applications/MacosUseServer.app/Contents/MacOS/MacosUseServer`
- MCP: `~/go/bin/macos-use-mcp` (via `go install`)

### Step 2: Grant macOS Permissions (TCC)

The server needs two TCC permissions. After `gmake macos-use.install` (which
starts the server), macOS will prompt for each on first use. You can also grant
them manually:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click **+**, navigate to `~/Applications/MacosUseServer.app`, add it
3. Toggle the switch **ON**
4. Repeat for **Screen Recording** (System Settings → Privacy & Security →
   Screen Recording)

| Permission       | Triggered By              | Purpose                                    |
|------------------|---------------------------|-------------------------------------------|
| Accessibility    | `TraverseAccessibility`  | Reading and controlling UI elements via AX |
| Screen Recording | `CaptureScreenshot`       | Capturing screen/window/region screenshots |

**After granting, restart the server** so the running process picks up the
new TCC grants:

```sh
gmake macos-use.restart
```

> **Note:** Each `gmake macos-use.install` re-codesigns the binary (new cdhash),
> which may invalidate TCC grants. Re-grant in System Settings, then
> `gmake macos-use.restart` (which does NOT re-sign).

**To reset a previously-denied or stale permission:**

```sh
gmake macos-use.tcc-reset
```

### Step 3: Verify the Deployment

```sh
gmake macos-use.verify
```

This checks: bundle structure, codesign verification, embedded entitlements,
Info.plist validity, socket existence, running process, and launchd status.

You can also use the MCP tools to verify end-to-end:

1. **No-permission test** (uses Quartz/CGWindowList, no TCC needed):
   ```
   macos-use_list_apps
   macos-use_list_windows
   macos-use_get_display
   ```

2. **Accessibility test** (triggers AX permission prompt on first use):
   ```
   macos-use_open_app  (id: "Calculator")
   macos-use_find_elements  (parent: "applications/{pid}")
   ```

3. **Screen Recording test** (triggers Screen Recording prompt on first use):
   ```
   macos-use_screenshot
   ```

### Step 4: Configure the MCP Client (opencode)

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

## Updating After a Rebuild

Simply run:

```sh
gmake macos-use.install
```

This rebuilds, re-bundles, re-signs (ad-hoc), and restarts the service.

## All Make Targets

| Target | Description |
|--------|-------------|
| `macos-use.build-server` | Build the MacosUseServer release binary |
| `macos-use.build-mcp` | Build and install the macos-use-mcp Go binary |
| `macos-use.build` | Build both server and MCP |
| `macos-use.bundle` | Create the .app bundle (clean, from scratch) |
| `macos-use.sign` | Ad-hoc codesign (`--force --deep --sign -`) + xattr clear + verify |
| `macos-use.register` | Register the .app with LaunchServices |
| `macos-use.launchd` | Create and load the launchd service |
| `macos-use.install` | Full install: build + bundle + sign + register + launchd |
| `macos-use.verify` | Verify the deployment (signature, plist, socket, process) |
| `macos-use.status` | Show launchd status, socket, process, and signature |
| `macos-use.start` | Alias for `macos-use.restart` — start the service |
| `macos-use.stop` | Stop the launchd service (no rebuild/codesign/uninstall) |
| `macos-use.restart` | Restart the launchd service (no rebuild/codesign) |
| `macos-use.tcc-reset` | Reset TCC permissions (Accessibility + Screen Recording) |
| `macos-use.uninstall` | Completely uninstall: remove .app, plist, socket, logs, TCC |
| `macos-use.logs` | Show recent MacosUseServer log entries |

## Swift Server Configuration

The Swift server (`MacosUseServer`) is configured via environment variables
(set in the launchd plist):

| Variable              | Default     | Description                                 |
|-----------------------|-------------|---------------------------------------------|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | IP address to bind to (loopback by default) |
| `GRPC_PORT`           | `8080`      | TCP port number                             |
| `GRPC_UNIX_SOCKET`    | (none)      | Unix socket path (overrides TCP if set)      |

When `GRPC_UNIX_SOCKET` is set, the server ignores `GRPC_LISTEN_ADDRESS` and
`GRPC_PORT` and listens only on the Unix socket.

## Stopping the Service

To stop the server without uninstalling (preserves the `.app`, plist, and TCC
permissions):

```sh
gmake macos-use.stop
```

To start it again:

```sh
gmake macos-use.restart
```

## Screenshot Capture Architecture

The server uses Apple's **ScreenCaptureKit** framework for all screenshot
operations (screen, window, region, and element captures).

### Single-Frame Capture via SCScreenshotManager

`ScreenshotCapture.swift` uses `SCScreenshotManager.captureImage` (macOS 14+)
for single-frame captures. This replaces the older `SCStream` + delegate +
`CheckedContinuation` pattern, eliminating the `startCapture` completion-handler
race entirely.

Pixel dimensions are derived from the `SCContentFilter` itself — the single
source of truth that respects scaled display modes:

| Property | Type | Description |
|----------|------|-------------|
| `filter.contentRect` | `CGRect` | Source rect in screen **points** |
| `filter.pointPixelScale` | `Float` | Pixel-per-point ratio (2.0 Retina, 1.0 non-Retina) |

```swift
let scale = CGFloat(filter.pointPixelScale)
config.width  = Int(filter.contentRect.width  * scale)
config.height = Int(filter.contentRect.height * scale)
return try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: config,
)
```

> **Why not `CGDisplayPixelsWide`?** That returns the hardware mode's pixel
> dimensions, which do NOT match when the user selects a scaled display mode
> ("Larger Text" / "More Space" in System Settings). `pointPixelScale` is the
> value ScreenCaptureKit itself uses for compositing.

### Apple Documentation

- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [SCContentFilter.contentRect](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect)
- [SCContentFilter.pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale)
- [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos)

## Uninstallation

```sh
gmake macos-use.uninstall
```

This stops the service, removes the `.app` bundle, launchd plist, socket, logs,
and resets TCC permissions.

## Security Considerations

### Network Access

The server defaults to **loopback only** (`127.0.0.1`). For local MCP use,
Unix sockets are recommended — they bypass the network stack entirely and
enforce filesystem permissions.

### macOS Permissions

Both Accessibility and Screen Recording are **powerful** permissions. Only
grant them to the `MacosUseServer.app` bundle you built yourself. The `.app`
bundle approach isolates the permission to a single, auditable binary.

### Socket Permissions

The server enforces `0600` (owner read/write only) on the Unix socket. Only
the user running the server can connect.

## Monitoring

### Health Checks

```sh
gmake macos-use.status
```

Or use MCP tools:

```
macos-use_get_display
```

### Logging

When running via launchd, logs go to:

```
~/Library/Logs/macosuse.log        (stdout)
~/Library/Logs/macosuse.error.log  (stderr)
```

View recent logs:

```sh
gmake macos-use.logs
```

## Troubleshooting

### TCC Permissions Revert After Rebuild

**Cause:** The app was re-signed with a new ad-hoc identity, which changes
the cdhash. TCC may invalidate the previous grant.

**Fix:** After `gmake macos-use.install`, re-grant Accessibility and Screen
Recording in System Settings, then `gmake macos-use.restart`.

### Server Crashes on Startup (Resource Bundle Error)

**Symptom:** `Fatal error: could not load resource bundle: from .../MacosUseServer_MacosUseServer.bundle`

**Cause:** SPM's generated `resource_bundle_accessor.swift` calls `fatalError`
when the resource bundle (containing protobuf descriptor sets for gRPC
reflection) cannot be found. This only affects gRPC reflection — the
server's core functionality (AX, screenshots, input) does not require it.

**Fix:** Ensure the build directory still exists at the hardcoded fallback
path inside `resource_bundle_accessor.swift`. For local deployment where the
source tree is present, this works automatically.

### `tccutil reset` Says "No Matching Bundle Identifier"

**Cause:** The bundle identifier hasn't been registered with LaunchServices.

**Fix:** Re-run `gmake macos-use.register`, then retry.

### AX Permission Prompt Doesn't Appear

**Cause:** TCC doesn't know about the `.app` bundle.

**Fix:** Ensure `lsregister -f` has been run (via `gmake macos-use.register`
or `gmake macos-use.install`) and the server is actually running from inside
the `.app` bundle (not a bare binary). Check System Settings → Privacy &
Security → Accessibility for `com.macosusesdk.server` and add it manually if
needed.

### Screen Recording Permission Denied

**Symptom:** `CaptureScreenshot` returns an error, or `SCShareableContent` hangs.

**Fix:** Grant Screen Recording permission in System Settings → Privacy &
Security → Screen Recording. Add `MacosUseServer.app` and toggle it ON.
Restart the server after toggling (`gmake macos-use.restart`).

> **Note:** Every time the `.app` binary is re-signed (e.g. after
> `gmake macos-use.install`), the ad-hoc cdhash changes and TCC may
> invalidate the grant. Re-grant in System Settings, then
> `gmake macos-use.restart` (which does NOT re-sign).

### Screenshot Returns "invalid width 0 and height 0" or "Unknown error"

**Symptom:** `CaptureScreenshot` fails with OSLog error:
`-[SCStream serializeStreamProperties]: invalid width 0 and height 0`
or a gRPC "Unknown error".

**Cause:** macOS 15 (Sequoia) added a hard validation in
`-[SCStream serializeStreamProperties]` that rejects `width == 0 || height == 0`.
The old code set `config.width = 0` and `config.height = 0` as a "use source
dimension" sentinel — this sentinel is no longer accepted.

**Fix (already applied):** `ScreenshotCapture.swift` now uses
`SCScreenshotManager.captureImage(contentFilter:configuration:)` (the
single-frame API, macOS 14+) instead of the `SCStream` + delegate + continuation
pattern. Pixel dimensions are derived from the filter itself:

```swift
let scale = CGFloat(filter.pointPixelScale)
config.width  = Int(filter.contentRect.width  * scale)
config.height = Int(filter.contentRect.height * scale)
```

`filter.contentRect` gives the source rect in screen **points**;
`filter.pointPixelScale` gives the pixel-per-point ratio (2.0 on Retina,
1.0 on non-Retina). This respects user-selected scaled display modes —
unlike `CGDisplayPixelsWide`, which returns the raw hardware mode dimensions.

**Apple documentation:**
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [SCContentFilter.contentRect](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect)
- [SCContentFilter.pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos)

### Client Connection Refused

1. Verify the server process is running:
   ```sh
   pgrep -fl MacosUseServer
   ```

2. Verify the socket exists:
   ```sh
   ls -la "$HOME/Library/Caches/macosuse.sock"
   # Expected: srw------- (0600 — owner read/write only)
   ```

3. Check launchd status:
   ```sh
   gmake macos-use.status
   ```

4. Check the error log:
   ```sh
   gmake macos-use.logs
   ```

### Quarantine Attribute Blocking Execution

```sh
xattr -d com.apple.quarantine ~/Applications/MacosUseServer.app
```
