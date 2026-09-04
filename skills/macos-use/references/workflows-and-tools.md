# Workflows and Tools Reference

Detailed workflow patterns, element selectors, and tool signatures for the
macos-use MCP server. Load this file when you need step-by-step procedures
or exact parameter formats.

---

## Workflows

### Execute High-Efficiency Transactions

To avoid conversational friction and round-trip token waste, chain discovery,
actions, and verification without redundant pauses:

1. **Do not screenshot before clicking an AX element:** If `find_elements` returned
   the target element and text, immediately call `click_element` or click its center.
2. **Act immediately on dynamic handles:** In web apps and dynamic views, element
   handles (`elem_<ts>_<id>`) become stale quickly. Invoke the interaction in the
   same logical transaction.
3. **Chain multi-step flows:** For form filling or multi-page navigation, sequence
   inputs, waits, and confirmations into consecutive calls without conversational
   stop-and-ask interruptions.

### Automate Web Browsers (Chrome / Safari / Firefox)

1. **Launch / Focus Browser:**
   - Check running status with `list_apps(kind="running")`. If not running, call
     `open_app(bundle)` with the bundle from `list_apps(kind="installed")`.
   - Call `list_windows(app)` to obtain the browser window resource.
   - **Chrome Profile Picker Detection:** If Chrome opens a profile selection
     window, query `find_elements(parent=window, selector="role:AXButton")` to find
     `Open Person 1 profile` (or target profile) and click it.
2. **Navigate to URL:**
   - Bring window to front: `focus_window(window)`.
   - Focus the address bar via `click_element(parent=window, selector="role:AXTextField")`
     or coordinate click on the URL bar center.
   - Enter URL via physical keystrokes: `type(target=window, text="https://...")`
     followed by `keypress(target=window, keys=["enter"])`.
   - Wait for page to settle: `wait(duration=2..4)`.
3. **Feed Browsing & Interaction:**
   - Query page elements: `find_elements(parent=window, selector="role:AXHeading")`
     or `role:AXLink` to discover content.
   - Click articles or links via `click_element(parent=window, element=handle)`.
   - Scroll through dynamic feeds: `scroll(target=window, x=center_x, y=center_y, scroll_y=500)`
     followed by `wait(1.0)` and `find_elements(force_refresh=true)`.

### Visual Grounding Fallback (JetBrains IDEs & Non-AX Apps)

When an application's runtime disables the Accessibility API (such as GoLand,
IntelliJ, PyCharm throwing `AX error -25202` or `kAXErrorAPIDisabled -25211`):

1. **Acquire Visual State:**
   - Bring window to front: `focus_window(window)`.
   - Capture window: `screenshot(window=window, format="png")`.
2. **Compute Global Coordinates:**
   - Identify the local pixel coordinate `(local_x, local_y)` in the image.
   - Compute global coordinate using the window's top-left origin:
     $$\text{target\_x} = \text{window.x} + \text{local\_x}$$
     $$\text{target\_y} = \text{window.y} + \text{local\_y}$$
3. **Dispatch Physical Inputs:**
   - Double-click to open files in project trees: `double_click(target=window, x=target_x, y=target_y)`.
   - Click to focus editors or buttons: `click(target=window, x=target_x, y=target_y)`.
   - Type code or search queries: `type(target=window, text="...")`.
   - Trigger shortcuts: `keypress(target=window, keys=["meta", "s"])`.
4. **Verify:**
   - Capture a follow-up `screenshot(window=window)` to confirm visual changes.

### Understand the Current Screen State

1. `list_apps(kind="running")` to see what is running, or `list_apps()` to
   discover installed bundles.
2. `get_display()` to inspect screen topology, scale factors, and cursor position.
3. `find_elements(parent, selector)` for specific targets (by role, text,
   etc.) — a selector is required.
4. `screenshot()` only if AX didn't show what you needed (canvas, custom
   rendering, web view visual content).

### Find and Click a Button

1. `find_elements(parent, selector="role:AXButton")` — returns elements with
   parent-bound handles.
2. `click_element(parent, element="<handle>")` — clicks the center and
   acquires focus.
3. If the click fails, follow the Click Escalation path (see SKILL.md).

### Type into a Text Field

1. `find_elements(parent, selector="role:AXTextField")` to locate the field.
2. `type_element(parent, element="<handle>", text="hello")` — direct AX
   value mutation; more reliable than keystrokes.
3. For web/Electron fields that need DOM keyboard events:
   `type_element(parent, element="<handle>", text="hello",
   input_method="keystrokes")`.
4. For fields that must receive physical keystrokes: `type(target, text)` on
   the exact window resource, or `keypress` for shortcuts.

### Read Information from an App

1. `open_app` if not already tracked.
2. `find_elements` to get the element tree. Results provide the element ID,
   text, and role. Use `read_element(parent, element)` for bounds,
   enabled/focused state, and actions.
3. Extract text from AX elements — do not screenshot to read text.
4. After interaction, data may be stale. Use `read_element` on the specific
   handle or `find_elements` with `force_refresh=true` for a fresh read.

### Automate a Repetitive Sequence (Macros)

1. `create_macro(display_name, actions=[...])` with a list of macro actions
   (physical inputs, waits, assignments, conditionals).
2. `execute_macro(macro="macros/{id}")` — runs the macro as one owned
   transaction.
3. `list_macros()`, `get_macro(macro)`, `update_macro(macro, ...)`, and
   `delete_macro(macro)` manage the registry.

---

## Element Selectors

`find_elements` and the element mutation tools accept one `key:value`
selector string:

| Selector | Example | Description |
|----------|---------|-------------|
| `role` | `role:AXButton` | Match by AX role |
| `text` | `text:Submit` | Exact text match (case-sensitive) |
| `text_contains` | `text_contains:save` | Substring match (case-sensitive) |

A selector used for mutation (`click_element`, `type_element`) must resolve
to exactly one element; the server rejects ambiguous selectors. When
discovery and mutation happen in sequence, prefer the parent-bound element
handle returned by `find_elements` over re-issuing a selector.

### Common AX Roles

`AXButton`, `AXTextField`, `AXStaticText`, `AXCheckBox`, `AXPopUpButton`,
`AXMenu`, `AXMenuItem`, `AXTable`, `AXRow`, `AXLink`, `AXComboBox`,
`AXTextArea`, `AXSlider`, `AXRadioButton`, `AXTabGroup`, `AXWebArea`, `AXHeading`.

---

## Tool Signatures

Pointer input tools (`click`, `double_click`, `move`, `scroll`, and `drag`) take
an exact `target` of `desktop`, an application/window resource, or
`displays/{display}`. Keyboard tools (`type` and `keypress`) accept only
`desktop` or an application/window resource. Resource names are opaque —
obtain them from `list_apps`, `list_windows`, and `get_display`.

### App Lifecycle

```
open_app(app, bring_to_front=true, mode="launch_or_activate")
  app: exact applicationBundles/* resource (from list_apps) or applications/* process
list_apps(kind="installed"|"running", filter, order_by, page_size, page_token, full)
  kind=installed discovers bundles; kind=running lists exact processes
close_app(app, force=false)
  app: exact applications/* process resource
```

### Finding Elements

```
find_elements(parent, selector, force_refresh=false, page_size, page_token)
  parent: "applications/{id}" or "applications/{id}/windows/{id}"
  selector: "role:AXButton" | "text:Save" | "text_contains:save" (required)
read_element(parent, element)
  parent: application/window used during discovery when element is a bare handle
  element: parent-bound handle or full element resource name
```

### Element Interaction

```
click_element(parent, element)          — click by exact find_elements handle (preferred)
click_element(parent, selector)         — re-discover by unique selector, then click
type_element(parent, element|selector, text, input_method="ax"|"keystrokes")
   — set element value; the current MCP JSON handler cannot distinguish omitted
     text from an explicit empty string, so both clear the value
read_element(parent, element)            — role, text, bounds, value, actions, focused/enabled
```

### Keyboard & Mouse (physical input)

```
type(target, text, char_delay)          — type text as keyboard input
keypress(target, keys)                  — key combo; CUA names: ctrl, alt, meta, shift,
                                           enter, esc, backspace, arrowup, arrowdown, ...
click(target, x, y, button, click_count, keys)      — coordinate click (last resort)
double_click(target, x, y, button, keys)
move(target, x, y, duration, keys)
scroll(target, x, y, scroll_x, scroll_y, duration, keys)
drag(target, path, button, duration, keys)          — ordered waypoints, min 2 points
```

All coordinates are Global Display Coordinates (top-left origin, Y increases
downward) — the same system window bounds use.

### Windows

```
list_windows(app, filter, order_by, page_size, page_token)
focus_window(window)                     — bring to front
move_window(window, x, y)                — Global Display Coordinates
resize_window(window, width, height)
```

### Screenshots

```
screenshot(display|window|region, format="png"|"jpeg"|"tiff", quality, ocr, include_shadow)
  display: "displays/{id}" from get_display
  window:  exact applications/{id}/windows/{id} resource
  region:  x, y, width, height in logical display points
```

### Clipboard

```
clipboard(action="get"|"set"|"clear", text)   — text required for set
```

### Scripting (Fallback Only)

```
run(command, timeout, type="shell"|"applescript"|"javascript")
```

### Waiting

```
wait(duration)    — pause for the given duration in seconds (max MACOS_USE_REQUEST_TIMEOUT; default 1)
```

### Macros

```
create_macro(display_name, description, actions, tags, macro_id) → macros/{id}
get_macro(macro)                    — macro: exact macros/{id} resource
list_macros(page_size, page_token)
update_macro(macro, display_name, description, actions, tags)
delete_macro(macro, force=false)
execute_macro(macro, application, timeout)
  application: required when the macro contains physical input actions
```

### Display

```
get_display()    — display topology (ID, frame, visible frame, main flag, scale)
                  and the current cursor position
```
