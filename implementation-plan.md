**This is `./implementation-plan.md`. KEEP THE PLAN UP TO DATE AS YOU EVOLVE THE CODE. DEVIATIONS TO THE PLAN MUST BE LOGGED WITHIN THE PLAN. THE PLAN MUST BE REASSESSED HOLISTICALLY AFTER ANY CHANGE OF ANY SIZE.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**!! MANDATORY OPERATIONAL DIRECTIVE !!**
**The use of subagents via the `runSubagent` tool is MANDATORY for the execution of the tasks below. Tasks are grouped specifically to be run in distinct subagent contexts to prevent context window exhaustion. Do not attempt to solve all groups in a single turn.**

---

# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION (ACTION-FOCUSED)**

2*3=### **Current Reality (2025-11-22 20:45 JST - Takumi's Shame Audit)**

**CRITICAL BUILD FAILURES:**
1. Integration test `TestWindowChangeObservation` FAILS with `DeadlineExceeded` during `ResizeWindow` RPC.
   - **Root Cause:** Server DEADLOCK or excessive blocking during window mutation.
   - **Symptom:** ResizeWindow RPC times out after 3 minutes, never returns.
   - **Evidence:** Line 1775 of build.log shows "ResizeWindow (back to original) failed: rpc error: code = DeadlineExceeded desc = context deadline exceeded"

**CRITICAL DEFECTS (Immediate Action Required):**
1. **Window Lookup Consolidation NOT DONE** (FIX_ME_THEN_DELETE_THIS_DOC.md Section 3)
   - Server `WindowHelpers.swift` `findWindowElement()` STILL uses manual 2N IPC iteration.
   - SDK `WindowQuery.swift` `fetchAXWindowInfo()` exists but is UNUSED by Server.
   - This causes INEFFICIENCY (2N vs 1N IPC) and BRITTLENESS (strict 2px vs heuristic).
   - **Immediate Action:** Refactor Server to use SDK primitive.

2. **Dead Code Removal NOT DONE** (FIX_ME_THEN_DELETE_THIS_DOC.md Section 6.2)
   - `Server/Sources/MacosUseServer/Extensions.swift` contains unused `asyncMap` function.
   - **Immediate Action:** Delete the file.

3. **Async Input Controller NOT DONE** (FIX_ME_THEN_DELETE_THIS_DOC.md hints + implementation-plan)
   - `InputController.swift` uses `usleep` (blocking).
   - Must convert to `async/await` with `Task.sleep`.
   - **Immediate Action:** Refactor InputController to be async.

---

### **Work Queue (MANDATORY IMMEDIATE EXECUTION)**

**TASK 1: Fix ResizeWindow Deadlock**
* [ ] Investigate why `resizeWindow()` in `MacosUseServiceProvider.swift` causes 3-minute timeout.
* [ ] Check if `findWindowElement()` or `windowRegistry.refreshWindows()` blocks main thread.
* [ ] Verify Task.detached isolation is correct for AX operations.

**TASK 2: Window Lookup Consolidation (FIX_ME Section 3)**
* [ ] Verify SDK `WindowQuery.swift` `WindowInfo` struct includes `element: AXUIElement` field.
* [ ] Refactor Server `WindowHelpers.swift` `findWindowElement()` to call SDK's `fetchAXWindowInfo()`.
* [ ] Remove Server's manual 2N IPC loop.
* [ ] Update all callers to use consolidated implementation.

**TASK 3: Dead Code Removal (FIX_ME Section 6.2)**
* [ ] Delete `Server/Sources/MacosUseServer/Extensions.swift`.

**TASK 4: Async Input Controller (FIX_ME Liveness)**
* [ ] Convert `InputController.swift` methods to `async/await`.
* [ ] Replace `usleep` with `Task.sleep`.
* [ ] Update `AutomationCoordinator` to await InputController calls.

**TASK 5: Verification**
* [ ] Run `make-all-with-log` and ensure zero failures.
* [ ] Run `test-integration-all` and ensure all tests pass.
* [ ] Verify `TestWindowChangeObservation` specifically passes without timeout.

---

## **Phase 4: Testing Strategy**

### **4.1 Unit Tests**
- **Requirement:** Every fix must have accompanying unit test verification.
- **Strictness:** `integration/observation_test.go` must remain an EFFECTIVE test of the logic it covers.

### **4.2 Test Harness**
- **Golden Apps:** `TextEdit`, `Calculator`, `Finder`.
- **Lifecycle:** Tests must clean up resources (DeleteApplication) aggressively.
  - TODO: This needs to be expanded to RELIABLY include hung API servers.

### **Correctness & Verification Guarantees**
1.  **State-Difference Assertions:** Mutator RPCs must be followed by Accessor RPCs to verify delta.
2.  **PollUntil Pattern:** No `time.Sleep()`. Use polling with timeouts.

---
**END OF IMPLEMENTATION PLAN**
(To provide an update, return to the "STATUS SECTION" at the top of this document.)

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**
