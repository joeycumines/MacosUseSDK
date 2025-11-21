Ensure, or rather GUARANTEE the correctness and completeness of the current implementation and its reviews. Since you're _guaranteeing_ it, sink commensurate effort; you care deeply about keeping your word, after all. Even then, I expect you to think very, VERY hard, significantly harder than you might expect. Assume, from start to finish, that there's _always_ another inconsistency, omission, or ambiguity, and you just haven't caught it yet. Question all information provided — _only_ when it is simply impossible to verify are you allowed to trust, and whenever you trust you MUST specify that (as briefly as possible).

Your primary goal is to produce an accurate, exhaustive document that **reliably verifies the current implementation**, identifies **any and all issues**, and does so in a way that enables a **clear, consistent decision** to be made for each identified issue. Every point you raise must be actionable: for each concern, it should be obvious what decision(s) need to be taken, what trade-offs are in play, and what evidence supports each option. Your analysis must be sufficiently detailed that a reader can make **meaningful recommendations towards achieving the optimal outcome**, without having to re-derive any of your reasoning from scratch.

Provide a succinct summary, then a more detailed analysis. Your succinct summary must be such that **removing any single part, or applying any transformation or adjustment of wording, would make it materially worse**. The detailed analysis should be structured, but not verbose for its own sake: every sentence must either (a) increase fidelity of understanding, or (b) tighten the connection between evidence, conclusions, and decisions.

You MUST:

- Treat the existing reviews (`review-1.md`, `review-2.md`) and facts (`review-facts.md`) as **claims to be audited**, not as ground truth. For each claim, either:
  - Corroborate it with precise references into the implementation (filenames, function names, high-level descriptions of logic), or
  - Refute or qualify it, again with precise references.
- Explicitly call out where the two reviews disagree, and adjudicate those disagreements based on the code and protocol definitions.
- Distinguish clearly between:
  - **Hard facts** (directly observable from code / proto definitions / tests),
  - **Inferred behavior** (strongly implied by the implementation, but not strictly proven), and
  - **Assumptions** (things you cannot verify, that you are temporarily treating as true). Label each as such.
- For every non-trivial behavior, wire it back to the corresponding protocol or API surface (for example, how `window.proto` expectations are or are not satisfied by `MacosUseServiceProvider`, `WindowHelpers`, and `WindowQuery`).

You MUST NOT:

- Introduce new speculative requirements or preferences that are not grounded in the proto definitions, existing reviews, or obvious correctness/performance reasoning.
- Hand-wave around ambiguity. Wherever behavior is ambiguous, _pinpoint_ the ambiguity, explain what concrete outcomes it could lead to, and what additional information would resolve it.

Your output must be **ruthlessly organized** around decisions and issues, not around files. Group related concerns even if they span multiple components or layers.

---

## Context Snippets (for reference)

Below are curated, high-fidelity snippets and references. They are not to be re-summarized mechanically; instead, use them as precise anchors during analysis. Preserve their semantics exactly; if you paraphrase, you are responsible for not losing any nuance.

### 1. Review Facts & Prior Reviews

```markdown
File: review-facts.md

Summary: Factual observations that verify or falsify claims from the two reviews.

- Pagination **is** implemented in `MacosUseServiceProvider` (methods `encodePageToken`, `decodePageToken`, and pagination logic in `list*` methods and `find*` methods), and `ElementLocator` exposes a `maxResults` parameter.
- There is an **architectural divergence** in window lookup logic between Server (`WindowHelpers`) and SDK (`WindowQuery`), including different performance characteristics (per-attribute AX calls vs batched attribute fetches) and different matching heuristics.
- Concurrency fixes exist: `AutomationCoordinator` and window mutations in `MacosUseServiceProvider` use `Task.detached` to avoid main-thread blocking; `InputController` uses `withCheckedThrowingContinuation` to avoid `usleep`-based blocking and retain cycles.
- The implementation of `buildWindowResponseFromAX` in `MacosUseServiceProvider` aligns with the `window.proto` "Split-Brain Authority" model: AX as authority for title/bounds/minimized/hidden, registry as authority for z-index/bundle ID, and a hybrid `visible` calculation.
- `asyncMap` in `Extensions.swift` is currently unused.

File: review-1.md

- Contains an earlier review that claimed: (a) pagination was effectively missing or incomplete, and (b) architectural differences between Server and SDK window logic were problematic, among other concurrency and correctness concerns.
- Some claims are now known to be incorrect or overstated (e.g., pagination absence) in light of `review-facts.md`.

File: review-2.md

- Provides a revised review that corrects some of the earlier misstatements.
- Confirms:
  - Main-thread hang fixes via `Task.detached` for AX work.
  - A real race condition / "split-brain" risk in window lookup, due to geometry-based reconciliation between `CGWindowList` (snapshot, possibly stale) and live AX state.
  - That pagination logic **does** exist and is exercised by integration tests.
- Emphasizes the importance of distinguishing AX authority vs CG snapshot authority, especially for visibility and window state.
```

### 2. Server Element Location & Traversal

```swift
File: Server/Sources/MacosUseServer/ElementLocator.swift

public actor ElementLocator {
	public static let shared = ElementLocator()

	public func findElements(
		selector: Macosusesdk_Type_ElementSelector,
		parent: String,
		visibleOnly: Bool = false,
		maxResults: Int = 0,
	) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
		// 1) Parse parent (application vs application+window).
		// 2) Call `traverseWithPaths(pid:visibleOnly:)`.
		// 3) Filter via `matchesSelector`.
		// 4) Apply `maxResults` via `prefix(maxResults)` if > 0.
	}

	public func findElementsInRegion(
		region: Macosusesdk_Type_Region,
		selector: Macosusesdk_Type_ElementSelector?,
		parent: String,
		visibleOnly: Bool = false,
		maxResults: Int = 0,
	) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
		// Similar structure to `findElements`, but filters by region first, then optional selector,
		// then applies `maxResults` via `prefix(maxResults)`.
	}

	private func traverseWithPaths(pid: pid_t, visibleOnly: Bool) async throws -> [
		(Macosusesdk_Type_Element, [Int32]),
	] {
		let sdkResponse = try await MainActor.run {
			try MacosUseSDK.traverseAccessibilityTree(pid: pid, onlyVisibleElements: visibleOnly)
		}

		// Converts SDK elements into proto elements, registers them in `ElementRegistry`,
		// and assigns a synthetic path `[Int32(index)]` for now.
	}
}
```

Use this snippet to reason about:

- How `maxResults` interacts with server-side pagination in `MacosUseServiceProvider`.
- Whether the semantics expected by integration tests (especially pagination and deterministic ordering) are actually satisfied end to end.

### 3. Window Query (SDK) vs Window Helpers (Server)

```swift
File: Sources/MacosUseSDK/WindowQuery.swift

public struct WindowInfo {
	public let pid: Int32
	public let windowId: CGWindowID
	public let bounds: CGRect
	public let title: String
	public let isMinimized: Bool
	public let isHidden: Bool
	public let isMain: Bool
	public let isFocused: Bool
}

public func fetchAXWindowInfo(
	pid: Int32,
	windowId: CGWindowID,
	expectedBounds: CGRect,
	expectedTitle: String? = nil,
) -> WindowInfo? {
	// AXUIElementCopyAttributeValue(kAXWindowsAttribute) to get windows.
	// AXUIElementCopyMultipleAttributeValues to batch Position, Size, Title, Minimized, Main.
	// Computes a heuristic score based on difference between AX bounds and `expectedBounds`,
	// with a scoring bonus when `expectedTitle` matches the AX title.
	// Returns the best match below a threshold, or nil.
}
```

```swift
File: Server/Sources/MacosUseServer/WindowHelpers.swift

extension MacosUseServiceProvider {
	func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
		// Uses AXUIElementCreateApplication(pid) and kAXWindowsAttribute.
		// For each AX window, calls AXUIElementCopyAttributeValue for kAXPositionAttribute
		// and kAXSizeAttribute individually (per-window, per-attribute calls).
		// Fetches CGWindowListCopyWindowInfo as a snapshot, finds the CG window by ID,
		// and compares CG bounds vs AX bounds with a tolerance (~2px) to declare a match.
		// If no bounds match within tolerance, throws notFound.
	}

	func buildWindowResponseFromAX(...) async throws -> ServerResponse<Macosusesdk_V1_Window> {
		// On a detached Task, queries AX for position, size, title, minimized, hidden.
		// Reads optional metadata from WindowRegistry (layer, bundleID, isOnScreen).
		// Computes `visible` via split-brain formula:
		//   visible = (isOnScreen OR Assumption) && !axMinimized && !axHidden
		// Where Assumption = true if AX interaction succeeded and the window is not minimized/hidden.
	}
}
```

You must use these to:

- Compare performance characteristics (batched vs per-attribute IPC).
- Compare matching robustness (heuristic, title-aware vs strict geometry-only matching).
- Trace how AX authority vs CG snapshot authority is actually applied in the server.

### 4. Automation Coordinator & Concurrency

```swift
File: Server/Sources/MacosUseServer/AutomationCoordinator.swift

public actor AutomationCoordinator {
	public static let shared = AutomationCoordinator()

	public func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws
		-> Macosusesdk_V1_TraverseAccessibilityResponse
	{
		// Uses Task.detached(priority: .userInitiated) { try MacosUseSDK.traverseAccessibilityTree(...) }
		// to avoid blocking the main actor during AX traversal.
		// Then converts SDK elements to proto elements off-main-thread as well.
	}
}
```

Use this to validate claims about main-thread blocking, correctness of concurrency boundary placement, and interaction with `ElementLocator` (which calls `traverseAccessibilityTree` via `MainActor.run`). If there is any apparent tension, you must surface it explicitly.

### 5. Input Controller (OSAScript and Synthetic Input)

```swift
File: Sources/MacosUseSDK/InputController.swift

public func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) async throws { ... }
public func clickMouse(at point: CGPoint) async throws { ... }
public func doubleClickMouse(at point: CGPoint) async throws { ... }
public func rightClickMouse(at point: CGPoint) async throws { ... }
public func moveMouse(to point: CGPoint) async throws { ... }
public func writeText(_ text: String) async throws {
	// Uses /usr/bin/osascript with a single -e script, wrapping in
	// withCheckedThrowingContinuation, and carefully clearing process.terminationHandler
	// to avoid retain cycles. Parses stderr for error messages.
}
public func mapKeyNameToKeyCode(_ keyName: String) -> CGKeyCode? { ... }
```

Use this to:

- Check whether the reviews' claims about input behavior, error handling, and async behavior are accurate.
- Consider how this interacts with higher-level `AutomationCoordinator` APIs.

### 6. Extensions & Dead Code

```swift
File: Server/Sources/MacosUseServer/Extensions.swift

extension Sequence {
	func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
		var result: [T] = []
		for element in self {
			try await result.append(transform(element))
		}
		return result
	}
}
```

This function is currently unused, but your analysis should note:

- Whether it is correctly implemented (semantics, error propagation, ordering).
- Whether it should be removed, wired in, or documented as an intentional future primitive.

### 7. Window Proto Contract

```proto
File: proto/macosusesdk/v1/window.proto

message Window {
  string name = 1;
  string title = 2;  // AX authority, fresh kAXTitleAttribute.
  Bounds bounds = 3; // AX authority, fresh kAXPositionAttribute + kAXSizeAttribute.
  int32 z_index = 4; // Registry authority, cached from CGWindowList via WindowRegistry.
  bool visible = 5;  // Split-brain formula combining Registry.isOnScreen, AX.Minimized, AX.Hidden.
  string bundle_id = 10; // Registry authority, via NSRunningApplication.
}

message WindowState {
  string name = 1;
  bool resizable = 2;   // AXSizeSettable
  bool minimizable = 3; // AXMinimizeButton
  bool closable = 4;    // AXCloseButton
  bool modal = 5;       // kAXModalAttribute and/or kAXSubroleAttribute
  bool floating = 6;    // kAXSubroleAttribute contains "Floating"
  bool ax_hidden = 7;   // Fresh kAXHiddenAttribute
  bool minimized = 8;   // Fresh kAXMinimizedAttribute
  bool focused = 9;     // Fresh kAXMainAttribute
  optional bool fullscreen = 10; // Currently unimplemented / optional
}
```

You must use this proto as the **single source of truth** for what is considered "correct" behavior for window-related APIs. Whenever you analyze server or SDK code (`MacosUseServiceProvider`, `WindowHelpers`, `WindowQuery`), explicitly check and state whether it conforms to, violates, or only partially implements these contracts.

### 8. MacosUseServiceProvider (Spot-Check Only Where Relevant)

```swift
File: Server/Sources/MacosUseServer/MacosUseServiceProvider.swift

final class MacosUseServiceProvider: Macosusesdk_V1_MacosUse.ServiceProtocol {
	// Holds stateStore, operationStore, windowRegistry.

	// Pagination helpers:
	private func encodePageToken(offset: Int) -> String { ... }
	private func decodePageToken(_ token: String) throws -> Int { ... }

	// Application pagination:
	func listApplications(...) async throws -> ServerResponse<Macosusesdk_V1_ListApplicationsResponse> {
		// Sorts applications, decodes page_token to offset, slices by pageSize,
		// and encodes nextPageToken if more results exist.
	}

	// Input pagination:
	func listInputs(...) async throws -> ServerResponse<Macosusesdk_V1_ListInputsResponse> { ... }

	// Window listing and lookup:
	func getWindow(...) async throws -> ServerResponse<Macosusesdk_V1_Window> { ... }
	func listWindows(...) async throws -> ServerResponse<Macosusesdk_V1_ListWindowsResponse> { ... }

	// Window mutation endpoints (focus/move/resize/minimize/restore) delegate to AX helpers
	// and typically return responses built via `buildWindowResponseFromAX`.
}
```

You are allowed to only **spot-check** this file, focusing on:

- Pagination behavior.
- Interaction with `WindowHelpers` / `WindowRegistry` for window operations.
- Alignment with `window.proto` semantics (especially `visible` and the split-brain model).

Avoid re-reading or re-summarizing unrelated parts.

---

When producing your final document:

- Keep the original linguistic style: slightly insistent, precise, and optimization-obsessed.
- Preserve key phrases like "Ensure, or rather GUARANTEE", "think very VERY hard", and the emphasis on questioning everything.
- Any deviations or improvements MUST be incremental in tone and structure, not wholesale changes.

Remember: **your job is to guarantee that a clear, consistent decision can be made for each issue surfaced by the reviews, based on the actual implementation and protocol contracts.**