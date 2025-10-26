## FIRST-PASS (DRAFT) Implementation Plan

**CRITICAL INFORMATION:** You are expected to **CONTINUALLY** refine this. The constraints in [implementation-constraints.md](./implementation-constraints.md) are AUTHORATIVE and MANDATORY, and MUST be read. The below is a DRAFT plan, to be refined and improved upon.

## **Implementation Plan: MacosUseSDK gRPC Service**

### **Objective**

This plan details the construction of a fully-realized, production-grade gRPC server, written in Swift, that exposes the complete functionality of the `MacosUseSDK` to cross-language clients.

The implementation will establish a resource-oriented API adhering to Google's AIPs. It will be built upon a robust, asynchronous control loop (a Swift Actor running on the main thread) to serially manage all SDK interactions. This architecture guarantees thread safety, supports multi-target automation, and provides a clear, maintainable separation between the API layer and the automation core.

-----

## **Phase 1: API Definition & `buf` Configuration**

This phase defines the complete API contract in Protobuf and configures the `buf` build system for code generation and validation.

### **1.1 Project Structure Setup**

  * **Action:** Create the `proto/v1` directory to house all `.proto` definitions.
  * **Action:** Create a `gen` directory for generated stubs.

### **1.2 `buf.yaml` Configuration**

  * **Action:** Create `buf.yaml` (v2) in the repository root.
  * **Specification:**
    ```yaml
    version: v2
    modules:
      - path: proto
    deps:
      - buf.build/googleapis/googleapis
    lint:
      use:
        - DEFAULT
      except:
        - PACKAGE_VERSION_SUFFIX
    breaking:
      use:
        - FILE
    ```

### **1.3 `buf.gen.yaml` Configuration**

  * **Action:** Create `buf.gen.yaml` in the repository root.
  * **Specification:** This configures generators for Swift (server) and Go (client).
    ```yaml
    version: v2
    plugins:
      # Swift Server Stubs (grpc-swift)
      - remote: buf.build/apple/swift:v1
        out: gen/swift
        opt:
          - Visibility=public
      - remote: buf.build/grpc/swift:v1
        out: gen/swift
        opt:
          - Visibility=public
          - Server=true
          - Client=false # We only need the server in this repo

      # Go Client Stubs
      - remote: buf.build/protocolbuffers/go:v1.31
        out: gen/go
        opt:
          - paths=source_relative
      - remote: buf.build/grpc/go:v1.3
        out: gen/go
        opt:
          - paths=source_relative
          - require_unimplemented_servers=false
    ```

### **1.4 `go.mod` for Go Stubs**

  * **Action:** Initialize a Go module in the repository root (or a sub-directory, but root is fine).
  * **Command:**
    ```bash
    go mod init github.com/joeycumines/MacosUseSDK
    go get google.golang.org/grpc
    go get google.golang.org/protobuf
    ```

### **1.5 API Service Definitions (`.proto`)**

  * **Action:** Create `proto/v1/desktop.proto` and `proto/v1/targets.proto`.
  * **File:** `proto/v1/desktop.proto`
      * **Purpose:** Handles global actions and the creation of application targets.
    <!-- end list -->
    ```protobuf
    syntax = "proto3";

    package macosusesdk.v1;

    import "google/api/annotations.proto";
    import "google/api/client.proto";
    import "google/api/field_behavior.proto";
    import "google/protobuf/empty.proto";
    import "macosusesdk/v1/targets.proto";

    // Service for interacting with the desktop environment as a whole.
    service DesktopService {
      option (google.api.default_host) = "macos.googleapis.com";

      // Opens or activates an application, creating a manageable target resource.
      rpc OpenApplication(OpenApplicationRequest) returns (TargetApplication) {
        option (google.api.http) = {
          post: "/v1/desktop:openApplication"
          body: "*"
        };
      }

      // Executes a "global" input command not tied to a specific application PID.
      rpc ExecuteGlobalInput(ExecuteGlobalInputRequest) returns (google.protobuf.Empty) {
        option (google.api.http) = {
          post: "/v1/desktop:executeGlobalInput"
          body: "*"
        };
      }
    }

    message OpenApplicationRequest {
      // The identifier (name, bundle ID, or path) of the application to open.
      // e.g., "Calculator", "com.apple.calculator"
      string identifier = 1 [(google.api.field_behavior) = REQUIRED];
    }

    message ExecuteGlobalInputRequest {
      // The input action to perform globally.
      InputAction input = 1 [(google.api.field_behavior) = REQUIRED];

      // If true, shows visual feedback for the input.
      bool show_animation = 2;

      // Duration for the visual feedback.
      double animation_duration = 3;
    }
    ```
  * **File:** `proto/v1/targets.proto`
      * **Purpose:** Defines the `TargetApplication` resource and methods to interact with it.
    <!-- end list -->
    ```protobuf
    syntax = "proto3";

    package macosusesdk.v1;

    import "google/api/annotations.proto";
    import "google/api/client.proto";
    import "google/api/field_behavior.proto";
    import "google/api/resource.proto";
    import "google/protobuf/empty.proto";

    // Service for managing and interacting with specific application targets.
    service TargetApplicationsService {
      option (google.api.default_host) = "macos.googleapis.com";

      // Gets a specific application target being tracked by the server.
      rpc GetTargetApplication(GetTargetApplicationRequest) returns (TargetApplication) {
        option (google.api.http) = {
          get: "/v1/{name=targetApplications/*}"
        };
        option (google.api.method_signature) = "name";
      }

      // Lists all application targets currently tracked by the server.
      rpc ListTargetApplications(ListTargetApplicationsRequest) returns (ListTargetApplicationsResponse) {
        option (google.api.http) = {
          get: "/v1/targetApplications"
        };
      }

      // Removes an application target from server tracking. This does NOT quit the app.
      rpc DeleteTargetApplication(DeleteTargetApplicationRequest) returns (google.protobuf.Empty) {
        option (google.api.http) = {
          delete: "/v1/{name=targetApplications/*}"
        };
        option (google.api.method_signature) = "name";
      }

      // Performs a complex, coordinated action on a specific application target.
      // This is the primary method for all automation.
      rpc PerformAction(PerformActionRequest) returns (ActionResult) {
        option (google.api.http) = {
          post: "/v1/{name=targetApplications/*}:performAction"
          body: "*"
        };
        option (google.api.method_signature) = "name,action,options";
      }

      // Streams accessibility tree changes for a specific application target.
      // This is an extension of the SDK's diffing capability.
      rpc Watch(WatchRequest) returns (stream WatchResponse) {
        option (google.api.http) = {
          get: "/v1/{name=targetApplications/*}:watch"
        };
        option (google.api.method_signature) = "name";
      }
    }

    // A resource representing a running application instance (PID)
    // that the server is actively tracking.
    message TargetApplication {
      option (google.api.resource) = {
        type: "macos.googleapis.com/TargetApplication"
        pattern: "targetApplications/{pid}"
      };

      // Resource name. e.g., "targetApplications/12345"
      string name = 1;

      // The process ID.
      int32 pid = 2 [(google.api.field_behavior) = OUTPUT_ONLY];

      // The localized name of the application.
      string app_name = 3 [(google.api.field_behavior) = OUTPUT_ONLY];
    }

    message GetTargetApplicationRequest {
      string name = 1 [
        (google.api.field_behavior) = REQUIRED,
        (google.api.resource_reference) = { type: "macos.googleapis.com/TargetApplication" }
      ];
    }

    message ListTargetApplicationsRequest {}

    message ListTargetApplicationsResponse {
      repeated TargetApplication target_applications = 1;
    }

    message DeleteTargetApplicationRequest {
      string name = 1 [
        (google.api.field_behavior) = REQUIRED,
        (google.api.resource_reference) = { type: "macos.googleapis.com/TargetApplication" }
      ];
    }

    // --- Action/Input Definitions (Mirrors SDK) ---

    message Point {
      double x = 1;
      double y = 2;
    }

    // Mirrors SDK `InputAction`
    message InputAction {
      oneof action_type {
        Point click = 1;
        Point double_click = 2;
        Point right_click = 3;
        string type_text = 4;
        KeyPress press_key = 5;
        Point move_to = 6;
      }
    }

    message KeyPress {
      // e.g., "return", "a", "cmd+c"
      string key_combo = 1;
    }

    // Mirrors SDK `PrimaryAction`
    message PrimaryAction {
      oneof action_type {
        // .open is handled by DesktopService.OpenApplication
        InputAction input = 1;
        bool traverse_only = 2;
      }
    }

    // Mirrors SDK `ActionOptions`
    message ActionOptions {
      bool traverse_before = 1;
      bool traverse_after = 2;
      bool show_diff = 3;
      bool only_visible_elements = 4;
      bool show_animation = 5;
      double animation_duration = 6;
      double delay_after_action = 7;
      // pidForTraversal is omitted; it's implicit from the resource name.
    }

    // Mirrors SDK `ActionResult`
    message ActionResult {
      // AppOpenerResult is inlined.
      int32 pid = 1;
      string app_name = 2;

      int32 traversal_pid = 3;
      ResponseData traversal_before = 4;
      ResponseData traversal_after = 5;
      TraversalDiff traversal_diff = 6;
      string primary_action_error = 7;
      string traversal_before_error = 8;
      string traversal_after_error = 9;
    }

    // Mirrors SDK `ResponseData`
    message ResponseData {
      string app_name = 1;
      repeated ElementData elements = 2;
      Statistics stats = 3;
      string processing_time_seconds = 4;
    }

    // Mirrors SDK `ElementData`
    message ElementData {
      string role = 1;
      optional string text = 2;
      optional double x = 3;
      optional double y = 4;
      optional double width = 5;
      optional double height = 6;
    }

    // Mirrors SDK `Statistics`
    message Statistics {
      int32 count = 1;
      int32 excluded_count = 2;
      int32 excluded_non_interactable = 3;
      int32 excluded_no_text = 4;
      int32 with_text_count = 5;
      int32 without_text_count = 6;
      int32 visible_elements_count = 7;
      map<string, int32> role_counts = 8;
    }

    // Mirrors SDK `TraversalDiff`
    message TraversalDiff {
      repeated ElementData added = 1;
      repeated ElementData removed = 2;
      repeated ModifiedElement modified = 3;
    }

    // Mirrors SDK `ModifiedElement`
    message ModifiedElement {
      ElementData before = 1;
      ElementData after = 2;
      repeated AttributeChangeDetail changes = 3;
    }

    // Mirrors SDK `AttributeChangeDetail`
    message AttributeChangeDetail {
      string attribute_name = 1;
      optional string added_text = 2;
      optional string removed_text = 3;
      optional string old_value = 4;
      optional string new_value = 5;
    }

    // --- RPC Request/Response Messages ---

    message PerformActionRequest {
      string name = 1 [
        (google.api.field_behavior) = REQUIRED,
        (google.api.resource_reference) = { type: "macos.googleapis.com/TargetApplication" }
      ];
      PrimaryAction action = 2 [(google.api.field_behavior) = REQUIRED];
      ActionOptions options = 3;
    }

    message WatchRequest {
      string name = 1 [
        (google.api.field_behavior) = REQUIRED,
        (google.api.resource_reference) = { type: "macos.googleapis.com/TargetApplication" }
      ];
      // e.g., poll interval
      double poll_interval_seconds = 2;
    }

    message WatchResponse {
      // Streams the diffs as they are detected.
      TraversalDiff diff = 1;
    }
    ```

-----

## **Phase 2: CI & Stub Generation Workflow**

This phase ensures all API changes are validated and that generated stubs are kept in sync.

### **2.1 `buf` Generation**

  * **Action:** Run `buf mod update` to populate `buf.lock`, then run `buf generate`.
  * **Result:** Populates `gen/swift` and `gen/go` with the generated stubs.

### **2.2 GitHub Actions CI Workflow**

  * **Action:** Create `.github/workflows/buf.yaml`.
  * **Specification:**
    ```yaml
    name: Buf
    on:
      push:
        branches:
          - main
      pull_request:
        branches:
          - main

    jobs:
      lint-and-breaking:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: bufbuild/buf-setup-action@v1
          - name: Lint
            run: buf lint
          - name: Breaking Change Detection
            run: |
              buf breaking --against "https(REMOVED_COLON)//github.com/$(git remote get-url origin | sed 's/https:\/\///' | sed 's/ssh:\/\///' | sed 's/git@//' | sed 's/.git//').git#branch=main"

      generate-stubs:
        runs-on: ubuntu-latest
        needs: lint-and-breaking
        if: github.ref == 'refs/heads/main' # Only run on main branch pushes
        steps:
          - uses: actions/checkout@v4
          - uses: bufbuild/buf-setup-action@v1
          - uses: actions/setup-go@v5
            with:
              go-version: '1.21'
          - name: Update Go dependencies
            run: go mod tidy
          - name: Generate Stubs
            run: buf generate
          - name: Commit and Push Stubs
            run: |
              git config --local user.email "action@github.com"
              git config --local user.name "GitHub Action"
              git add gen/
              git add go.mod go.sum buf.lock
              if ! git diff --staged --quiet; then
                git commit -m "ci: update generated gRPC stubs"
                git push
              else
                echo "No changes to generated stubs."
              fi
    ```

-----

## **Phase 3: Core Server Architecture (Swift)**

This phase implements the Swift server executable, the state management layer, and the central control loop.

### **3.1 Server Package Setup**

  * **Action:** Create a new Swift package for the server.
    ```bash
    mkdir Server
    cd Server
    swift package init --type executable
    ```
  * **Action:** Add `grpc-swift` and the local `MacosUseSDK` as dependencies in `Server/Package.swift`.
  * **Specification:**
    ```swift
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "MacosUseServer",
        platforms: [.macOS(.v12)],
        dependencies: [
            .package(url: "https/github.com/grpc/grpc-swift.git", from: "1.19.0"),
            .package(name: "MacosUseSDK", path: "../") // Local SDK
        ],
        targets: [
            .executableTarget(
                name: "MacosUseServer",
                dependencies: [
                    .product(name: "GRPC", package: "grpc-swift"),
                    "MacosUseSDK"
                ],
                path: "Sources"
            )
        ]
    )
    ```

### **3.2 Thread-Safe State Store**

  * **Action:** Create `Server/Sources/AppStateStore.swift`.
  * **Purpose:** A thread-safe `actor` to hold the "view" of known application targets, readable from any gRPC handler thread.
  * **Specification:**
    ```swift
    import Foundation
    import MacosUseSDK // For PID type

    // This struct is Sendable and acts as the COW view.
    struct ServerState: Sendable {
        var targets: [pid_t: Macosusesdk_V1_TargetApplication] = [:]
    }

    // This actor serializes all reads/writes to the state.
    actor AppStateStore {
        private var state = ServerState()

        func addTarget(_ target: Macosusesdk_V1_TargetApplication) {
            state.targets[target.pid] = target
        }

        func removeTarget(pid: pid_t) -> Macosusesdk_V1_TargetApplication? {
            return state.targets.removeValue(forKey: pid)
        }

        func getTarget(pid: pid_t) -> Macosusesdk_V1_TargetApplication? {
            return state.targets[pid]
        }

        func listTargets() -> [Macosusesdk_V1_TargetApplication] {
            return Array(state.targets.values)
        }

        func currentState() -> ServerState {
            return state
        }
    }
    ```

### **3.3 Central Control Loop (`AutomationCoordinator`)**

  * **Action:** Create `Server/Sources/AutomationCoordinator.swift`.
  * **Purpose:** A `@MainActor` global actor. This is the **only** entity that can call `MacosUseSDK` functions. It serializes all automation commands on the main thread, satisfying SDK requirements.
  * **Specification:**
    ```swift
    import Foundation
    import AppKit // For @MainActor
    import MacosUseSDK
    import CoreGraphics // For CGPoint, CGEventFlags

    @globalActor
    final class AutomationCoordinator {
        static let shared = AutomationCoordinator()

        @MainActor
        private init() {
            // This actor is now bound to the main thread.
        }

        // --- Command Handlers ---

        @MainActor
        func handleOpenApplication(identifier: String) async throws -> Macosusesdk_V1_TargetApplication {
            // All SDK calls are safely made from the MainActor.
            let result = try await MacosUseSDK.openApplication(identifier: identifier)
            return Macosusesdk_V1_TargetApplication.with {
                $0.name = "targetApplications/\(result.pid)"
                $0.pid = result.pid
                $0.appName = result.appName
            }
        }

        @MainActor
        func handleGlobalInput(request: Macosusesdk_V1_ExecuteGlobalInputRequest) async throws {
            let sdkAction = try ProtoMapper.toSDKInputAction(request.input)
            let options = ProtoMapper.toSDKActionOptions(
                pid: 0, // Not used for global
                options: .with {
                    $0.showAnimation = request.showAnimation
                    $0.animationDuration = request.animationDuration
                }
            )

            // This is a private helper on the coordinator
            try await self.executeSDKInputAction(sdkAction, options: options)
        }

        @MainActor
        func handlePerformAction(pid: pid_t, request: Macosusesdk_V1_PerformActionRequest) async throws -> Macosusesdk_V1_ActionResult {
            let sdkAction = try ProtoMapper.toSDKPrimaryAction(request.action)
            let options = ProtoMapper.toSDKActionOptions(pid: pid, options: request.options)

            // Call the SDK's main coordinator
            let sdkResult = await MacosUseSDK.performAction(action: sdkAction, optionsInput: options)

            // Map the SDK result back to the proto result
            return try ProtoMapper.toProtoActionResult(sdkResult)
        }

        @MainActor
        func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws -> Macosusesdk_V1_ResponseData {
             let sdkResponse = try MacosUseSDK.traverseAccessibilityTree(
                pid: pid,
                onlyVisibleElements: visibleOnly
             )
             return try ProtoMapper.toProtoResponseData(sdkResponse)
        }

        // --- Private SDK Execution Helper ---

        @MainActor
        private func executeSDKInputAction(_ action: MacosUseSDK.InputAction, options: MacosUseSDK.ActionOptions) async throws {
            // This logic is extracted from ActionCoordinator.executeInputAction
            // to be reusable for global inputs.
            let duration = options.animationDuration

            switch action {
            case .click(let point):
                if options.showAnimation {
                    try MacosUseSDK.clickMouseAndVisualize(at: point, duration: duration)
                } else {
                    try MacosUseSDK.clickMouse(at: point)
                }
            case .type(let text):
                if options.showAnimation {
                    try MacosUseSDK.writeTextAndVisualize(text, duration: duration)
                } else {
                    try MacosUseSDK.writeText(text)
                }
            // ... implement all other cases: doubleClick, rightClick, press, move
            // ...
            default:
                 throw URLError(.cancelled) // Placeholder
            }
        }
    }
    ```

### **3.4 Server Entrypoint (`main.swift`)**

  * **Action:** Modify `Server/Sources/main.swift`.
  * **Purpose:** Initializes the `NSApplication`, loads configuration, starts the gRPC server, and parks the main thread.
  * **Specification:**
    ```swift
    import Foundation
    import AppKit // CRITICAL: Must initialize NSApplication
    import GRPC
    import NIOCore
    import NIOPosix

    // --- Configuration ---
    struct ServerConfig {
        let listenAddress: String
        let port: Int
        let unixSocketPath: String?

        static func fromEnvironment() -> ServerConfig {
            let host = ProcessInfo.processInfo.environment["GRPC_LISTEN_ADDRESS"] ?? "127.0.0.1"
            let port = Int(ProcessInfo.processInfo.environment["GRPC_PORT"] ?? "8080") ?? 8080
            let socket = ProcessInfo.processInfo.environment["GRPC_UNIX_SOCKET"]
            return ServerConfig(listenAddress: host, port: port, unixSocketPath: socket)
        }
    }

    @main
    struct MacosUseServer {
        static func main() async throws {
            // 1. Initialize NSApplication. This is MANDATORY for the SDK.
            // We must do this before any SDK code is touched.
            let app = NSApplication.shared

            let config = ServerConfig.fromEnvironment()
            let stateStore = AppStateStore()

            // 2. Create the gRPC providers
            let desktopService = DefaultDesktopService(stateStore: stateStore)
            let targetsService = DefaultTargetApplicationsService(stateStore: stateStore)

            // 3. Set up the gRPC server
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                try! group.syncShutdownGracefully()
            }

            let serverBuilder = Server.usingTLS(
                /* ... TLS config ... */
            ).withServiceProviders([
                desktopService,
                targetsService
            ])
            // ... OR without TLS for local dev:
            // let serverBuilder = Server.insecure(group: group)
            //    .withServiceProviders([desktopService, targetsService])

            let server: Server
            if let socketPath = config.unixSocketPath {
                server = try await serverBuilder.bind(to: .unixDomainSocket(socketPath)).get()
                print("Server started on unix socket: \(socketPath)")
            } else {
                server = try await serverBuilder.bind(host: config.listenAddress, port: config.port).get()
                print("Server started on: \(config.listenAddress):\(config.port)")
            }

            // 4. Park the main thread.
            // The gRPC server runs on its own EventLoopGroup threads.
            // The main thread MUST be kept alive and running the RunLoop
            // for the @MainActor (AutomationCoordinator) to function.
            print("Parking main thread. Server is running...")
            RunLoop.main.run()

            // This part will only be reached on shutdown.
            try await server.close().get()
            print("Server shut down.")
        }
    }
    ```

-----

## **Phase 4: gRPC Service Implementation (Swift)**

This phase implements the gRPC provider classes that bridge gRPC requests to the `AutomationCoordinator`.

### **4.1 Proto-to-SDK Mappers**

  * **Action:** Create `Server/Sources/ProtoMapper.swift`.
  * **Purpose:** A utility to translate between gRPC message types and the SDK's Swift structs.
  * **Specification:**
    ```swift
    import Foundation
    import MacosUseSDK
    import CoreGraphics

    // Utility to map between Proto and SDK types
    enum ProtoMapper {

        // --- To SDK ---

        static func toSDKInputAction(_ proto: Macosusesdk_V1_InputAction) throws -> MacosUseSDK.InputAction {
            switch proto.actionType {
            case .click(let p): return .click(point: toSDKPoint(p))
            // ... all other cases
            case .typeText(let t): return .type(text: t)
            case .pressKey(let k):
                let (keyName, flags) = try parseKeyCombo(k.keyCombo)
                return .press(keyName: keyName, flags: flags)
            default: throw URLError(.badURL) // Placeholder error
            }
        }

        static func toSDKPrimaryAction(_ proto: Macosusesdk_V1_PrimaryAction) throws -> MacosUseSDK.PrimaryAction {
            switch proto.actionType {
            case .input(let i): return .input(action: try toSDKInputAction(i))
            case .traverseOnly: return .traverseOnly
            default: return .traverseOnly
            }
        }

        static func toSDKActionOptions(pid: pid_t, options: Macosusesdk_V1_ActionOptions) -> MacosUseSDK.ActionOptions {
            return MacosUseSDK.ActionOptions(
                traverseBefore: options.traverseBefore,
                traverseAfter: options.traverseAfter,
                showDiff: options.showDiff,
                onlyVisibleElements: options.onlyVisibleElements,
                showAnimation: options.showAnimation,
                animationDuration: options.animationDuration,
                pidForTraversal: pid, // Injected from the resource name
                delayAfterAction: options.delayAfterAction
            )
        }

        static func toSDKPoint(_ proto: Macosusesdk_V1_Point) -> CGPoint {
            return CGPoint(x: proto.x, y: proto.y)
        }

        static func parseKeyCombo(_ combo: String) throws -> (keyName: String, flags: CGEventFlags) {
             // ... logic from InputControllerTool/main.swift ...
             return ("return", []) // Placeholder
        }

        // --- To Proto ---

        static func toProtoActionResult(_ sdk: MacosUseSDK.ActionResult) throws -> Macosusesdk_V1_ActionResult {
             // ... map all fields from sdk -> proto ...
             var proto = Macosusesdk_V1_ActionResult()
             if let openRes = sdk.openResult {
                 proto.pid = openRes.pid
                 proto.appName = openRes.appName
             }
             proto.traversalPid = sdk.traversalPid ?? 0
             // ...
             return proto
        }

        static func toProtoResponseData(_ sdk: MacosUseSDK.ResponseData) throws -> Macosusesdk_V1_ResponseData {
             // ... map all fields ...
             return Macosusesdk_V1_ResponseData() // Placeholder
        }
    }
    ```

### **4.2 `DesktopService` Implementation**

  * **Action:** Create `Server/Sources/DefaultDesktopService.swift`.
  * **Specification:**
    ```swift
    import Foundation
    import GRPC
    import MacosUseSDK

    final class DefaultDesktopService: Macosusesdk_V1_DesktopServiceAsyncProvider {
        let stateStore: AppStateStore

        init(stateStore: AppStateStore) {
            self.stateStore = stateStore
        }

        func openApplication(request: Macosusesdk_V1_OpenApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_TargetApplication {

            // 1. Send Command to MainActor Coordinator
            let target = try await AutomationCoordinator.shared.handleOpenApplication(
                identifier: request.identifier
            )

            // 2. Update shared state
            await stateStore.addTarget(target)

            // 3. Return response
            return target
        }

        func executeGlobalInput(request: Macosusesdk_V1_ExecuteGlobalInputRequest, context: GRPCAsyncServerCallContext) async throws -> Google_Protobuf_Empty {

            // 1. Send Command to MainActor Coordinator
            try await AutomationCoordinator.shared.handleGlobalInput(request: request)

            // 2. Return response
            return Google_Protobuf_Empty()
        }
    }
    ```

### **4.3 `TargetApplicationsService` Implementation**

  * **Action:** Create `Server/Sources/DefaultTargetApplicationsService.swift`.
  * **Specification:**
    ```swift
    import Foundation
    import GRPC
    import MacosUseSDK

    final class DefaultTargetApplicationsService: Macosusesdk_V1_TargetApplicationsServiceAsyncProvider {
        let stateStore: AppStateStore

        init(stateStore: AppStateStore) {
            self.stateStore = stateStore
        }

        private func parsePID(fromName name: String) throws -> pid_t {
            guard name.starts(with: "targetApplications/") else {
                throw GRPCStatus(code: .invalidArgument, message: "Invalid resource name format.")
            }
            guard let pid = pid_t(name.dropFirst("targetApplications/".count)) else {
                throw GRPCStatus(code: .invalidArgument, message: "Invalid PID in resource name.")
            }
            return pid
        }

        func getTargetApplication(request: Macosusesdk_V1_GetTargetApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_TargetApplication {
            let pid = try parsePID(fromName: request.name)
            guard let target = await stateStore.getTarget(pid: pid) else {
                throw GRPCStatus(code: .notFound, message: "Target application with PID \(pid) not found.")
            }
            // TODO: Could add a check here to see if PID is still running
            return target
        }

        func listTargetApplications(request: Macosusesdk_V1_ListTargetApplicationsRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_ListTargetApplicationsResponse {
            let targets = await stateStore.listTargets()
            return .with { $0.targetApplications = targets }
        }

        func deleteTargetApplication(request: Macosusesdk_V1_DeleteTargetApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Google_Protobuf_Empty {
            let pid = try parsePID(fromName: request.name)
            _ = await stateStore.removeTarget(pid: pid)
            return Google_Protobuf_Empty()
        }

        func performAction(request: Macosusesdk_V1_PerformActionRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_ActionResult {
            let pid = try parsePID(fromName: request.name)

            // Send command to MainActor Coordinator
            let result = try await AutomationCoordinator.shared.handlePerformAction(
                pid: pid,
                request: request
            )
            return result
        }

        func watch(request: Macosusesdk_V1_WatchRequest, responseStream: GRPCAsyncResponseStreamWriter<Macosusesdk_V1_WatchResponse>, context: GRPCAsyncServerCallContext) async throws {
            let pid = try parsePID(fromName: request.name)
            let pollInterval = request.pollIntervalSeconds > 0 ? request.pollIntervalSeconds : 1.0

            var lastState: Macosusesdk_V1_ResponseData? = nil

            // Loop until the client cancels
            while !context.isCancelled {
                do {
                    // 1. Get current state
                    let currentState = try await AutomationCoordinator.shared.handleTraverse(
                        pid: pid,
                        visibleOnly: true // Watch only visible elements
                    )

                    // 2. Calculate diff if we have a previous state
                    if let- `prevState` = lastState {
                        // TODO: Implement a proper diff calculation
                        // let diff = calculateDiff(prevState.elements, currentState.elements)
                        let diff = Macosusesdk_V1_TraversalDiff() // Placeholder

                        // 3. Stream the diff
                        if !diff.added.isEmpty || !diff.removed.isEmpty || !diff.modified.isEmpty {
                            try await responseStream.send(
                                .with { $0.diff = diff }
                            )
                        }
                    }

                    lastState = currentState

                    // 4. Wait
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

                } catch {
                    // If traversal fails (e.g., app closed), end the stream.
                    print("Watch stream error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }
    ```

-----

## **Phase 5: Guarantees & Verification**

### **5.1 Guarantees**

1.  **AIP Compliance:** The API is resource-oriented (`TargetApplication`) with standard (`Get`, `List`, `Delete`) and custom (`PerformAction`, `Watch`) methods.
2.  **Thread Safety:** All SDK calls (which require `@MainActor`) are funneled through the `AutomationCoordinator` global actor, which serializes all automation commands on the main thread.
3.  **Stateful Awareness:** The `AppStateStore` actor provides a thread-safe, queryable view of all application targets the server is managing.
4.  **Complete SDK Coverage:** The `PerformAction` RPC exposes the full power of the SDK's `ActionCoordinator.performAction`, which is a superset of all capabilities demonstrated in the standalone tools.
5.  **Multi-Target Support:** Clients can create and manage multiple `TargetApplication` resources concurrently, enabling multi-app automation.
6.  **Extensibility:** The `Watch` RPC provides a new, streaming-diff capability, extending the SDK's "diff" functionality.

### **5.2 Verification Plan**

A client (e.g., a Go test) will execute the following sequence:

1.  **gRPC Connect:** Connect to the running Swift gRPC server.
2.  **Create Target:** Call `DesktopService.OpenApplication` with `identifier: "Calculator"`.
      * **Assertion:** Receives a `TargetApplication` response, e.g., `name: "targetApplications/12345"`.
3.  **Perform Simple Action:** Call `TargetApplicationsService.PerformAction` with `name: "targetApplications/12345"` and a `PrimaryAction` to type "1+2=".
      * **Assertion:** RPC succeeds.
4.  **Perform Diff Action:** Call `TargetApplicationsService.PerformAction` with `name: "targetApplications/12345"`, `action: .traverseOnly`, and `options: .showDiff = true`.
      * **Assertion:** Receives an `ActionResult` where `traversalDiff` contains a change, showing "3" was added.
5.  **Create Second Target:** Call `DesktopService.OpenApplication` with `identifier: "Messages"`.
      * **Assertion:** Receives a *different* `TargetApplication`, e.g., `name: "targetApplications/67890"`.
6.  **List Targets:** Call `TargetApplicationsService.ListTargetApplications`.
      * **Assertion:** Receives a response containing *both* "targetApplications/12345" and "targetApplications/67890".
7.  **Start Watch:** In a separate goroutine, call `TargetApplicationsService.Watch` for "targetApplications/12345" and begin reading from the stream.
8.  **Trigger Watch:** Call `TargetApplicationsService.PerformAction` on "targetApplications/12345" to type "\*5=".
      * **Assertion:** The `Watch` stream (from step 7) yields a `WatchResponse` containing a `TraversalDiff` that reflects the change from "3" to "15".
9.  **Cleanup:** Call `TargetApplicationsService.DeleteTargetApplication` for both PIDs.
      * **Assertion:** A subsequent `ListTargetApplications` call returns an empty list.
