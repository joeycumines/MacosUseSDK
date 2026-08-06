# Workflows and Tools Reference

Detailed workflow patterns, element selectors, and tool signatures for the
macos-use MCP server. Load this file when you need step-by-step procedures
or exact parameter formats.

---

## Workflows

### Understand the Current Screen State

Starting point whenever you need to know what's on screen.

1. `list_apps(kind="running")` to see what is running, or `list_apps()` to
   discover installed bundles.
2. `find_elements(parent, selector)` for specific targets (by role, text,
   etc.) — a selector is required.
3. `screenshot()` only if AX didn't show what you needed (canvas, custom
   rendering, web view visual content).

### Interact with an Application

1. **Discover** — `list_apps()` returns exact `applicationBundles/*`
   resources for installed apps and `applications/*` for running processes.
2. **Open** — `open_app(bundle)` with the exact bundle resource. Returns a
   process resource name like `applications/{id}`.
3. **Find** — `find_elements(parent, selector)` with `role:`, `text:`, or
   `text_contains:` criteria. Prefer role and text over position.
4. **Interact** — `click_element`, `type_element`, `type`, or `keypress`.
5. **Verify** — `find_elements` again to confirm. Use `screenshot` only for
   visual rendering, not text content.

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

### Automate a Repetitive Sequence

1. `create_macro(display_name, actions=[...])` with a list of macro actions
   (physical inputs, waits, assignments, conditionals).
2. `execute_macro(macro="macros/{id}")` — runs the macro as one owned
   transaction.
3. `list_macros()`, `get_macro(macro)`, `update_macro(macro, ...)`, and
   `delete_macro(macro)` manage the registry.

### Diagnose a Tauri/Electron App

1. Inspect the AX tree to understand the error state shown on screen.
2. Open devtools: `keypress(target, keys=["meta", "option", "i"])`.
3. Read console output via `find_elements` on the devtools panel.
4. Check the Network tab by clicking it (use `click_element` with a
   `text:Network` selector if the first click doesn't register on tab
   buttons).
5. If there's a "Copy details" or "Show details" button on the error screen,
   click it and read the clipboard via `clipboard(action="get")` — this
   often gives structured error data.
6. **Console input is unreliable.** If you need to evaluate JavaScript, try
   `type_element` with `input_method="keystrokes"` on the console prompt
   followed by Return, but expect focus issues. Shell tools may be more
   reliable for probing local APIs.
7. Stay focused on runtime state. Don't dig into source code unless the user
   asks.

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
`AXTextArea`, `AXSlider`, `AXRadioButton`, `AXTabGroup`, `AXWebArea`.

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

For "wait until an element appears", poll: call `find_elements` in a loop
with `wait` between attempts, or use a macro with condition actions.

### Macros

```
create_macro(display_name, description, actions, tags, macro_id) → macros/{id}
get_macro(macro)                    — macro: exact macros/{id} resource
list_macros(page_size, page_token)
update_macro(macro, display_name, description, actions, tags)
delete_macro(macro, force=false) — `force=true` is currently rejected as unimplemented
execute_macro(macro, application, timeout)
  application: required when the macro contains physical input actions; omit
  only for macros containing no physical actions
```

Macro actions are an ordered list; each action is a physical input
(click/type/keypress/scroll/drag/move with an exact target), a `wait`, an
`assign`, a `conditional`, a `loop`, or a `method_call`. Physical macro
inputs require exact application targets.

### Display

```
get_display()    — display topology (ID, frame, visible frame, main flag, scale)
                  and the current cursor position
```
