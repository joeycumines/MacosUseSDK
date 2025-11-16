# MacosUseSDK Proto API

This directory contains the Protocol Buffer definitions for the MacosUseSDK gRPC API.

## Structure

```
proto/
├── macosusesdk/
│   ├── type/           # Common type definitions (AIP-213)
│   │   ├── geometry.proto   # Point and geometric types
│   │   └── element.proto    # UI element and traversal types
│   └── v1/             # API v1 definitions
│       ├── application.proto   # Application resource
│       ├── input.proto        # Input resource
│       └── macos_use.proto    # MacosUse service and methods
└── README.md
```

## API Design Principles

This API follows [Google's API Improvement Proposals (AIPs)](https://google.aip.dev/) strictly:

### Resource-Oriented Design

The API exposes two primary resources:

1. **Application** (`applications/{application}`)
   - Represents a running macOS application being tracked for automation
   - Supports standard methods: Get, List, Delete
   
2. **Input** (`applications/{application}/inputs/{input}` or `desktopInputs/{input}`)
   - Represents an input action in a timeline
   - Supports standard methods: Create, Get, List
   - Forms a timeline for each application or globally for the desktop

### Service Structure (AIP-190, AIP-191)

- Single service: `MacosUse` (not `MacosUseService` - service suffix is discouraged per AIP-191)
- File: `macos_use.proto` aligns with service name
- All method request/response messages co-located with the service
- Resources in separate files

### Common Components (AIP-213)

Common types that are reused across the API are placed in `macosusesdk/type/`:

- `Point`: 2D screen coordinates
- `Element`: UI element representation
- `TraversalStatistics`: Statistics from accessibility tree traversal
- `ElementSelector`: Declarative element querying system (see Selector Grammar below)

These are minimal and only include truly common, reusable types.

### Selector Grammar (Element Selection)

The `ElementSelector` type in `type/selector.proto` provides a declarative way to query UI elements in the accessibility tree.

**Implemented Features:**

1. **Simple Selectors** (all fully implemented):
   - `role: "AXButton"` → Match by accessibility role
   - `text: "Submit"` → Exact text match (checks AXValue then AXTitle)
   - `text_contains: "Submit"` → Substring match (case-sensitive)
   - `text_regex: "^Submit.*"` → Regex match using NSRegularExpression
   - `position: {x: 100, y: 200, tolerance: 5}` → Match element at screen coordinates
   - `attributes: {"AXEnabled": "1"}` → Match custom accessibility attributes (all must match)

2. **Compound Selectors** (fully implemented):
   - `OPERATOR_AND`: All sub-selectors must match
   - `OPERATOR_OR`: At least one sub-selector must match
   - `OPERATOR_NOT`: Single sub-selector must NOT match (requires exactly 1 selector)

3. **Empty Selector**: Matches ALL elements (use with caution)

**Example Usage:**

```protobuf
// Find button with text "Submit"
{
  compound: {
    operator: AND,
    selectors: [
      { role: "AXButton" },
      { text: "Submit" }
    ]
  }
}

// Find any button OR link
{
  compound: {
    operator: OR,
    selectors: [
      { role: "AXButton" },
      { role: "AXLink" }
    ]
  }
}

// Find elements NOT containing "Error"
{
  compound: {
    operator: NOT,
    selectors: [{ text_contains: "Error" }]
  }
}
```

**Implementation:**
- Validation: `Server/Sources/MacosUseServer/SelectorParser.swift`
- Matching: `Server/Sources/MacosUseServer/ElementLocator.swift`

**Performance:** Simple selectors (role, text, text_contains, position) are optimized. Regex and attribute selectors require full tree traversal.

### Long-Running Operations (AIP-151)

`OpenApplication` is implemented as a long-running operation using `google.longrunning.Operation`:

```protobuf
rpc OpenApplication(OpenApplicationRequest) returns (google.longrunning.Operation) {
  option (google.longrunning.operation_info) = {
    response_type: "OpenApplicationResponse"
    metadata_type: "OpenApplicationMetadata"
  };
}
```

This allows clients to:
- Poll for completion
- Cancel operations
- Receive metadata during execution

### Input Timeline & Circular Buffer

Inputs are modeled as resources forming a timeline:

- **Application-specific**: `applications/{application}/inputs/{input}`
- **Global desktop**: `desktopInputs/{input}`

Each input has a state lifecycle:
1. `STATE_PENDING`: Created but not yet executing
2. `STATE_EXECUTING`: Currently being executed
3. `STATE_COMPLETED`: Successfully completed
4. `STATE_FAILED`: Failed with an error

**Circular Buffer**: The server maintains a circular buffer of completed inputs per application. This allows:
- Querying recent input history
- Analyzing automation patterns
- Debugging failed sequences

The buffer size is server-configurable and oldest completed inputs are automatically evicted.

### Standard Methods (AIP-130, AIP-131, AIP-132)

All resources implement appropriate standard methods:

**Application**:
- `GetApplication` (AIP-131)
- `ListApplications` (AIP-132)
- `DeleteApplication` (AIP-135)

**Input**:
- `CreateInput` (AIP-133)
- `GetInput` (AIP-131)
- `ListInputs` (AIP-132)

### Custom Methods (AIP-136)

- `TraverseAccessibility`: Retrieves accessibility tree snapshot
- `WatchAccessibility`: Streams accessibility tree changes (server-streaming RPC)

### Pagination (AIP-158)

List methods support pagination with `page_size` and `page_token`:

```protobuf
message ListApplicationsRequest {
  int32 page_size = 1;
  string page_token = 2;
}

message ListApplicationsResponse {
  repeated Application applications = 1;
  string next_page_token = 2;
}
```

## File Options

All proto files include mandatory options per AIP-191:

```protobuf
option go_package = "github.com/joeycumines/MacosUseSDK/gen/go/...";
option java_multiple_files = true;
option java_outer_classname = "...Proto";
option java_package = "com.macosusesdk...";
```

## Code Generation

Generated code is committed to the repository:

- `Server/Sources/MacosUseSDKProtos/`: Swift server stubs (grpc-swift)
- `gen/go/`: Go client stubs

### Regenerating Code

```bash
buf generate
```

## Linting

The API is validated with both `buf lint` and `api-linter`:

### buf lint

```bash
buf lint
```

Note: Some buf lint warnings conflict with AIPs. Per `implementation-constraints.md`, AIPs take precedence.

### api-linter (Google's AIP linter)

```bash
./hack/google-api-linter.sh
```

This script:
1. Exports googleapis protos via `buf export`
2. Runs `api-linter` with proper proto paths
3. Outputs in GitHub Actions format
4. Ignores googleapis protos (configured in `google-api-linter.yaml`)

## Dependencies

- `buf.build/googleapis/googleapis`: Google API common protos and types

Dependencies are locked in `buf.lock` via:

```bash
buf dep update
```

## Versioning

The API is versioned as `v1`. Future breaking changes will require a new version (`v2`, etc) per AIP-180.

## HTTP/JSON Mapping

All RPCs include HTTP annotations enabling REST/JSON access via grpc-gateway:

```protobuf
rpc GetApplication(GetApplicationRequest) returns (Application) {
  option (google.api.http) = {
    get: "/v1/{name=applications/*}"
  };
}
```

## Contributing

When modifying the API:

1. Follow all applicable AIPs
2. Run `buf lint` and `./hack/google-api-linter.sh`
3. Regenerate code with `buf generate`
4. Update this README if structure changes
5. Update `implementation-plan.md` with significant changes
