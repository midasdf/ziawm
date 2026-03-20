# i3 Feature Additions — Design Spec

## Overview

Three independent i3-compatible features added to zephwm:

1. **IPC binding event** — broadcast when a keybind triggers
2. **Sticky floating** — floating windows that follow workspace switches
3. **i3bar click protocol** — send click events to status_command stdin with per-block tracking

## 1. IPC Binding Event

### Problem

External bars (polybar, i3blocks) and tools subscribe to binding events to react to keybind triggers. zephwm has the infrastructure (`EventType.binding`, `IPC_EVENT_BINDING`, `broadcastIpcEvent`) but never broadcasts the event.

### Design

In `handleKeyPress` (event.zig), after a keybind matches but before executing the command, broadcast a binding event.

**JSON format (i3-compatible):**

```json
{"change":"run","binding":{"command":"focus left","event_state_mask":["Mod4"],"input_type":"keyboard","symbol":"Left"}}
```

**Modifier mapping:** Convert the X11 `ev.state` bitmask to an i3-compatible string array:

| X11 mask | i3 string |
|----------|-----------|
| `MOD_MASK_4` | `"Mod4"` |
| `MOD_MASK_SHIFT` | `"shift"` |
| `MOD_MASK_CONTROL` | `"ctrl"` |
| `MOD_MASK_1` | `"Mod1"` |

**Implementation:** ~20 lines in `handleKeyPress`. Build JSON in a stack buffer using `fixedBufferStream`, then call `broadcastIpcEvent(ctx, .binding, payload)`. This fires for all matching bindings including mode-specific bindings (resize mode, etc.) since `handleKeyPress` already filters by `ctx.current_mode`.

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| event.zig | JSON construction + broadcast call in handleKeyPress | Small |

## 2. Sticky Floating

### Problem

Floating windows disappear when switching workspaces. Users expect a `sticky` command to make certain floating windows persist across workspace switches.

### Design

**Data model — tree.zig:**

Add `is_sticky: bool = false` to `Container` struct.

**Command — command.zig:**

Add `sticky` to `CommandType` enum. Parse `sticky enable`, `sticky disable`, `sticky toggle`.

**Execution — event.zig:**

`executeSticky(ctx, cmd)`: Set `con.is_sticky` on the focused container. Only applies when `con.is_floating` is true — tiling windows cannot be sticky.

**Workspace switch behavior — event.zig:**

In `executeWorkspace`, after determining the target workspace, before clearing focus on the old workspace:

1. Walk old workspace's children (collect sticky windows first to avoid mutation during walk)
2. For each child where `is_floating && is_sticky`:
   - `unlink()` from old workspace
   - `appendChild()` to new workspace
3. Proceed with normal workspace switch

This migration must happen in **both** code paths within `executeWorkspace`:
- The normal workspace switch path
- The `back_and_forth` path (which returns early — sticky migration must run before the early return)

This "follow the focus" approach is simpler than i3's virtual presence on all workspaces, with identical user-visible behavior. Sticky windows always follow the focused workspace, including round-trips (A→B→A) and cross-output switches.

**Multi-output coordinate adjustment:** When a sticky window follows focus to a workspace on a different output, its floating position (x, y) may be off-screen. After moving, clamp the window's `rect.x` and `rect.y` to the target workspace's output bounds.

**Rendering:** No changes needed beyond coordinate adjustment. Sticky windows are physically moved to the active workspace, so they render through the normal floating path.

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| tree.zig | `is_sticky: bool = false` field on Container | Small |
| command.zig | `sticky` CommandType, parse `sticky enable/disable/toggle` | Small |
| event.zig | `executeSticky` handler + sticky migration in `executeWorkspace` | Medium |

## 3. i3bar Click Protocol

### Problem

Status commands (i3status, i3blocks, custom scripts) cannot receive click events from the bar. The i3bar protocol specifies bidirectional communication: stdout for status updates, stdin for click events.

### Design

#### Status Block Tracking

Current implementation treats status text as a single string. For click protocol, each JSON block needs individual position tracking.

**StatusBlock struct (zephwm-bar/main.zig):**

```zig
const StatusBlock = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    instance: [64]u8 = undefined,
    instance_len: u8 = 0,
    full_text: [256]u8 = undefined,
    full_text_len: u8 = 0,
    render_x: u16 = 0,
    render_width: u16 = 0,
};

const MAX_STATUS_BLOCKS = 32;
```

#### Protocol Detection

The i3bar JSON protocol is detected from the status_command's first output line. If it contains `"click_events":true`, click event dispatch is enabled. Otherwise (plain text mode), clicks in the status area are silently ignored and no stdin pipe is used.

A module-level `click_events_enabled: bool = false` flag tracks this state.

#### Spawn Changes

`spawnStatusCommand` creates two pipes:
- stdout pipe (existing): bar reads status updates
- stdin pipe (new): bar writes click events

Parent holds `stdin_write_fd`. The stdin pipe is always created, but click events are only written when `click_events_enabled` is true (detected from stdout header).

When `click_events_enabled` is detected, write the i3bar click protocol header to stdin:

```text
[
```

Subsequent click events are comma-prefixed JSON lines.

#### Status Parsing

Rewrite `readStatusLine` to parse i3bar JSON arrays into `StatusBlock` array:

- Detect protocol header: first non-empty line containing `{"version":1` sets JSON mode
- JSON mode input: `[{"full_text":"CPU 45%","name":"cpu"},{"full_text":"MEM 2.1G","name":"mem"}]`
  - Extract per-block: `full_text`, `name`, `instance`
  - Set `click_events_enabled = true` if `"click_events":true` was in the header
- Plain text input: single block with `name=""`, `instance=""`, `click_events_enabled` stays false

#### Rendering

`drawBar` renders status blocks right-to-left (rightmost block at far right). For each block:
1. Measure text width via `XftTextExtentsUtf8`
2. Draw text at computed position
3. Record `render_x` and `render_width` on the block

#### Click Event Dispatch

When a click lands in the status area (x > last workspace button) and `click_events_enabled` is true:
1. Walk `status_blocks`, find block where `render_x <= click_x < render_x + render_width`
2. Build click event JSON:

```json
,{"name":"cpu","instance":"","button":1,"x":1850,"y":10,"relative_x":30,"relative_y":10,"width":60,"height":20}
```

3. Write to `stdin_write_fd`

**Fields:**
- `name`, `instance`: from the matched StatusBlock
- `button`: X11 button number (1=left, 2=middle, 3=right)
- `x`, `y`: absolute click coordinates
- `relative_x`, `relative_y`: click position relative to block
- `width`, `height`: block dimensions (`render_width`, `BAR_HEIGHT`)

#### Files Changed

| File | Change | Scale |
|------|--------|-------|
| zephwm-bar/main.zig | StatusBlock struct, stdin pipe, block parsing, per-block rendering, click dispatch | Large |

## Implementation Order

1. **IPC binding event** — smallest, no dependencies
2. **Sticky floating** — medium, independent of bar
3. **i3bar click protocol** — largest, independent of WM core

## Testing Strategy

| Feature | Method |
|---------|--------|
| Binding event | Unit test: verify JSON format. Integration: subscribe to binding events via zephwm-msg, trigger keybind, verify event received |
| Sticky floating | Unit test: verify sticky window moves between workspaces in tree. Integration: set sticky, switch workspace, verify window still visible |
| Click protocol | Integration: run i3blocks with clickable block, click in bar, verify i3blocks receives click event on stdin |

## Non-Goals

- Mouse button bindings — keyboard only for binding events
- Sticky tiling windows — only floating windows can be sticky
- Block separator rendering — blocks drawn without visual separators
- Block background colors — only `full_text` rendering, no per-block color/markup
