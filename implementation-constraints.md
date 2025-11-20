# Implementation Constraints

## Session Directives

````markdown
# Implementation Constraints

## Session Directives

**CURRENT DIRECTIVE (2025-11-20):** API Design Fix Complete - `WindowState` is now a singleton sub-resource per AIP-128. Continue with remaining implementation priorities: correctness fixes, unit tests, and integration test expansion.

- Maintain an exhaustive TODO list via the mandated tool before any code or plan edits; include every task from `implementation-plan.md`, every known deficiency, all active constraints, and motivational reminders.
- Never stop execution mid-task and do not ask clarifying questions; infer next actions from the plan and constraints, and continue iterating until the entire plan is complete.
- All progress must be incremental yet substantial per iteration, with the TODO list continuously reflecting accurate status and next steps.
- Absolutely no manual testing; every behavior must be validated through automated tests (unit, integration, end-to-end) and recorded in CI.
- Assume macOS availability with minimal preconditions (Calculator/TextEdit/Finder) when designing integration tests.
- You are responsible for all bookkeeping (plan + constraints) and for shipping a production-ready result immediately upon completion.

## Critical Ways of Working (STRICT MANDATES)

**1. EXECUTION PROTOCOL (NON-NEGOTIABLE):**
- **NO DIRECT SHELL COMMANDS:** You are FORBIDDEN from running complex multi-argument shell commands directly.
- **MANDATORY `config.mk` PATTERN:** For ALL build steps, test runs, linting, or execution commands:
  1.  Define a **custom temporary target** in `config.mk`.
  2.  Execute it using the `mcp-server-make` tool.
- **FORBIDDEN ARGUMENT:** You MUST NOT specify the `file` option (e.g., `file=config.mk`) when invoking `mcp-server-make`. The invocation must rely strictly on the repository's default Makefile discovery (which includes `config.mk`).
- **LOGGING REQUIREMENT:** All `config.mk` recipes producing significant output MUST use `| tee $(or $(PROJECT_ROOT),$(error If you are reading this you specified the `file` option when calling `mcp-server-make`. DONT DO THAT.))/build.log | tail -n 15` (or similar) to prevent context window flooding.

**2. CONTINUOUS VALIDATION:**
- **DO NOT BREAK THE BUILD:** You must run the core `all` target constantly. Use `mcp-server-make all` after every file change.
- **Resource Leak Check:** Integration tests must ensure proper cleanup of observations and connections at teardown.

## Core Directives (Refinement Phase)

The gRPC server scaffolding exists. The current objective is **Strict Correctness** and **Production Hardening**; constraints in this section describe *requirements*, not current status.

The gRPC server MUST:
- Use **only** the gRPC Swift 2 module(s) (`grpc-swift-2`, `GRPCCore`, `grpc-swift-nio-transport`, `grpc-swift-protobuf`) and leverage the existing `AutomationCoordinator` (@MainActor) as the central control loop. Legacy v1 packages, plugins, generated code, or incremental v1/v2 compatibility shims are **forbidden** and must be actively removed during migration.
- Strictly follow **Google's AIPs** (2025 standards). When in doubt between `buf lint` and Google's AIPs, Google's AIPs take precedence.
- Support configuration via environment variables (socket paths, addresses).
- Maintain the **State Store** architecture: `AppStateStore` (copy-on-write view for queries), `WindowRegistry`, `ObservationManager`, and `SessionManager`.

**Mandatory Functional Requirements (Blockers):**
- **Pagination (AIP-158):** You MUST implement `page_size`, `page_token`, and `next_page_token` for ALL List/Find RPCs, and `page_token`/`next_page_token` MUST be treated as opaque by clients (no reliance on internal structure such as `"offset:N"`).
- **State-Difference Assertions:** Tests MUST NOT rely on "Happy Path" OK statuses. Every mutator RPC (Click, Move, Resize) MUST be followed by an accessor RPC to verify the *delta* in state.
- **Wait-For-Convergence:** Tests MUST use a `PollUntil` pattern. `time.Sleep` is FORBIDDEN in tests.

**API Scope:**
- Expose ALL functionality via the `MacosUse` service (consolidated service).
- Include all resources: Window, Element, Observation, Session, Macro, Screenshot, Clipboard, File, Script.
- Support advanced inputs: Modifiers, Special Keys, Mouse Operations (drag, right-click).
- Support VS Code integration patterns (multi-window, advanced targeting).

## Testing and Tooling

- **Atomic Testing:** ALL new behavior and ALL modifications MUST be accompanied by automated tests in the SAME change set.
- **Golden Applications:** Integration tests must strictly target `TextEdit`, `Calculator`, or `Finder` as defined in the plan.
- **CI Integrity:** Tests and CI checks MUST be kept green. Disabling tests is forbidden without a documented fix plan.
- **Test Fixture Lifecycle:** Every test suite must ensure a clean state (SIGKILL target apps) before running and perform aggressive cleanup (DeleteApplication) after running.

## Documentation and Planning

- **Single Source of Truth:** ALL updates to the plan MUST be represented in `./implementation-plan.md`.
- **No Status Files:** Do NOT create `IMPLEMENTATION_COMPLETE.md` or similar. Do NOT use `implementation-constraints.md` to track status, progress logs, or completion markers of any kind.
- **Plan-Local Status Only:** The **STATUS SECTION (ACTION-FOCUSED)** at the top of `implementation-plan.md` is the only allowed place for high-level status, and it MUST list only remaining work, unresolved discrepancies, and critical patterns that must not be forgotten. Do not accumulate historical "done" items or emojis there.
- **Verification Before Completion Claims:** Before treating any item as complete, you MUST verify the implementation and its tests. If there is any doubt, treat the item as not done and keep (or re-add) a corresponding action in the plan.
- **Living Document:** Keep `./implementation-plan.md` strictly aligned with this constraints document and the *actual* code reality. Update it as part of every change set, trimming completed/verified items from the status section rather than appending new ones.

## Proto API Structure

- **Path:** Proto files MUST be located at `proto/macosusesdk/v1/` and mirror package structure.
- **Common Types:** Use `proto/macosusesdk/type` for shared definitions.
- **Separation:** Resource definitions MUST be in separate files from service definitions.
- **Naming:** Follow https://google.aip.dev/121, 190, and 191.
- **Linting:** Use `buf` for generation but `api-linter` (Google's linter) for design validation.

## Google API Linter Configuration

- `api-linter` MUST be run via a dedicated Go module in `hack/google-api-linter/`.
- Logic MUST be encapsulated in `./hack/google-api-linter.sh` (executable via `mcp-server-make`).
- Configuration MUST be in `./google-api-linter.yaml` with:
  ```yaml
  ---
  - included_paths:
      - 'google/**/*.proto'
    disabled_rules:
      - 'all'
  ```
- You MUST NOT ignore linting for anything except `googleapis` protos.

## CI/CD Workflows

- MUST use reusable workflow patterns (`workflow_call`).
- `ci.yaml` is the entry point; individual workflows must not have independent triggers.
- Scripts MUST NOT use `set -e`; use explicit chaining (`&&`) or condition checks.
