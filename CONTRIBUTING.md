# Contributing to ExactMac

Thank you for your interest in contributing to ExactMac!

## Developer Setup

### System Requirements

| Requirement | Minimum Version | Notes |
|-------------|-----------------|-------|
| **macOS** | 15.0 (Sequoia) | Swift server requires macOS 15+ (gRPC Swift 2, Swift 6 concurrency) |
| **Xcode** | 16.0 | Includes Swift 6.1 toolchain |
| **Go** | 1.25+ | For MCP server and integration tests |
| **GNU Make** | 4.0+ | Build orchestration (Homebrew `make` provides `gmake`) |

### Installing Homebrew Dependencies

Install all required development tools via Homebrew:

```sh
# Core build tools
brew install go buf make

# Linting and formatting
brew install swiftformat swiftlint staticcheck golangci-lint

# Optional: Google API linter (for proto validation)
go install github.com/googleapis/api-linter/cmd/api-linter@latest
```

> **Note**: macOS includes BSD `make`. Use `gmake` (GNU Make from Homebrew) for compatibility with the build system.

### Accessibility Permissions

**CRITICAL**: Integration tests and the SDK require macOS Accessibility permissions.

1. Open **System Settings > Privacy & Security > Accessibility**
2. Add your terminal application (e.g., Terminal.app, iTerm2, VS Code)
3. Toggle the permission ON
4. **Restart your terminal** after granting permissions

To verify permissions are granted:

```sh
# This should succeed without prompting (returns the frontmost app name)
osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'
```

### Clone and First Build

```sh
# Clone the repository
git clone https://github.com/joeycumines/ExactMac.git
cd ExactMac

# Generate protobuf code (required before first build)
gmake buf.generate

# Full build (Swift + Go + Proto)
gmake all

# Verify build succeeded
echo $?  # Should print 0
```

### Environment Variables (Optional)

For local development with custom server configuration:

```sh
# Swift gRPC server
export GRPC_LISTEN_ADDRESS="127.0.0.1"
export GRPC_PORT="50051"

# Go MCP server
export MCP_HTTP_ADDRESS="127.0.0.1:8080"
export EXACTMAC_SERVER_ADDR="127.0.0.1:50051"
```

See the [Deployment Guide](DEPLOYMENT.md) for the full environment variable reference.

## Building

```sh
# Full build (Swift + Go + Proto generation)
gmake all

# Run all tests (Go + Swift suites)
gmake go.test swift.test

# Specific component builds
gmake swift.build    # Swift SDK and Server
gmake go.build       # Go MCP server
gmake buf.generate   # Regenerate protobuf code
```

## Testing

### Unit Tests

```sh
# All unit tests (Go + Swift suites)
gmake go.test swift.test

# Go unit tests
gmake go.test

# Swift unit tests
gmake swift.test

# Run specific Swift test
swift test --filter TestClassName/testMethodName
```

### Integration Tests

Integration tests require macOS accessibility permissions and target Calculator, TextEdit, and Finder:

```sh
# Run all integration tests (requires permissions)
gmake go.test.integration

# Run specific integration test suite
cd integration && go test -v -run TestCalculator ./...
```

**Important**: Integration and asynchronous state-convergence tests use `PollUntilContext` rather than arbitrary sleeps. Tests must assert state differences, not just "OK" status. Some lower-level transport tests may use timing primitives to test timeout behavior.

## Claude Plugin Development

The agent skill in `skills/exactmac/` ships as the `exactmac` Claude Code plugin; this repo is the marketplace (`.claude-plugin/`). To test skill changes, add the marketplace from the local checkout — relative-path plugins in a local-directory marketplace load in place, so edits apply without reinstalling:

```
/plugin marketplace add /path/to/ExactMac
/plugin install exactmac@exactmac
```

Validate manifests with `claude plugin validate .` from the repo root. The plugin manifest and skill metadata carry the coupled product version; use `gmake release.update RELEASE_VERSION=X.Y.Z` for release updates instead of editing one manifest or following a Git SHA independently.

## Releases

See [RELEASE_PROCESS.md](RELEASE_PROCESS.md) for the one-version, one-root-tag release process and the required `hack/` helper scripts. The update script edits files; the tag script creates only a local annotated tag. Neither pushes a tag or creates a GitHub release.

## Test Guidelines

### Golden Application Constraint

Integration tests MUST target only these applications:

| Application | Use Case |
|-------------|----------|
| **Calculator** | Input simulation, element interaction |
| **TextEdit** | Text input, clipboard, document handling |
| **Finder** | File dialogs, window management |

Do not introduce new target applications without discussion.

### No `time.Sleep` Rule

**BANNED for integration and state-convergence tests**: arbitrary `time.Sleep`.
Use `PollUntilContext` for async verification. Lower-level transport tests may
use controlled timing primitives when the test specifically verifies timeout
or deadline behavior:

```go
// ❌ WRONG: Arbitrary sleep
time.Sleep(2 * time.Second)

// ✅ CORRECT: Poll until condition or timeout
err := PollUntilContext(ctx, 100*time.Millisecond, func() bool {
    resp, _ := client.GetWindow(ctx, &pb.GetWindowRequest{Name: windowName})
    return resp != nil && resp.GetWindow().GetTitle() == expectedTitle
})
```

The `PollUntilContext` helper polls at the given interval until the predicate returns `true` or the context expires.

### State-Delta Assertions

Tests MUST verify state changes, not just "OK" status:

```go
// ❌ WRONG: Only checking status
resp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{...})
require.NoError(t, err) // Only verifies the call succeeded

// ✅ CORRECT: Verify the delta in state
initialWindow := getWindow(t, client, windowName)
initialX, initialY := initialWindow.GetBounds().GetX(), initialWindow.GetBounds().GetY()

_, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
    Name: windowName,
    X: 200, Y: 300,
})
require.NoError(t, err)

// Assert the state actually changed
finalWindow := getWindow(t, client, windowName)
assert.NotEqual(t, initialX, finalWindow.GetBounds().GetX())
assert.Equal(t, float64(200), finalWindow.GetBounds().GetX())
```

### Fixture Lifecycle

Every test suite must ensure a clean state:

**Before Tests (Setup)**:
```go
// In integration/main_test.go, the package-scoped helper gracefully quits
// TextEdit, polls for exit, then force-kills Calculator/TextEdit survivors.
// Finder is intentionally not killed. Reuse that helper from tests in the
// integration package rather than copying this call into another package.
killGoldenApplications()
```

**After Tests (Cleanup)**:
```go
func TestSomething(t *testing.T) {
    // ... test setup ...
    
    t.Cleanup(func() {
        // CloseApplication closes the exact owned process and cleans up state.
        _, _ = client.CloseApplication(ctx, &pb.CloseApplicationRequest{
            // Use the exact opaque Application.name returned by the server.
            Name: application.Name,
            Force: true,
        })
    })
    
    // ... test body ...
}
```

## Code Style

### Go

- Run `go vet` and `staticcheck` before committing
- All exported types and functions require godoc comments
- Error messages follow the format: `"failed to [action]: [details]"`

### Swift

- Use `Logger` with privacy annotations; `fputs`/`print` are forbidden for diagnostics
- Actor-based concurrency for shared state
- Consistent `RPCError(code:message:)` pattern for errors

### Proto

- Follow [Google AIPs](https://google.aip.dev/) (2025 standards)
- Use `google.api.field_behavior` annotations
- Document coordinate systems explicitly (Global Display Coordinates)
- Page tokens are opaque per AIP-158

## Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes with tests
4. Run `gmake all` to verify
5. Submit a PR with a descriptive title

Key components:
- **Swift gRPC Server** (`Server/`): macOS Accessibility API integration
- **Go MCP Server** (`internal/`): MCP proxy exposing agentic tools
- **Proto Definitions** (`proto/`): API contracts following Google AIPs

## License

By contributing, you agree that your contributions will be licensed under the project's license.
