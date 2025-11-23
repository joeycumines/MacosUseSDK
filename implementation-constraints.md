# Implementation Constraints

## Critical Ways of Working (STRICT MANDATES)

**1. EXECUTION PROTOCOL (NON-NEGOTIABLE):**
- **NO DIRECT SHELL COMMANDS:** You are FORBIDDEN from running complex multi-argument shell commands directly.
- **MANDATORY `config.mk` PATTERN:** For ALL build steps, test runs, linting, or execution commands:
  1.  Define a **custom temporary target** in `config.mk`.
  2.  Execute it using the `mcp-server-make` tool.
- **FORBIDDEN ARGUMENT:** You MUST NOT specify the `file` option (e.g., `file=config.mk`) when invoking `mcp-server-make`. The invocation must rely strictly on the repository's default Makefile discovery (which includes `config.mk`).
- **LOGGING REQUIREMENT:** All `config.mk` recipes producing significant output MUST use `| tee $(or $(PROJECT_ROOT),$(error If you are reading this you specified the `file` option when calling `mcp-server-make`. DONT DO THAT.))/build.log | tail -n 15` (or similar) to prevent context window flooding.
  For example (add if missing to `config.mk` within `ifndef CUSTOM_TARGETS_DEFINED ... endif` per `example.config.mk`):
  ```makefile
  .PHONY: make-all-with-log
  make-all-with-log: ## Run all targets with logging to build.log
  make-all-with-log: SHELL := /bin/bash
  make-all-with-log:
  	@echo "Output limited to avoid context explosion. See $(or $(PROJECT_ROOT),$(error If you are reading this you specified the `file` option when calling `mcp-server-make`. DONT DO THAT.))/build.log for full content."; \
  	set -o pipefail; \
  	$(MAKE) all 2>&1 | tee $(or $(PROJECT_ROOT),$(error If you are reading this you specified the `file` option when calling `mcp-server-make`. DONT DO THAT.))/build.log | tail -n 15; \
  	exit $${PIPESTATUS[0]}
  ```

**2. CONTINUOUS VALIDATION:**
- **DO NOT BREAK THE BUILD:** You must run the core `all` target constantly. Use `mcp-server-make make-all-with-log` after every file change.
- **Resource Leak Check:** Integration tests must ensure proper cleanup of observations and connections at teardown.

**3. LOG OUTPUT PRIVACY:**
- AVOID and REPLACE ad-hoc `fputs` or unannotated `print` with `Logger` and `OSLogPrivacy` for any message emitted from Swift server components or SDK helpers in `Server/Sources/MacosUseServer` and `Sources/MacosUseSDK`.
- `fputs` is forbidden in these server/SDK directories for diagnostic logs — it bypasses OS unified logging and cannot mark privacy. Use `Logger` with explicit `privacy` annotations for every interpolated value. For user-facing CLI help text (static strings) `print` is allowed only outside `Server/Sources/MacosUseServer` and `Sources/MacosUseSDK`.

## Core Directives

Constraints in this section describe *requirements*, not current status.

The gRPC server MUST:
- Strictly follow **Google's AIPs** (2025 standards). When in doubt between `buf lint` and Google's AIPs, Google's AIPs take precedence.
- Support configuration via environment variables (socket paths, addresses).
- Maintain the **State Store** architecture: `AppStateStore` (copy-on-write view for queries), `WindowRegistry`, `ObservationManager`, and `SessionManager`.

Previous sins (now corrected, not to be repeated):
- **Pagination (AIP-158):** You MUST implement `page_size`, `page_token`, and `next_page_token` for ALL List/Find RPCs, and `page_token`/`next_page_token` MUST be treated as opaque by clients (no reliance on internal structure such as `"offset:N"`).
- **State-Difference Assertions:** Tests MUST NOT rely on "Happy Path" OK statuses. Every mutator RPC (Click, Move, Resize) MUST be followed by an accessor RPC to verify the *delta* in state.
- **Wait-For-Convergence:** Tests MUST use a `PollUntil` pattern. `time.Sleep` is FORBIDDEN in tests.

**API Scope:**
- Expose ALL functionality via the `MacosUse` service (consolidated service).
- Include all resources: Window, Element, Observation, Session, Macro, Screenshot, Clipboard, File, Script.
- Support advanced inputs: Modifiers, Special Keys, Mouse Operations (drag, right-click).
- Support VS Code integration patterns (multi-window, advanced targeting).

**Core Graphics/Cocoa/Accessibility Race Condition Mitigation:** Do not rely on `NSRunningApplication(processIdentifier:)` or `CGWindowListCopyWindowInfo` (and related `CGWindow*` APIs) for process/window liveness or existence checks when performing AX actions. These APIs can lag behind the real-time state of the Accessibility server. Always attempt AX actions (e.g., `AXUIElementCreateApplication(pid)`, `AXUIElementCopyAttributeValue`) directly, then handle invalid process/element errors if they occur. Using CG/NS APIs as a "guard" or "pre-check" introduces a race condition where valid AX targets are rejected because the slower API hasn't updated yet.

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

## Master (LIVING) Documents

**MUST BE KEPT UP TO DATE.** Must be analytical, terse, and precise.

- [docs/02-window-state-management.md](docs/02-window-state-management.md)

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
