# i3 Feature Additions Batch 2 — Design Spec

## Overview

Four independent i3-compatible features:

1. **move workspace to output** — relocate current workspace to another monitor
2. **border normal/none/pixel** — per-window border style and width
3. **IPC output event** — broadcast on monitor hot-plug
4. **urgent workspace** — propagate window urgency to workspace level

## 1. Move Workspace to Output

### Problem

No way to move a workspace between monitors. Users expect `move workspace to output left/right/up/down/NAME`.

### Design

**Command (command.zig):**

Add `move_workspace_to_output` to CommandType. Parse `move workspace to output {left|right|up|down|NAME}`.

**Execution (event.zig):**

`executeMoveWorkspaceToOutput(ctx, cmd)`:

1. Get focused workspace via `getFocusedWorkspace()`
2. Get current output (workspace's parent)
3. Resolve target output:
   - `left/right/up/down` → `output.findAdjacent(current_out, direction)`
   - Named → `output.findByName(tree_root, name)`
4. If target == current, return
5. `ws.unlink()` from current output
6. `target_out.appendChild(ws)` to new output
7. `ws.rect = target_out.rect` — update geometry
8. If target output has no focused workspace, focus this one
9. `relayoutAndRender(ctx)`
10. Broadcast workspace event

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| command.zig | `move_workspace_to_output` type + parse | Small |
| event.zig | `executeMoveWorkspaceToOutput` handler | Small |

## 2. Border Normal/None/Pixel

### Problem

No per-window border control. Users expect `border none`, `border pixel N`, `border toggle`.

### Design

**Data model (tree.zig):**

Add to Container:

```zig
border_style: BorderStyle = .pixel,
border_width_override: i16 = -1, // -1 = use config default
```

```zig
pub const BorderStyle = enum { pixel, none, normal };
```

`normal` renders identically to `pixel` for now (future: title bar in border). `-1` override means "use config default `border_px`".

**Command (command.zig):**

Add `border` to CommandType. Parse:
- `border none` → args = `{"none"}`
- `border pixel` → args = `{"pixel"}`
- `border pixel 3` → args = `{"pixel", "3"}`
- `border normal` → args = `{"normal"}`
- `border toggle` → args = `{"toggle"}`

**Execution (event.zig):**

`executeBorder(ctx, cmd)`:
- `none`: set `border_style = .none`
- `pixel`: set `border_style = .pixel`, optionally set `border_width_override` from arg
- `normal`: set `border_style = .normal`
- `toggle`: cycle `none → pixel → normal → none`
- Call `relayoutAndRender(ctx)`

**Rendering (render.zig):**

In `applyWindow`, when configuring the frame:
- Compute effective border width: if `border_style == .none` → 0, else if `border_width_override >= 0` → that value, else config default
- Add `CONFIG_WINDOW_BORDER_WIDTH` to the configure mask and values

In frame creation (event.zig MapRequest): use config default. Per-window border is applied later via `applyWindow`.

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| tree.zig | `BorderStyle` enum, `border_style`, `border_width_override` on Container | Small |
| command.zig | `border` type + parse | Small |
| event.zig | `executeBorder` handler | Small |
| render.zig | effective border width in `applyWindow` frame configure | Small |

## 3. IPC Output Event

### Problem

External tools (bars, scripts) cannot react to monitor connect/disconnect. The IPC infrastructure supports `.output` events but never broadcasts them.

### Design

In `handleRandrScreenChange` (event.zig), after `output.updateOutputs()` succeeds, broadcast:

```zig
broadcastIpcEvent(ctx, .output, "{\"change\":\"unspecified\"}");
```

i3's output event uses `"change":"unspecified"` — clients query `GET_OUTPUTS` for details.

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| event.zig | One line in `handleRandrScreenChange` | Tiny |

## 4. Urgent Workspace

### Problem

Window urgency (WM_HINTS UrgencyHint) is detected per-window but not propagated to the workspace level. The bar already renders urgent workspaces differently but never receives urgency state.

### Design

**Data model (tree.zig):**

Add `urgent: bool = false` to `WorkspaceData`.

**Urgency propagation (event.zig):**

In `handlePropertyNotify`, after updating `wd.urgency` from WM_HINTS (line ~1264):

1. Find the container's workspace ancestor (walk up `parent` until `.workspace` type)
2. If `wd.urgency == true` and workspace is not currently focused → set `wsd.urgent = true`
3. If urgency changed, broadcast workspace event

**Focus clears urgency (event.zig):**

In `executeWorkspace`, after focusing `target_ws`:
- Set `target_ws.workspace.?.urgent = false`
- Walk `target_ws` children, clear `wd.urgency = false` for all windows

**IPC (main.zig):**

`buildWorkspacesJson` already emits `"urgent":` field. Currently hardcoded to check window urgency. Change to read `wsd.urgent` instead for accurate workspace-level urgency.

**Bar:** No changes needed — already reads `ws_urgent` and renders with `URGENT_BG` color.

**Files changed:**

| File | Change | Scale |
|------|--------|-------|
| tree.zig | `urgent: bool = false` on WorkspaceData | Small |
| event.zig | urgency propagation in PropertyNotify + clear on workspace focus | Medium |
| main.zig | `buildWorkspacesJson` reads `wsd.urgent` | Small |

## Implementation Order

1. **IPC output event** — one line, instant
2. **urgent workspace** — small, self-contained
3. **move workspace to output** — medium, uses existing output infrastructure
4. **border** — medium, touches render path

## Testing Strategy

| Feature | Method |
|---------|--------|
| move workspace to output | Unit test: parse command. Integration: Xephyr multi-monitor, move ws, verify output change |
| border | Unit test: parse command, test border style cycling. Integration: set border none, verify no border |
| IPC output event | Integration: subscribe to output events, trigger xrandr change |
| urgent workspace | Unit test: verify urgency propagation in tree. Integration: set urgency hint, verify bar highlights workspace |

## Non-Goals

- `border normal` with title bar (renders same as `pixel` for now)
- Per-output urgent highlight animation
- `_NET_WM_STATE_DEMANDS_ATTENTION` handling (only WM_HINTS UrgencyHint)
