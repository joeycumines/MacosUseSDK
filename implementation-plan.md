**This is `./implementation-plan.md`. KEEP THE PLAN UP TO DATE AS YOU EVOLVE THE CODE. DEVIATIONS TO THE PLAN MUST BE LOGGED WITHIN THE PLAN. THE PLAN MUST BE REASSESSED HOLISTICALLY AFTER ANY CHANGE OF ANY SIZE.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**!! MANDATORY OPERATIONAL DIRECTIVE !!**
**The use of subagents via the `runSubagent` tool is MANDATORY for the execution of the tasks below. Tasks are grouped specifically to be run in distinct subagent contexts to prevent context window exhaustion. Do not attempt to solve all groups in a single turn.**

---

# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION (ACTION-FOCUSED)**

### **Current Reality**
The build passes, but the previous submission failed Code Review on **Correctness**, **Performance**, and **Completeness**. The codebase currently contains a memory leak, dead code in critical heuristics, main-thread blocking, and missing implementations for claimed features.

**CRITICAL DEFECTS (Must fix immediately):**
1.  **Memory Leak:** `InputController` introduces a retain cycle by capturing `[process]` without releasing it.
2.  **Dead Code:** `WindowQuery` ignores the `expectedTitle` argument, breaking the documented secondary matching heuristic.
3.  **UI Blocking:** `AutomationCoordinator` claims non-blocking behavior but performs the heavy `AX` traversal on `MainActor`.
4.  **Missing Implementation:** AIP-158 Pagination is marked complete, but the actual logic is missing from the codebase.

---

### **Work Queue (Grouped for Subagents)**

**GROUP A: Correctness & Logic Repairs (Target: `InputController.swift`, `WindowQuery.swift`)**
* **Subagent Objective:** Fix memory safety and heuristic logic.
* [ ] **Fix Retain Cycle (`InputController.swift`):** The closure captures `[process]` strongly. You MUST break the cycle by setting `proc.terminationHandler = nil` inside the completion block.
* [ ] **Restore Dead Code (`WindowQuery.swift`):** The signature `expectedTitle _: String?` ignores the argument. Remove the underscore `_` and ensure the "secondary matching heuristic" actually uses this parameter as documented.
* [ ] **Verify:** Run related unit tests to ensure no regression.

**GROUP B: Concurrency & Performance (Target: `AutomationCoordinator.swift`)**
* **Subagent Objective:** Address the mismatch between performance claims and reality.
* [ ] **Fix Main Thread Blocking:** The current fix only offloads Protobuf mapping. The heavy `MacosUseSDK.traverseAccessibilityTree` is still wrapped in `MainActor.run`. Investigate if `AXUIElement` traversal can be safely detached or if strict `MainActor` isolation is required. If it is required, the "Zero blocking calls" claim must be revised or the architecture adjusted to chunk the work. **Priority:** Move traversal off main thread if safe; otherwise, document the bottleneck explicitly.

**GROUP C: Missing Features (Target: `MacosUseServiceProvider.swift`, `MacosUseSDK`)**
* **Subagent Objective:** Actually implement the missing pagination logic.
* [ ] **Implement Pagination:** The code for AIP-158 (opaque tokens, page limits) is missing despite the tests being added. Implement the logic to handle `page_token` and `page_size` in the Provider/SDK layer.
* [ ] **Verify:** Ensure `integration/pagination_find_test.go` passes against *real* logic, not accidental defaults.

---

## **Objective**

Build a production-grade gRPC server exposing the complete MacosUseSDK functionality through a sophisticated, resource-oriented API following Google's AIPs.

## **Phase 1: API Definition (Reality-Aligned)**

### **1.1 Core Resources**

#### **Application** (`applications/{application}`)
- Proto: `proto/macosusesdk/v1/application.proto`.
- **Status:** Defined. Pagination on `ListApplications` requires verification (See Phase 3.4).

#### **Window** (`applications/{application}/windows/{window}`)
- Proto: `proto/macosusesdk/v1/window.proto`.
- **Status:** Defined. Pagination on `ListWindows` requires verification (See Phase 3.4).

#### **Element** (`applications/{application}/windows/{window}/elements/{element}`)
- Proto: `proto/macosusesdk/type/element.proto`.
- **Status:** Defined.

#### **Observation** (`applications/{application}/observations/{observation}`)
- Proto: `proto/macosusesdk/v1/observation.proto`.
- **Status:** Defined. Streaming implemented.

### **1.3 Element Targeting System**
- **Selector Syntax:** Defined in `proto/macosusesdk/type/selector.proto`.
- **Query System:** `FindElements` and `FindRegionElements` exist.

---

## **Phase 2: Server Architecture**

### **2.1 State Management**
- **Current Reality:** `AppStateStore` manages state.
- **Constraint:** Must maintain `@MainActor` constraints where AX APIs require it, but offload processing where possible.

---

## **Phase 3: Service Completeness (Concrete Gaps)**

### **3.1 Application & Window Services**
- ✅ Split-brain authority model implemented.
- ✅ Window mutations return immediate AX state.

### **3.4 Query & Pagination (MANDATORY & INCOMPLETE)**
**Current Status: FAILED / MISSING CODE**
- The implementation plan previously claimed this was complete. Code review proved the implementation logic was missing.
- **Requirement:**
    - Implement opaque token generation/parsing (base64).
    - Ensure `FindElements`, `ListWindows`, `ListApplications` respect `page_size`.
    - Ensure `next_page_token` is generated correctly.

---

## **Phase 4: Testing Strategy**

### **4.1 Unit Tests**
- **Requirement:** Every fix in Group A/B/C must have accompanying unit test verification.
- **Strictness:** `integration/observation_test.go` has been updated to strict 2px tolerance. This must be maintained.

### **4.2 Test Harness**
- **Golden Apps:** `TextEdit`, `Calculator`, `Finder`.
- **Lifecycle:** Tests must clean up resources (DeleteApplication) aggressively.

### **Correctness & Verification Guarantees**
1.  **State-Difference Assertions:** Mutator RPCs must be followed by Accessor RPCs to verify delta.
2.  **PollUntil Pattern:** No `time.Sleep()`. Use polling with timeouts.

---

## **Phase 10: Implementation Priorities (Revised)**

### **Priority 1: Critical Defect Remediation (IMMEDIATE)**
Fix memory leaks (`InputController`), dead code (`WindowQuery`), and blocking calls (`AutomationCoordinator`).

### **Priority 2: Pagination Implementation (IMMEDIATE)**
Actually write the code that makes the pagination tests pass validly.

### **Priority 3: Observation & Window Changes (HIGH)**
Add robust window and element change detection.

---
**END OF IMPLEMENTATION PLAN**
(To provide an update, return to the "STATUS SECTION" at the top of this document.)

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**
