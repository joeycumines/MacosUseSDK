# Deploying MacosUseSDK Locally on macOS

MacosUseSDK is not a conventional command-line service. Its Swift server needs
to use Accessibility, Core Graphics input, AppKit, and ScreenCaptureKit from the
logged-in desktop session. That changes the deployment design in three important
ways:

1. the server must have a stable, app-like identity for macOS privacy controls;
2. the SwiftPM resource bundle must travel with the executable; and
3. the process must run as a per-user LaunchAgent in the GUI domain.

This guide implements that design for a **single-user, same-Mac development
installation**. It builds the Swift gRPC server and Go MCP proxy, installs the
server as `~/Applications/MacosUseServer.app`, signs and registers the app, and
runs it behind an owner-only Unix socket.

> This is a local-development deployment, not a distribution pipeline. Shipping
> the app to other Macs requires a Developer ID workflow, Hardened Runtime,
> notarization, stapling, and an update strategy that are intentionally outside
> this guide.

All commands below are run from the repository root. All deployment targets are
implemented in [`make/macos-use.mk`](make/macos-use.mk). Run `gmake help` and
look for the `[MacosUse]` sections to list them.

## The resulting architecture

```text
┌──────────────┐      MCP over stdio      ┌──────────────────┐
│   OpenCode   │ ◄──────────────────────► │  macos-use-mcp   │
│  MCP client  │                          │    Go process    │
└──────────────┘                          └────────┬─────────┘
                                                 │ gRPC
                                                 │ Unix socket (0600)
                                                 ▼
                                      ┌────────────────────────┐
                                      │ MacosUseServer.app     │
                                      │ Swift LaunchAgent      │
                                      │ GUI user session       │
                                      └───────────┬────────────┘
                                                  │
                           Accessibility / CGEvent / ScreenCaptureKit
```

The two executables have deliberately different responsibilities:

- **`MacosUseServer`** is the native Swift service. It receives the macOS TCC
  grants and runs from an application bundle under the user's GUI launchd
  domain.
- **`macos-use-mcp`** is the Go MCP adapter. It speaks MCP to OpenCode and gRPC
  to the Swift server. It does not need Accessibility or screen-capture access.

For the local installation, the two processes communicate through
`~/Library/Caches/macosuse.sock`; no TCP listener is required.

## Prerequisites

The checked-in source currently establishes the authoritative versions:

- **macOS 15 or later** — `Server/Package.swift` declares `.macOS(.v15)`.
- **Swift 6 or later** — `Server/Package.swift` declares
  `// swift-tools-version: 6.0`.
- **Go matching `go.mod`** — the current module directive is `go 1.26.3`.
- **Buf CLI** — `macos-use.build-server` regenerates the descriptor set through
  the repository's `buf.descriptor-sets` target.
- **GNU Make 4 or later** — use Homebrew's `gmake`, not Apple's BSD `make`.
- **Xcode Command Line Tools** — supplies `swift`, `codesign`, `plutil`, and the
  other macOS development utilities.

A typical Homebrew setup is:

```sh
xcode-select --install
brew install go make bufbuild/buf/buf
```

`grpcurl` is useful for manual gRPC diagnostics but is not required by the
installation target:

```sh
brew install grpcurl
```

Check the machine and source tree before deploying:

```sh
gmake macos-use.doctor
```

## Quick start

The default installation uses an ad-hoc signature, which is convenient for a
one-off local build:

```sh
gmake macos-use.install
```

Then grant the app both privacy permissions in **System Settings → Privacy &
Security**:

1. **Accessibility** — add `~/Applications/MacosUseServer.app` and enable it.
2. **Screen & System Audio Recording** — add the same app and enable it. On some
   macOS releases this panel is labelled **Screen Recording**.

Restart the already-signed service so the new grants apply:

```sh
gmake macos-use.restart
gmake macos-use.verify
```

`macos-use.restart` does not build, replace, or re-sign the application.

## Prefer a stable signing identity

TCC tracks protected privileges using an app's code-signing identity. An ad-hoc
signature is adequate to execute a local app, but it is not a stable identity:
rebuilding and signing new bytes can cause Accessibility or screen-capture
approval to disappear.

List available code-signing identities:

```sh
security find-identity -v -p codesigning
```

For day-to-day development, install with a persistent Apple Development
identity:

```sh
gmake macos-use.install \
  MACOS_USE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
```

Keep the bundle identifier and signing identity consistent across builds. That
is the practical way to preserve TCC grants while iterating.

The Makefile intentionally does **not** use `codesign --deep` while signing.
Apple's signing model is to sign nested code from the inside out and then sign
the outer app. This bundle currently contains one main executable and
resource-only SwiftPM bundles, so signing the outer app is sufficient. The
verification phase does use `--deep --strict` to detect invalid nested content.
If executable helpers, frameworks, or plug-ins are added later, sign those
components explicitly before signing the app.

## What `macos-use.install` does

The installation target runs these phases in a fixed order rather than relying
on a parallel phony-prerequisite graph:

1. **Doctor** — validates macOS, GNU Make, required commands, and source files.
2. **Build server** — generates the protobuf descriptor set and performs a
   release Swift build.
3. **Build MCP proxy** — installs `macos-use-mcp` into the resolved Go binary
   directory.
4. **Stop service** — unloads any existing LaunchAgent before replacing signed
   code on disk.
5. **Bundle** — creates a staged `.app`, copies the executable and all SwiftPM
   resource bundles, validates `Info.plist`, then moves the staged app into
   place.
6. **Sign** — clears extended attributes on the app bundle being signed, signs it,
   and performs strict verification.
7. **Register** — registers the signed app with LaunchServices.
8. **Launch** — writes and bootstraps the per-user LaunchAgent in
   `gui/$(id -u)`.
9. **Verify** — fails unless the bundle, descriptor resources, signature,
   LaunchAgent, running state, socket mode, and MCP binary are all valid.

The low-level targets are intentionally independent. For example,
`gmake macos-use.register` registers the app that is already installed; it does
not unexpectedly rebuild or re-sign it.

## Why the SwiftPM resource bundle matters

`Server/Package.swift` declares:

```swift
resources: [
    .copy("DescriptorSets"),
]
```

SwiftPM therefore emits a resource bundle named
`MacosUseServer_MacosUseServer.bundle`. The generated `Bundle.module` accessor
first looks for that bundle relative to `Bundle.main.bundleURL` and otherwise
falls back to the build-tree path embedded at compile time.

Copying only the executable is not a complete deployment. It leaves production
startup dependent on the source build directory and can trigger a fatal
resource-bundle lookup failure.

The corrected bundle phase stores the real resource bundle under the standard
macOS location:

```text
MacosUseServer.app/Contents/Resources/MacosUseServer_MacosUseServer.bundle
```

The verifier checks the installed bundle and at least one packaged `*.pb`
descriptor file.

## Why this is a LaunchAgent

A LaunchDaemon runs outside the logged-in user's GUI context and is the wrong
execution domain for a service that talks to the accessibility server,
WindowServer, AppKit, and ScreenCaptureKit.

The generated plist is installed at:

```text
~/Library/LaunchAgents/com.macosusesdk.server.plist
```

It runs in the exact service domain:

```text
gui/<uid>/com.macosusesdk.server
```

Lifecycle commands use modern launchctl operations:

- `bootstrap` to load the plist;
- `bootout` to unload it;
- `kickstart -k` to restart the loaded service; and
- `launchctl print gui/<uid>/<label>` to inspect that exact service.

`KeepAlive=true` keeps the server resident and already implies `RunAtLoad`, so a
separate `RunAtLoad` key is unnecessary. The plist also sets an octal `0177`
umask. The Swift server independently applies the same restrictive umask and
changes the socket to `0600` after binding.

## Installed paths

| Artifact | Default path |
|---|---|
| Application bundle | `~/Applications/MacosUseServer.app` |
| Server executable | `~/Applications/MacosUseServer.app/Contents/MacOS/MacosUseServer` |
| SwiftPM resources | `~/Applications/MacosUseServer.app/Contents/Resources/*.bundle` |
| LaunchAgent plist | `~/Library/LaunchAgents/com.macosusesdk.server.plist` |
| gRPC Unix socket | `~/Library/Caches/macosuse.sock` |
| Standard output log | `~/Library/Logs/macosuse.log` |
| Standard error log | `~/Library/Logs/macosuse.error.log` |
| MCP binary | `$GOBIN/macos-use-mcp`, otherwise the first `$GOPATH/bin` |
| Build logs | `.build-logs/macos-use-server.log` and `.build-logs/macos-use-mcp.log` |

Go's usual default is `~/go/bin`, but the Makefile resolves `GOBIN` and
`GOPATH` instead of assuming that location.

## Granting and resetting TCC permissions

The server needs these grants:

| Permission | Representative operation | Why it is needed |
|---|---|---|
| Accessibility | `find_elements`, element reads, clicks, typing, window mutations | Read and control other apps through AX APIs |
| Screen & System Audio Recording | `screenshot` | Capture displays and windows with ScreenCaptureKit |

OpenCode may display MCP tools with the configured server-name prefix, such as
`macos-use_screenshot`.

After changing either permission, restart the process:

```sh
gmake macos-use.restart
```

To remove denied or stale records during development:

```sh
gmake macos-use.tcc-reset
```

Then re-enable both permissions in System Settings and restart again. The reset
target reports missing records as warnings rather than pretending a record was
removed.

## Verifying the deployment

Run the strict structural and runtime verifier at any time:

```sh
gmake macos-use.verify
```

Unlike a status display, verification returns a non-zero exit status when a
required condition fails. It checks:

- the app and executable;
- `Info.plist` syntax and bundle identifier;
- the installed SwiftPM bundle and protobuf descriptor resources;
- strict recursive code-signing validity;
- the LaunchAgent plist;
- the exact launchd service and its running state;
- the Unix socket and its `0600` mode; and
- the installed MCP executable.

For an end-to-end permission check, exercise the MCP surface in this order:

1. Basic transport and enumeration: `get_display`, `list_apps`, `list_windows`.
2. Accessibility: `open_app`, then `find_elements` for the returned application.
3. Screen capture: `screenshot`.

The Makefile deliberately does not automate TCC interaction or treat a missing
privacy grant as an installation failure; those decisions require the logged-in
user.

## Configuring OpenCode

Keep this MCP server project-scoped by creating `opencode.jsonc` in the
repository root. OpenCode searches upward from the working directory to the
nearest Git root, and its project configuration overrides standard global
configuration.

First determine the actual MCP binary path:

```sh
GOBIN_PATH="$(go env GOBIN)"
if [ -z "$GOBIN_PATH" ]; then
  GOPATH_PATH="$(go env GOPATH)"
  GOBIN_PATH="${GOPATH_PATH%%:*}/bin"
fi
printf '%s\n' "$GOBIN_PATH/macos-use-mcp"
printf '%s\n' "$HOME/Library/Caches/macosuse.sock"
```

Use those absolute paths in the project configuration:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "macos-use": {
      "type": "local",
      "command": ["/Users/YOU/go/bin/macos-use-mcp"],
      "enabled": true,
      "environment": {
        "MACOS_USE_SERVER_SOCKET_PATH": "/Users/YOU/Library/Caches/macosuse.sock",
        "MCP_TRANSPORT": "stdio"
      },
      "timeout": 10000
    }
  }
}
```

OpenCode's `timeout` is expressed in milliseconds and controls how long it waits
to fetch tools from the MCP server. The proxy's own gRPC request timeout is a
separate setting, `MACOS_USE_REQUEST_TIMEOUT`, expressed in seconds.

Do not add the entry to the global OpenCode configuration unless the tools
should be available in every project.

## Runtime configuration

### Swift gRPC server

The LaunchAgent sets only `GRPC_UNIX_SOCKET`, so the local deployment never
opens a TCP port.

| Variable | Source default | Meaning |
|---|---:|---|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | TCP bind address when no socket is configured |
| `GRPC_PORT` | `8080` | TCP port when no socket is configured |
| `GRPC_UNIX_SOCKET` | empty | Unix socket path; takes precedence over TCP |

### Go MCP proxy

| Variable | Default | Meaning |
|---|---:|---|
| `MACOS_USE_SERVER_SOCKET_PATH` | empty | Swift server Unix socket; when set, the TCP address is ignored |
| `MACOS_USE_SERVER_ADDR` | `localhost:50051` | TCP fallback used only when no socket path is set |
| `MACOS_USE_REQUEST_TIMEOUT` | `30` | gRPC request timeout in seconds |
| `MACOS_USE_DEBUG` | `false` | Enable proxy debug logging |
| `MCP_TRANSPORT` | `stdio` | MCP transport: `stdio` or `streamable-http` |
| `MCP_HTTP_ADDRESS` | `127.0.0.1:8080` | Listener for Streamable HTTP transport |
| `MCP_HTTP_SOCKET` | empty | Unix socket for HTTP transport |
| `MCP_API_KEY` | empty | Bearer-token authentication for HTTP transport |
| `MCP_RATE_LIMIT` | `0` | Requests per second; zero disables limiting |
| `MCP_AUDIT_LOG_FILE` | empty | Optional owner-private non-content audit-log destination |
| `MCP_SHELL_COMMANDS_ENABLED` | `false` | Enables shell execution; leave disabled unless explicitly required |

The Swift TCP default and the MCP TCP fallback are different. The deployment
avoids that ambiguity by configuring both sides with the same Unix socket.

## Screenshot implementation

Screenshot operations use ScreenCaptureKit's single-frame API,
`SCScreenshotManager.captureImage(contentFilter:configuration:)`.

The stream configuration receives explicit non-zero pixel dimensions derived
from the content filter:

```swift
let scale = CGFloat(filter.pointPixelScale)
config.width = Int(filter.contentRect.width * scale)
config.height = Int(filter.contentRect.height * scale)
```

`contentRect` is measured in points and `pointPixelScale` is the conversion from
points to pixels for the filtered content. This is preferable to setting width
and height to zero, and it respects user-selected scaled display modes better
than deriving capture size from a raw display mode.

## Updating without losing permissions unnecessarily

To rebuild and reinstall everything:

```sh
gmake macos-use.install
```

This replaces and re-signs the application. With the default ad-hoc identity,
expect to re-grant TCC permissions. With a stable Apple Development identity,
TCC should normally recognize the new build as the same app, provided the
bundle identifier and designated requirement remain stable.

To restart the same installed code after a configuration or TCC change:

```sh
gmake macos-use.restart
```

That target does not touch the app's bytes or signature.

## Lifecycle and diagnostic targets

| Target | Purpose |
|---|---|
| `macos-use.doctor` | Validate the host tools and expected source layout |
| `macos-use.build-server` | Generate descriptors and build the release Swift server |
| `macos-use.build-mcp` | Build and install the Go MCP proxy |
| `macos-use.build` | Run both builds in a deterministic order |
| `macos-use.bundle` | Stage and install the app, including SwiftPM resources |
| `macos-use.sign` | Sign the existing app and verify it strictly |
| `macos-use.register` | Register the existing signed app with LaunchServices |
| `macos-use.launchd` | Write and bootstrap the per-user LaunchAgent |
| `macos-use.install` | Run the complete ordered local installation |
| `macos-use.verify` | Fail unless every required installed/runtime check passes |
| `macos-use.status` | Print launchd, socket, signature, and MCP status without asserting success |
| `macos-use.start` | Start a loaded or installed service without rebuilding |
| `macos-use.restart` | Force-restart the service without rebuilding or signing |
| `macos-use.stop` | Stop and unload the service while preserving installed files and TCC |
| `macos-use.tcc-reset` | Reset Accessibility and ScreenCapture TCC records |
| `macos-use.logs` | Show stdout, stderr, and recent unified-log entries |
| `macos-use.uninstall` | Remove installed app, service, socket, logs, MCP binary, and matching TCC records |

## Troubleshooting

### The server reports a missing resource bundle

Run:

```sh
ls -ld \
  ~/Applications/MacosUseServer.app/Contents/Resources/MacosUseServer_MacosUseServer.bundle
find ~/Applications/MacosUseServer.app -name '*.pb' -print
gmake macos-use.verify
```

A correct deployment contains the real bundle under `Contents/Resources`.
Re-run `gmake macos-use.install` if it is absent.

### A TCC grant disappears after rebuilding

The usual cause is ad-hoc signing. Install with a persistent Apple Development
identity, then grant the permission once more:

```sh
gmake macos-use.install \
  MACOS_USE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
```

### The privacy prompt does not appear

Confirm that the installed app is signed and registered, and that launchd is
running the executable from inside that app:

```sh
gmake macos-use.status
codesign -dvvv ~/Applications/MacosUseServer.app
gmake macos-use.register
```

`macos-use.register` does not rebuild or re-sign. If the app is still absent
from the relevant System Settings panel, add
`~/Applications/MacosUseServer.app` manually.

### Screen capture remains denied after enabling it

Apple's ScreenCaptureKit guidance requires restarting the app after approval.
Run:

```sh
gmake macos-use.restart
gmake macos-use.logs
```

### The socket is missing or the client cannot connect

```sh
gmake macos-use.status
gmake macos-use.logs
gmake macos-use.verify
```

Confirm that the path in `opencode.jsonc` exactly matches:

```text
~/Library/Caches/macosuse.sock
```

OpenCode configuration requires an absolute path; a literal `~` is not a safe
substitute.

### OpenCode cannot find `macos-use-mcp`

Do not assume `~/go/bin`. Resolve the active Go install directory and use that
absolute path in `opencode.jsonc`:

```sh
go env GOBIN
go env GOPATH
```

The Makefile prints the final MCP path during installation and in
`gmake macos-use.status`.

### `launchctl bootstrap` reports that the service is already loaded

Use the exact lifecycle targets rather than loading the plist manually:

```sh
gmake macos-use.stop
gmake macos-use.launchd
```

They address the service as `gui/<uid>/com.macosusesdk.server` and remove a stale
socket before bootstrapping.

### Screenshot capture reports zero width or height

The current implementation computes explicit dimensions from
`SCContentFilter.contentRect` and `pointPixelScale`. Rebuild the installed app to
ensure it contains that source:

```sh
gmake macos-use.install
```

### Quarantine or extended attributes interfere with signing

The sign target runs `xattr -cr` against the app bundle being signed. The full
install target signs a newly staged local app, while the standalone sign target
operates on the already-installed bundle. A locally built application normally should not need a separate
quarantine workaround. Diagnose unexpected attributes before applying broader
changes:

```sh
xattr -lr ~/Applications/MacosUseServer.app
```

## Security boundaries

Accessibility and screen recording are high-impact permissions. Grant them only
to an app you built from source and whose signature you inspected.

The default local design keeps the trust boundary narrow:

- the Swift server listens on a Unix socket instead of a network interface;
- both launchd and the server use a restrictive `0177` umask;
- the server enforces socket mode `0600`;
- the service runs as the logged-in user, not as root;
- the MCP proxy defaults to stdio; and
- shell-command execution is disabled by default.

Do not expose the MCP Streamable HTTP transport or the Swift gRPC TCP listener
beyond loopback without adding authentication, TLS, rate limiting, and an
explicit threat model.

## Uninstallation

```sh
gmake macos-use.uninstall
```

This removes installed runtime artifacts, including the app, LaunchAgent plist,
socket, logs, and resolved `macos-use-mcp` binary. It also attempts to remove
the matching LaunchServices registration and TCC records; macOS may report no
matching record, and those cleanup commands are intentionally non-fatal. It does
not delete source files or Swift/Go build caches in the repository.

## Primary references

- Apple, *Code Signing Tasks*:
  <https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html>
- Apple, *Technical Note TN2206: macOS Code Signing In Depth*:
  <https://developer.apple.com/library/archive/technotes/tn2206/_index.html>
- Apple, *Placing content in a bundle*:
  <https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle>
- Apple, *Embedding nonstandard code structures in a bundle*:
  <https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle>
- Apple, *Hardened Runtime*:
  <https://developer.apple.com/documentation/security/hardened_runtime>
- Apple, *Notarizing macOS software before distribution*:
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple, `launchctl(1)` and `launchd.plist(5)` man pages as shipped with Xcode:
  <https://keith.github.io/xcode-man-pages/launchctl.1.html>
  and <https://keith.github.io/xcode-man-pages/launchd.plist.5.html>
- Apple, *SCScreenshotManager*:
  <https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager>
- Apple, *SCContentFilter.contentRect*:
  <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect>
- Apple, *SCContentFilter.pointPixelScale*:
  <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale>
- Apple, *Capturing screen content in macOS*:
  <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos>
- Swift Package Manager, *Bundling resources with a Swift package*:
  <https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package>
- OpenCode, *MCP servers*:
  <https://opencode.ai/docs/mcp-servers/>
- OpenCode, *Config*:
  <https://opencode.ai/docs/config/>
- Go, *How to Write Go Code*:
  <https://go.dev/doc/code>
