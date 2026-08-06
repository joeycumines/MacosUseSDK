---
name: macos-use
description: >
  Automates macOS desktop applications through the MacosUseSDK MCP server.
  Covers opening apps, finding and interacting with UI elements via
  Accessibility APIs, typing text, clicking, window management,
  clipboard operations, scripts, macros, and display queries.
  Activates for: "macos automation", "desktop automation", "macos-use",
  "control mac app", "click button", "automate app", "accessibility",
  "desktop ui", "mac automation", "interact with application", "open app",
  "type text into", "desktop control", "ui automation", "macos use",
  and any task involving controlling or interacting with macOS applications
  or desktop elements programmatically, even if the user doesn't explicitly
  mention "macos-use" or "automation". Also activates when the user asks to
  interact with a running application, fill in forms, click buttons, read
  text from an app, or perform any GUI-level task on macOS.
---

# macOS Desktop Automation

Automate macOS apps via the `macos-use` MCP server. The Accessibility (AX)
API is your primary interface — every element's role, text, position, and
state is available without screenshots. Use AX first; screenshots only for
visual verification.

## Prerequisites

The `macos-use` MCP server must be running. If unavailable, direct the user
to `https://github.com/joeycumines/MacosUseSDK/blob/main/DEPLOYMENT.md`.
Do not install or configure it yourself.

## Core Principles

### AX First

Read the AX tree before doing anything else. `find_elements` is
non-destructive — call it freely.

1. **Call `find_elements`** on the exact application or window resource to
   understand what's on screen.
2. **If AX gave you the info, stop.** No screenshot needed.
3. **Only then**, if you need visual verification (colors, layout, canvas
   content), take a `screenshot`.

Screenshots are for *seeing*, not for *reading*. The AX tree gives you
every element's text — faster and more precise than OCR on pixels.

### Exact Resource Names

Every tool that targets a desktop entity requires an **exact opaque
resource name**: `applicationBundles/{id}`, `applications/{id}`, `applications/{id}/windows/{id}`,
`displays/{id}`, or the explicit `desktop` keyword for the active desktop
union. These come from `list_apps`, `list_windows`, or `get_display` —
never guess or synthesize them, and never pass display names or bundle
identifiers where a resource name is required.

### Click Escalation

`click_element` can fail on sheet buttons, modals, and overlays. When a
click doesn't produce the expected effect, escalate — don't retry:

1. **`click_element(parent, element)`** — clicks the element center and
   acquires focus; always try first with a `find_elements` handle.
2. **`click_element(parent, selector)`** — a selector such as
   `role:AXButton` or `text:Save` re-discovers the element; must resolve
   uniquely.
3. **Keyboard shortcut** — `keypress(target, keys=["return"])` or
   `keypress(target, keys=["escape"])`, or the app-specific shortcut via
   `type`/`keypress` on the exact window resource.
4. **`run(command, type="applescript")`** — System Events via
   AppleScript — last resort only.

Don't retry a failed `click_element` more than twice before escalating.
Repeated failed clicks waste rounds and risk hitting adjacent controls.

### Fresh Data After Interaction

After typing into a field or clicking a button, `find_elements` may return
stale text. Call `read_element` on the specific element or `find_elements`
again for a fresh read. `find_elements` also accepts `force_refresh` when
you need to discard the server's cached AX data.

### No AppleScript Detours

When AX tools can do the job, use them directly. `run` with AppleScript or
JavaScript is an escape hatch for things the AX tree can't reach (menu
commands without AX representation, app-specific scripting dictionaries).
Falling back to AppleScript when `click_element` or `type_element` would
work wastes a round-trip and is often blocked by authorization.

## App Lifecycle

Track an app with `open_app(bundle)` — pass the exact
`applicationBundles/*` resource returned by `list_apps` (or an exact
`applications/*` process resource to activate it). `list_apps` discovers
installed bundles and lists running processes (`kind="running"`); use it
before opening. Close owned apps with `close_app(app)` when the user's
task is done.

## Web Views (Tauri/Electron)

Web view apps show `AXWebArea` in the AX tree with heading/text structure
but not the full DOM.

**Opening devtools**: `keypress(target, keys=["meta", "option", "i"])`
or right-click → "Inspect Element".

**Reading console output**: Use `find_elements` to read console text
(`AXStaticText` elements). This is reliable.

**Typing into the console**: Unreliable — keyboard focus frequently lands on
the wrong application. Prefer reading existing console output via AX. If you
must evaluate JavaScript, use `type_element` with `input_method="keystrokes"`
on the console prompt (web views need DOM keyboard events), then press
Return, but expect focus issues. Consider shell tools instead if you have
native shell access.

**Copy details button**: On error screens, clicking "Copy details" or
similar and reading the clipboard via `clipboard(action="get")` is often the
fastest way to get structured error data.

## Shell Tools

If you have native shell access (like Claude Code), use it alongside AX for
investigating app backends — `ps`, `lsof`, `curl` for local HTTP APIs, and
database clients can reveal what the AX tree can't. (The MCP's own `run`
tool exists for environments without shell access — if you have shell, use
it instead.) Stay focused on the app's runtime state. Don't dig into source
code unless the user specifically asks — you're diagnosing the running app,
not auditing its codebase.

## Safety

- **No undo in GUI automation.** Before clicking, know what the element does.
  Inspect with `find_elements` or `read_element` first.
- **System Settings is off-limits.** Do not automate System Settings.
- **Coordinate clicks are risky.** Always prefer `click_element` with a
  `find_elements` handle. If you must use raw `click(x, y)`, target the
  **center** of the element's bounds — the top-left often lands on padding.
- **Background Space caveat.** Windows on other macOS Spaces may appear in
  `list_windows` but fail when accessed — the AX API only sees the active
  Space.

## Quick Reference

| Category | Key Tools |
|----------|-----------|
| **App** | `open_app(bundle)`, `list_apps(kind)`, `close_app(app)` |
| **Find** | `find_elements(parent, selector)`, `read_element(parent, element)` |
| **Click** | `click_element(parent, element \| selector)` |
| **Type** | `type_element(parent, element \| selector, text)`, `type(target, text)`, `keypress(target, keys)` |
| **Input** | `click(x, y)`, `double_click(x, y)`, `move(x, y)`, `drag(path)`, `scroll(x, y, scroll_y)`, `type`, `keypress` |
| **Windows** | `list_windows(app)`, `focus_window(window)`, `move_window(window, x, y)`, `resize_window(window, width, height)` |
| **Screenshots** | `screenshot(window \| region \| display)` — use *after* AX |
| **Clipboard** | `clipboard(action="get" \| "set" \| "clear")` |
| **Scripting** | `run(command, type="shell" \| "applescript" \| "javascript")` — shell requires explicit opt-in; fallback only |
| **Wait** | `wait(duration)` |
| **Macros** | `create_macro(actions)`, `execute_macro(macro)`, `list_macros()` |
| **Display** | `get_display()` — display topology and cursor position |

**Selector format**: one `key:value` string — `role:AXButton`,
`text:Save`, `text_contains:submit`. Selectors re-discover an element and
must resolve uniquely.

**Common AX roles**: `AXButton`, `AXTextField`, `AXStaticText`, `AXCheckBox`,
`AXPopUpButton`, `AXMenu`, `AXMenuItem`, `AXTable`, `AXRow`, `AXLink`,
`AXComboBox`, `AXTextArea`, `AXSlider`, `AXRadioButton`, `AXTabGroup`.

## Reference Files

- **[references/window-state-management.md](references/window-state-management.md)**
  — Window enumeration, visibility semantics. Load when debugging window
  issues.

- **[references/workflows-and-tools.md](references/workflows-and-tools.md)**
  — Detailed workflow patterns, element selector reference, and the complete
  29-tool signature reference. Load when you need step-by-step procedures for
  common tasks or exact parameter formats for less-familiar tools.

- **[references/mcp-reliability-recommendations.md](references/mcp-reliability-recommendations.md)**
  — Empirically derived reliability notes for the server's input and
  discovery behavior. Load when investigating click/input reliability issues.
