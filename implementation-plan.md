## Implementation Plan: MacosUseSDK gRPC Service

**CRITICAL:** This plan is **CONTINUALLY** refined. Constraints in [implementation-constraints.md](./implementation-constraints.md) are **AUTHORATIVE** and **MANDATORY**.

### Objective

Construct a fully-realized, production-grade gRPC server in Swift exposing complete MacosUseSDK functionality via a resource-oriented API adhering to Google's AIPs.

### Architecture Overview

- **Control Loop**: Swift Actor (`@MainActor`) on main thread serializing all SDK calls
- **State Management**: Actor-based with copy-on-write views
- **API Design**: Resource-oriented following all applicable AIPs
- **Concurrency**: Sophisticated patterns supporting multiple concurrent clients and applications

---

## Current Status

### ✅ Completed

#### Proto API (proto/macosusesdk/v1/)
- Proto directory restructured to `proto/macosusesdk/v1/` (was `proto/v1/`)
- Common types extracted to `proto/macosusesdk/type/` per AIP-213:
  - `geometry.proto`: Point type
  - `element.proto`: Element, TraversalStatistics types
- Resources in separate files:
  - `application.proto`: Application resource
  - `input.proto`: Input resource with state lifecycle
- Service consolidated to single `MacosUse` service in `macos_use.proto`
- All request/response messages co-located with service
- Mandatory file options added to all protos
- `OpenApplication` implemented as LRO using `google.longrunning.Operation` per AIP-151
- Inputs modeled as timeline resources:
  - Application-specific: `applications/{application}/inputs/{input}`
  - Global desktop: `desktopInputs/{input}`
- Input resources support Create, Get, List per AIP-133, AIP-131, AIP-132
- Application resources support Get, List, Delete per AIP-131, AIP-132, AIP-135
- Custom methods: `TraverseAccessibility`, `WatchAccessibility` per AIP-136
- Pagination support in List methods per AIP-158

#### Build System
- `buf.yaml` v2 configured with googleapis dependency
- `buf.lock` generated with locked dependency versions
- `buf.gen.yaml` v2 configured for Swift server and Go client generation
- All proto stubs generated in `gen/swift/` and `gen/go/`
- Go module (`go.mod`) initialized and tidied
- googleapis protos generated for both Swift and Go

#### CI/CD
- Reusable workflow pattern implemented with `workflow_call`
- Main `ci.yaml` workflow orchestrating all checks
- Individual workflows (buf, api-linter, swift) callable as jobs
- Final summary job with `if: always()` checking all results
- Scripts use `set -x` and explicit error handling (no `set -e`)
- Minimal permissions configured for all jobs

#### Linting & Validation
- `google-api-linter.yaml` configured to ignore googleapis protos only
- `hack/google-api-linter.sh` POSIX-compliant script:
  - Uses `buf export` for googleapis protos
  - Proper cleanup hooks with trap
  - GitHub Actions format output
- `buf lint` configured (AIPs take precedence over buf where conflicts exist)

#### Documentation
- `proto/README.md` documenting:
  - API design principles
  - Resource-oriented structure  
  - LRO pattern for OpenApplication
  - Input timeline and circular buffer semantics
  - Standard and custom methods
  - Common components rationale
  - File options
  - Code generation process
  - Linting tools

---

## Remaining Work

### Phase 1: Input Circular Buffer Implementation

**Objective**: Implement server-side circular buffer for completed inputs per application.

**Components**:
1. Buffer data structure in `AppStateStore`
   - Configurable size per application
   - FIFO eviction of oldest completed inputs
   - State: `STATE_COMPLETED` or `STATE_FAILED`

2. Buffer management in `AutomationCoordinator`
   - On input completion, add to application's buffer
   - Automatic eviction when buffer full
   - Thread-safe access via Actor

3. List method filtering
   - `ListInputs` supports `state_filter` parameter
   - Returns inputs from buffer + pending/executing inputs
   - Pagination support

**Acceptance**:
- Completed inputs retained in per-application circular buffer
- Buffer size configurable via `ServerConfig`
- Old inputs automatically evicted
- List/Get methods access buffer correctly

### Phase 2: Swift Server Implementation

**Objective**: Complete Swift server with full SDK integration.

#### 2.1 Update Server Package
- Add dependency on generated Swift stubs
- Update imports to use `gen/swift/` protos
- Ensure grpc-swift version compatibility

#### 2.2 Implement Service Providers

**MacosUseAsyncProvider Implementation**:
```swift
final class MacosUseProvider: Macosusesdk_V1_MacosUseAsyncProvider {
    let stateStore: AppStateStore
    let coordinator: AutomationCoordinator
    
    // Implement all 9 RPC methods
}
```

**Methods to implement**:
1. `openApplication`: Start LRO, coordinate with SDK
2. `getApplication`: Query state store
3. `listApplications`: Query state store with pagination
4. `deleteApplication`: Remove from tracking
5. `createInput`: Enqueue input, return resource
6. `getInput`: Query from buffer or pending queue
7. `listInputs`: Query with state filter and pagination
8. `traverseAccessibility`: Call SDK traversal
9. `watchAccessibility`: Stream accessibility changes

#### 2.3 Proto-to-SDK Type Mapping

Create `ProtoMapper.swift`:
- Convert proto `InputAction` ↔ SDK `InputAction`
- Convert proto `Application` ↔ SDK application info
- Convert proto `Element` ↔ SDK `ElementData`
- Handle all traversal and diff conversions

#### 2.4 Update AutomationCoordinator

- Replace temporary types with generated proto types
- Implement input execution queue
- Manage input state transitions
- Integrate with circular buffer
- LRO operation tracking

#### 2.5 Update AppStateStore

- Store `Application` proto resources
- Maintain input circular buffers per application
- Manage pending/executing input queues
- Support pagination for List methods

#### 2.6 Update ServerConfig

- Add buffer size configuration
- Add poll interval configuration for Watch
- Validate environment variables

#### 2.7 Implement main.swift

- Initialize NSApplication
- Load ServerConfig
- Create state store and coordinator
- Instantiate service provider
- Configure gRPC server (TCP or Unix socket)
- Start server and run main event loop

### Phase 3: Testing

#### 3.1 Unit Tests
- `AppStateStore` circular buffer tests
- Input state transition tests
- Proto mapper conversion tests
- Configuration parsing tests

#### 3.2 Integration Tests
- Go client tests exercising all RPCs
- LRO operation lifecycle tests
- Watch streaming tests
- Circular buffer eviction tests
- Multi-application concurrency tests

#### 3.3 End-to-End Tests
- Full automation workflows
- Error handling scenarios
- Resource lifecycle tests

### Phase 4: Documentation Updates

- Update `Server/README.md` with:
  - Circular buffer configuration
  - Input timeline usage
  - LRO operation handling
  - Watch streaming patterns
- Update examples with new API
- Add deployment guides for production

---

## Key Technical Decisions

### Input Timeline & Circular Buffer

**Design**: Inputs form an append-only timeline. Completed inputs are retained in a circular buffer.

**Rationale**:
- Enables audit trail of automation actions
- Supports debugging and pattern analysis
- Bounds memory usage with circular buffer
- Aligns with resource-oriented design (each input is a resource)

**Implementation**:
- Buffer per application (not global)
- Configurable size (default: 100 inputs)
- FIFO eviction
- States in buffer: `STATE_COMPLETED`, `STATE_FAILED`
- Pending/executing inputs NOT in buffer

### Long-Running Operations

**Design**: `OpenApplication` returns `google.longrunning.Operation`.

**Rationale**:
- Application launch can be slow
- Clients need async handling
- Enables cancellation
- Provides progress metadata
- Standard AIP-151 pattern

**Implementation**:
- Operation name: `operations/{uuid}`
- Metadata: `OpenApplicationMetadata` (identifier)
- Result: `OpenApplicationResponse` (Application resource)
- Stored in `AppStateStore` until completion

### Single Service Consolidation

**Design**: All methods in one `MacosUse` service (not `MacosUseService`).

**Rationale**:
- AIP-191 discourages "Service" suffix
- Logically cohesive set of operations
- Simpler client usage
- Clear API surface

### Common Components

**Design**: Minimal common types in `macosusesdk/type/`.

**Included**:
- `Point`: Truly reusable geometric type
- `Element`: Reused across traversal operations
- `TraversalStatistics`: Reused across traversal operations

**Excluded**:
- Input-specific types (in `input.proto`)
- Request/response messages (co-located with service)
- Application-specific types (in `application.proto`)

**Rationale**:
- AIP-213 emphasizes minimalism
- Avoid premature abstraction
- Common components for truly reusable types only

---

## Dependencies

- **grpc-swift**: v1.23.0+ (github.com/grpc/grpc-swift)
- **MacosUseSDK**: Local package dependency
- **googleapis**: buf.build/googleapis/googleapis (locked in buf.lock)
- **Go toolchain**: 1.23+ (for generated Go stubs)
- **Swift toolchain**: 6.0+ (for server)
- **buf**: v1.47.2+ (for proto tooling)

---

## Validation Checklist

- [x] Proto directory structure: `proto/macosusesdk/v1/`
- [x] Common types in `proto/macosusesdk/type/`
- [x] Resources in separate files
- [x] Single consolidated service
- [x] All mandatory file options
- [x] LRO for OpenApplication
- [x] Input timeline resources
- [x] Circular buffer design documented
- [x] buf.lock with locked dependencies
- [x] Generated stubs (Swift + Go)
- [x] CI workflows with reusable pattern
- [x] Main ci.yaml with summary job
- [x] Scripts use set -x, no set -e
- [x] google-api-linter configured and working
- [x] proto/README.md complete
- [ ] Circular buffer implemented in server
- [ ] Service provider implementations complete
- [ ] Proto mapper implementations complete
- [ ] AutomationCoordinator updated for new types
- [ ] AppStateStore updated for new types
- [ ] Server main.swift complete
- [ ] Unit tests passing
- [ ] Integration tests passing
- [ ] Server/README.md updated
- [ ] Examples updated
