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

**Implementation:** ~20 lines in `handleKeyPress`. Build JSON in a stack buffer using `fixedBufferStream`, then call `broadcastIpcEvent(ctx, .binding, payload)`.

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

1. Walk old workspace's children
2. For each child where `is_floating && is_sticky`:
   - `unlink()` from old workspace
   - `appendChild()` to new workspace
3. Proceed with normal workspace switch

This "follow the focus" approach is simpler than i3's virtual presence on all workspaces, with identical user-visible behavior.

**Rendering:** No changes needed. Sticky windows are physically moved to the active workspace, so they render through the normal floating path.

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
    full_text: [128]u8 = undefined,
    full_text_len: u8 = 0,
    render_x: u16 = 0,
    render_width: u16 = 0,
};

const MAX_STATUS_BLOCKS = 32;
```

#### Spawn Changes

`spawnStatusCommand` creates two pipes:
- stdout pipe (existing): bar reads status updates
- stdin pipe (new): bar writes click events

Parent holds `stdin_write_fd`. After spawn, write the i3bar click protocol header to stdin:

```text
[
```

Subsequent click events are comma-prefixed JSON lines.

#### Status Parsing

Extend `readStatusLine` to parse i3bar JSON arrays into `StatusBlock` array:

- Input: `[{"full_text":"CPU 45%","name":"cpu"},{"full_text":"MEM 2.1G","name":"mem"}]`
- Extract per-block: `full_text`, `name`, `instance`
- Plain text input: single block with `name=""`, `instance=""`

#### Rendering

`drawBar` renders status blocks right-to-left (rightmost block at far right). For each block:
1. Measure text width via `XftTextExtentsUtf8`
2. Draw text at computed position
3. Record `render_x` and `render_width` on the block

#### Click Event Dispatch

When a click lands in the status area (x > last workspace button):
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
