---
name: macos-use
description: >
  Automates macOS desktop applications through the MacosUseSDK MCP server.
  Finds and interacts with UI elements via Accessibility (AX) APIs, types text,
  clicks, manages windows, automates browsers, executes multi-action transactions,
  and provides visual grounding fallback. Activates for: "macos automation",
  "desktop automation", "control mac app", "click button", "automate app",
  "accessibility", "desktop ui", "mac automation", "interact with application",
  "open app", "type text into", "desktop control", "ui automation", "browse website",
  "navigate browser", and any GUI-level task on macOS.
license: MIT
compatibility: Requires MacosUseSDK MCP server running with macOS Accessibility permissions.
metadata:
  author: MacosUseSDK Team
  version: 1.2.0
  mcp-server: macos-use
---

# macOS Desktop Automation (`macos-use`)

Automate macOS applications through the `macos-use` MCP server. The Accessibility (AX)
API is your primary interface — giving direct access to every element's role, text,
geometry, and state without pixel processing. When AX is supported, use AX first;
screenshots are for visual inspection, not for text reading. When AX is disabled by
application runtimes (such as Java/Swing in JetBrains IDEs), seamlessly transition to
visual grounding.

---

## Core Principles

### 1. High-Efficiency Transactions

Avoid slow, conversational turn-by-turn micro-steps. Driving GUI automation via an AI
agent requires compact, purposeful transactions:
- **AX First means stop when you have the data:** If `find_elements` returns the element
  handle and text, **do not take a screenshot** before clicking. Take screenshots only
  when you need visual verification (layouts, canvas, images).
- **Act immediately on discovered handles:** Dynamic UI handles (`elem_<timestamp>_<id>`)
  expire when the underlying DOM or view redraws. Discover and interact in the same or
  immediate next step.
- **Group related actions:** If you need to open a new tab, navigate, and search, execute
  the sequence with minimal pauses instead of waiting for conversational turns between
  every click.
- **Use macros for repetitive sequences:** When replaying an identical sequence of inputs
  on a stable target, use `create_macro` and `execute_macro` to execute as one owned
  server transaction.

### 2. App Runtime Paradigms & AX Support

Different application frameworks expose macOS Accessibility in distinct ways. Diagnose
the app type before deciding on your interaction strategy:

1. **Native Cocoa & GPUI (Terminal, Zed, Finder, System Settings, TextEdit, Calculator):**
   - Full, rich AX tree.
   - `find_elements` and `click_element` work with sub-millisecond precision.
2. **Chromium & WebViews (Chrome, Electron, Slack, VS Code, Discord):**
   - Rich `AXWebArea` accessibility tree.
   - **Caveat: Dynamic DOMs invalidate handles rapidly.** Act on element handles promptly.
   - **Caveat: Chrome Profile Picker.** On cold launch, Chrome often presents a profile
     selection window before the main browser window appears.
   - **Caveat: Address Bar & Web Input.** Direct AX mutation (`type_element(input_method="ax")`)
     may be restricted on web address bars. Click the address bar and use physical
     `type(target, text)` followed by `keypress(target, keys=["enter"])`.
3. **Java / Swing / JetBrains Runtime (GoLand, IntelliJ, PyCharm, WebStorm):**
   - **Default: Accessibility API Disabled.** JetBrains Runtime disables the Java
     Accessibility Bridge (JAB) by default to reduce overhead. Direct AX queries fail
     with `kAXErrorAPIDisabled (-25211)` or `kAXErrorCannotComplete (-25202)`.
   - **Enabling AX:** Requires checking **Settings → Appearance & Behavior → Appearance →
     Accessibility → "Support screen readers"** and restarting the IDE.
   - **Visual Grounding Fallback:** When screen reader support is disabled, use
     **Visual Grounding (Computer-Use Mode)**: capture `screenshot(window)`, compute
     target coordinates, and drive via `click`, `double_click`, `type`, and `keypress`.

### 3. Exact Resource Identity

Every tool requires an **exact opaque resource name**:
- Applications: `applications/{id}` (from `list_apps(kind="running")`)
- Application Bundles: `applicationBundles/{id}` (from `list_apps(kind="installed")`)
- Windows: `applications/{id}/windows/{id}` (from `list_windows(app)`)
- Displays: `displays/{id}` (from `get_display()`)
- Desktop: `desktop` (explicit keyword for the entire multi-monitor union)

Never invent, guess, or truncate resource IDs.

### 4. Multi-Monitor Coordinate System Math

MacosUseSDK uses **Global Display Coordinates (top-left origin)**:
- Origin `(0, 0)` is the top-left of the **primary display** (`displays/1`).
- Secondary monitors can have **negative coordinates** (e.g., positioned to the left or above).
- Window bounds returned by `list_windows` and `screenshot` report their global origins.
- To convert a window-local coordinate `(local_x, local_y)` to a global point for `click`
  or `scroll`:
  $$\text{global\_x} = \text{window.x} + \text{local\_x}$$
  $$\text{global\_y} = \text{window.y} + \text{local\_y}$$
  This math works uniformly across all displays without manual monitor offset mapping.

### 5. Handle Staleness & Selector Disambiguation

- **Stale Handle:** If `click_element` reports `Element ... is no longer available`, the
  underlying UI redrew. Re-run `find_elements(force_refresh=true)` and click immediately,
  or fall back to clicking the center point obtained from `read_element(element)`.
- **Selector Ambiguity:** If `click_element(selector="text:X")` returns
  `FailedPrecondition - Selector matched multiple elements`, do not repeat the same selector.
  Use `find_elements` with that text to inspect all matches, pick the interactable handle
  (e.g., `role:AXLink` or `role:AXButton` instead of `role:AXHeading` or `role:AXGroup`),
  and call `click_element(parent, element=handle)`.

### 6. Click Escalation

When an interaction does not produce the expected result, escalate immediately rather
than repeating the same failed call:
1. `click_element(parent, element=handle)` — clicks geometric center and acquires focus.
2. Coordinate click on center — `click(target=window, x=bounds.x + width/2, y=bounds.y + height/2)`.
3. Keyboard trigger — `keypress(target=window, keys=["enter"])` or `keys=["space"]`.
4. Visual inspection — `screenshot(window)` to verify actual window state and popups.

---

## Standard Operating Procedures

### Workflow 1: Browser Automation (Chrome, Safari, Firefox)

1. **Launch / Focus:**
   - Call `list_apps(kind="running")` to check if the browser is running. If not,
     `open_app(bundle)` with the bundle resource from `list_apps(kind="installed")`.
   - Call `list_windows(app)` to obtain the browser window.
   - If Chrome shows a Profile Picker window (e.g. `Open Person 1 profile`), click the
     profile button via `click_element` to open the main window.
2. **Navigate to URL:**
   - Focus the browser window: `focus_window(window)`.
   - Click "New tab" button via `click_element(selector="text:New tab")` or use shortcut
     `keypress(target=window, keys=["cmd", "t"])`.
   - Focus the address bar via `click_element(selector="role:AXTextField")` or click its
     center coordinates.
   - Enter URL: `type(target=window, text="https://...")` followed by
     `keypress(target=window, keys=["enter"])`.
   - Wait for page load: `wait(duration=2..4)`.
3. **Browse & Interact:**
   - Query page content using `find_elements(parent=window, selector="role:AXHeading")` or
     `role:AXLink` to discover content.
   - Click links/buttons using `click_element` or center-coordinate `click`.
   - Scroll through feeds: `scroll(target=window, x=center_x, y=center_y, scroll_y=500)`
     followed by `wait(1.0)` and `find_elements(force_refresh=true)`.

### Workflow 2: Visual Grounding Fallback (JetBrains IDEs, Canvas, Games)

When an application's accessibility tree returns `kAXErrorAPIDisabled (-25211)` or
`kAXErrorCannotComplete (-25202)`:
1. Focus the application window with `focus_window(window)`.
2. Capture a window screenshot: `screenshot(window=window, format="png")`.
3. View the image to identify visual targets, tabs, buttons, or input areas.
4. Calculate global coordinates:
   $$\text{target\_x} = \text{window.x} + \text{pixel\_x}$$
   $$\text{target\_y} = \text{window.y} + \text{pixel\_y}$$
5. Perform pointer or keyboard actions:
   - Double-click to open files: `double_click(target=window, x=target_x, y=target_y)`.
   - Click to focus text editor: `click(target=window, x=target_x, y=target_y)`.
   - Type code or comments: `type(target=window, text="...")`.
   - Send shortcuts: `keypress(target=window, keys=["cmd", "s"])`.
6. Verify outcome with a subsequent targeted screenshot.

### Workflow 3: Native Desktop App Interaction

1. `find_elements(parent=window, selector="role:AXButton")` or specific text.
2. `click_element(parent=window, element=handle)` to click and focus.
3. For text fields: `type_element(parent=window, element=handle, text="value")`.
4. Re-query AX with `force_refresh=true` or use `read_element` to confirm changes.

---

## Quality Checklist

Before declaring a desktop automation task complete, verify:
- [ ] Correct application and window were targeted using exact resource names.
- [ ] AX tree was utilized first before taking any screenshots.
- [ ] Dynamic element handle staleness was handled gracefully (immediate click or coordinate center fallback).
- [ ] If browser was used, profile picker and address bar submission were handled cleanly.
- [ ] If an AX-disabled app (JetBrains) was encountered, visual grounding was cleanly applied without looping on failed AX calls.
- [ ] Final state was confirmed through AX readback or targeted verification.

---

## Concrete Examples

### Example 1: Efficient Browser Navigation & Feed Discovery

**User says:** "Open Chrome, go to reddit.com/r/animemes, and list the top posts."

**Actions:**
1. Discover Chrome with `list_apps(kind="running")` and `list_windows(app)`.
2. If profile picker is active, click `elem_... - Open Person 1 profile`.
3. Locate address bar with `find_elements(parent=window, selector="role:AXTextField")`.
4. Click address bar, `type(target=window, text="https://www.reddit.com/r/animemes")`, and `keypress(target=window, keys=["enter"])`.
5. `wait(duration=3.0)`.
6. Discover meme posts using `find_elements(parent=window, selector="role:AXHeading")`.
7. Extract and present titles directly from AX elements without needing OCR.

**Result:** Fast, reliable navigation and structured post extraction in minimal roundtrips.

### Example 2: Handling Non-AX Applications (JetBrains / GoLand)

**User says:** "Open metrics.go in GoLand and add a comment."

**Actions:**
1. `find_elements` returns `AX error -25202 (kAXErrorCannotComplete)` due to disabled JAB.
2. Seamlessly pivot to Visual Grounding: capture `screenshot(window=window)`.
3. Locate `metrics.go` in the project tree crop at local `(130, 498)`.
4. Calculate global position: `x = 1207 + 130 = 1337`, `y = -1440 + 498 = -942`.
5. Execute `double_click(target=window, x=1337, y=-942)` to open file.
6. Click editor area, send `type(target=window, text="// updated")`, and save.
7. Confirm with verification screenshot.

**Result:** Task completed successfully despite complete lack of Accessibility tree support.

---

## Troubleshooting Reference

| Error / Symptom | Root Cause | Exact Fix |
| :--- | :--- | :--- |
| `AX error -25202` or `-25211` (`kAXErrorAPIDisabled`) | Application runtime (e.g. JetBrains JBR / Swing) has accessibility disabled | Fall back to **Workflow 2 (Visual Grounding)** using window screenshot + coordinate calculation. Or advise user to enable "Support screen readers" in IDE settings. |
| `Element ... is no longer available` | Underlying DOM or UI redrew, invalidating the cached snapshot handle | Call `find_elements(force_refresh=true)` and click immediately, or click the element's center coordinate via `click(target=window, x, y)`. |
| `FailedPrecondition - Selector matched multiple elements` | Multiple elements (e.g. heading, link, group) share identical text | Use `find_elements` with that text to view all matches, select the exact interactable handle (`role:AXLink` or `role:AXButton`), and pass `element=handle`. |
| Browser shows wrong screen after launch | Chrome Profile Picker is waiting for profile selection | Inspect AX tree for `Open Person 1 profile` or `Guest mode` and click it before attempting browser navigation. |
| Address bar doesn't navigate on `type_element` | Browser security blocks direct AX text mutation in URL bar | Click the address bar to focus it, use physical `type(target=window, text=url)`, then send `keypress(target=window, keys=["enter"])`. |
| Click misses target on secondary monitor | Origin calculation ignored display coordinate offset | Use Global Display Coordinates: $\text{global} = \text{window origin} + \text{local coordinate}$. Secondary displays often have negative origins. |

---

## Reference Documents

- **[references/workflows-and-tools.md](references/workflows-and-tools.md)** — Complete tool parameter reference, macro recipes, and advanced workflow patterns.
- **[references/mcp-reliability-recommendations.md](references/mcp-reliability-recommendations.md)** — Empirical reliability notes on focus acquisition, handle lifecycles, and coordinate clicks.
- **[references/window-state-management.md](references/window-state-management.md)** — Window enumeration, Space limitations, and visibility semantics.
