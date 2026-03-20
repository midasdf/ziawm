# zephwm Visual Quality Improvements — Design Spec

## Overview

Three interconnected improvements to zephwm's visual layer, implemented in dependency order:

1. **Font detection with fallback** — robust XCB core font loading with metrics
2. **Frame windows (reparenting WM)** — stable title bars via X11 frame windows
3. **Per-output bar** — one bar window per monitor, single process

Target hardware: HackberryPi Zero (RPi Zero 2W, 512MB RAM). No new dependencies.

## 1. Font Detection & Metrics

### Problem

Title bar rendering hardcodes `"fixed"` font with no error handling. No font metrics means no text width calculation — titles overflow tab boundaries. If `"fixed"` doesn't exist, title bars silently break.

### Design

**Fallback list** (tried in order via `xcb_open_font` + `xcb_request_check`):

```
"fixed"
"-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1"
"-misc-fixed-medium-r-normal--14-130-75-75-c-70-iso10646-1"
"cursor"
```

`"cursor"` is guaranteed to exist on any X server.

**Metrics acquisition** via `xcb_query_font`:

- `font_ascent` — pixels above baseline
- `font_descent` — pixels below baseline
- `max_bounds.character_width` — max character width (sufficient for fixed-width fonts)

**Derived values** (stored as module-level state in render.zig):

- `tab_bar_height = font_ascent + font_descent + 4` (replaces hardcoded 16px)
- Text y-position: `y + font_ascent + 2` (replaces hardcoded `y + 12`)
- Text truncation: `visible_chars = tab_width / char_width`, truncate title bytes accordingly

**Files changed:**

| File | Change |
|------|--------|
| render.zig | `ensureTitleGc`: fallback loop, metrics query, module vars |
| render.zig | `drawTitleBars`: use metrics for positioning and truncation |
| layout.zig | `applyTabbed`/`applyStacked`: use dynamic `tab_bar_height` instead of hardcoded 16 |

### Notes

- All fonts in the fallback list are XCB core fonts (not Xft/TrueType)
- `xcb_query_text_extents` available for per-string width if needed, but `max_bounds.character_width` is sufficient for fixed-width fonts
- Font is loaded once at first use (lazy init pattern preserved)

## 2. Frame Windows (Reparenting)

### Problem

Title bars for tabbed/stacked layouts are drawn directly on the root window. Any window that overlaps (floating, fullscreen, or the client windows themselves) overwrites the title bar. There is no Expose-based redraw because root window Expose events are not practical to handle for this purpose.

### Design

Every managed window gets a **frame window** — an X11 window created by the WM that becomes the parent of the client window.

#### Window Hierarchy

```
Before:                          After:
  root                             root
  ├── client A                     ├── frame A (border_width=N)
  ├── client B                     │   └── client A
  └── client C                     ├── frame B
                                   │   └── client B
                                   └── frame C
                                       └── client C
```

#### Frame Window Properties

- `border_width`: from config (default 2px)
- `border_pixel`: focus color (changes on focus/unfocus)
- `override_redirect`: false (WM manages it)
- Event mask: `SubstructureRedirect | SubstructureNotify | ExposureMask | EnterWindow`
- Background pixel: title bar background color (for tabbed/stacked)

#### Data Model Changes

**tree.zig — WindowData struct:**

Add `frame_id: u32` field. This is the X11 window ID of the frame.

**Window lookup (main.zig HashMap):**

Both `client_id` and `frame_id` map to the same `*Container` in the existing `window_map`. X11 IDs are globally unique so no collision is possible.

#### Lifecycle

**MapRequest (event.zig):**

1. Read client window attributes and properties (class, title, type)
2. Create frame window: `xcb_create_window(depth=copy_from_parent, x, y, w, h, border_width, ...)`
3. Set frame event mask
4. `xcb_reparent_window(client, frame, 0, 0)` — client at (0,0) within frame
5. `pending_unmap += 1` — reparent generates a synthetic UnmapNotify
6. `xcb_map_window(frame)`, `xcb_map_window(client)`
7. Create Container with `frame_id` set
8. Insert into tree, focus, relayout

**Render (render.zig):**

```
# For each visible window container:
xcb_configure_window(frame, x, y, w, h)        # position frame
xcb_configure_window(client, 0, y_offset, inner_w, inner_h)  # client inside frame
xcb_change_window_attributes(frame, border_pixel, color)      # border color
```

Where:
- `y_offset = 0` for hsplit/vsplit (no title bar)
- `y_offset = tab_bar_height` for focused child in tabbed layout
- `y_offset = tab_bar_height * num_siblings` for focused child in stacked layout
- `inner_w = frame_w` (border handled by X11)
- `inner_h = frame_h - y_offset`

Map/unmap operates on the **frame**, not the client. Client stays mapped inside its frame.

**Tabbed/Stacked Title Bars:**

Drawn on the **focused child's frame window**, in the area above the client:

```
frame window (total height = tab_bar_height + client_height)
┌───────────────────────────┐
│ [Tab A] [Tab B*] [Tab C]  │  ← drawn via xcb_poly_fill_rectangle + xcb_image_text_8
├───────────────────────────┤
│                           │
│      client window B      │  ← positioned at y=tab_bar_height
│                           │
└───────────────────────────┘
```

For stacked layout, same idea but each sibling gets its own row:

```
frame window
┌───────────────────────────┐
│ Stack item A              │
│ Stack item B*  (focused)  │
│ Stack item C              │
├───────────────────────────┤
│      client window B      │
└───────────────────────────┘
```

**Expose Event (new handler in event.zig):**

When a frame receives an Expose event, look up the Container and redraw its title bar region. This guarantees title bars survive overlapping windows, workspace switches, etc.

**UnmapNotify (event.zig):**

Current logic: check `pending_unmap` counter, `mapped` state, and `ev.event == ev.window`.

With frames: `ev.event` will be the frame ID (since client is child of frame). Adjust the check:
- `ev.event == container.window.frame_id` AND `ev.window == container.window.id`
- Decrement `pending_unmap` if > 0, skip handling
- Otherwise: client requested unmap → destroy frame, remove container

**DestroyNotify (event.zig):**

Client destroyed → `xcb_destroy_window(frame)`, remove both IDs from window_map.

**WM Shutdown / Restart (main.zig):**

ICCCM requires reparenting clients back to root before WM exits:

```zig
for (all_containers) |con| {
    if (con.window) |w| {
        xcb_reparent_window(w.id, root_window, con.rect.x, con.rect.y);
    }
}
```

For restart (re-exec): same unreparent, then exec. New instance will re-reparent on MapRequest or by scanning existing windows.

**Focus:**

`xcb_set_input_focus` always targets the **client window**, never the frame. Frame is purely decorative + structural.

#### Files Changed

| File | Change | Scale |
|------|--------|-------|
| tree.zig | `frame_id` field in WindowData | Small |
| event.zig | MapRequest: create frame + reparent. UnmapNotify/DestroyNotify: frame cleanup. New Expose handler | Large |
| render.zig | Configure frame + client separately. Title bar drawn on frame. Expose-triggered redraw | Large |
| layout.zig | tabbed/stacked account for title bar in frame height | Small |
| main.zig | Shutdown/restart: unreparent all clients. window_map stores frame_id too | Medium |
| xcb.zig | Add wrappers: `reparent_window`, `create_window` if missing | Small |

### Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| UnmapNotify double-fire on reparent | Increment `pending_unmap` before `xcb_reparent_window` |
| Focus goes to frame instead of client | Always `set_input_focus(client_id)`, never frame |
| Stale frame after client crash | DestroyNotify handler destroys frame unconditionally |
| Restart loses window positions | Unreparent with current geometry before exec |
| Existing integration tests break | Tests use window IDs; frame IDs are new, tests should still work since client windows are still managed |

## 3. Per-Output Bar

### Problem

zephwm-bar creates a single window on the primary output. Multi-monitor setups show the bar only on one screen.

### Design

zephwm-bar remains a single process but creates one X window per output.

#### IPC Extension

**New: `GET_OUTPUTS` message type** (or extend existing IPC):

Response:
```json
{
  "outputs": [
    {"name": "HDMI-1", "active": true, "x": 0, "y": 0, "width": 1920, "height": 1080},
    {"name": "DP-1", "active": true, "x": 1920, "y": 0, "width": 2560, "height": 1440}
  ]
}
```

**Extended workspace event** — add `output` field:

```json
{"change": "focus", "current": {"name": "1", "output": "HDMI-1", ...}}
```

#### zephwm-bar Changes

**Startup:**

1. Connect to IPC socket (`I3SOCK` env var)
2. Send `GET_OUTPUTS` → get output list
3. For each active output:
   - Create X window at `(output.x, output.y_bottom_or_top, output.width, bar_height)`
   - Set `_NET_WM_WINDOW_TYPE_DOCK`
   - Set `_NET_WM_STRUT_PARTIAL` scoped to that output's x-range
4. Spawn `status_command` (one process)
5. Subscribe to workspace + output IPC events

**Rendering per bar window:**

- Left side: workspace buttons filtered to `workspace.output == this_bar.output_name`
- Right side: status text (shared across all bars from single status_command)
- Center: (unused, same as current)

**Output hot-plug:**

On IPC output event:
- Compare new output list with current bar windows
- Create windows for new outputs
- Destroy windows for removed outputs
- Resize windows for changed outputs

**Data structure:**

```
BarWindow {
    output_name: []const u8,
    window_id: u32,
    x: i16,
    width: u16,
    pixmap: u32,        // double-buffer (existing pattern)
    workspaces: []Workspace,  // filtered to this output
}

bars: ArrayList(BarWindow)   // one per active output
```

**status_command handling:**

- Single child process, stdout parsed once
- Parsed status blocks stored in shared state
- Each bar window renders from that shared state

#### Files Changed

| File | Change | Scale |
|------|--------|-------|
| ipc.zig | `GET_OUTPUTS` handler, output field in workspace events | Medium |
| output.zig | Export output list for IPC consumption | Small |
| src/bar.zig (WM side) | No change (bar spawning stays the same) | None |
| zephwm-bar (separate binary) | Multi-window, IPC GET_OUTPUTS, output event handling | Large |

## Implementation Order

### Phase A: Font Detection & Metrics
1. Font fallback loop in `ensureTitleGc`
2. `xcb_query_font` metrics acquisition
3. Dynamic `tab_bar_height` in layout.zig
4. Text truncation in title bar rendering
5. Unit tests for fallback logic

### Phase B: Frame Windows
1. Add `frame_id` to WindowData, extend window_map
2. Frame creation + reparent in MapRequest
3. Render: configure frame + client separately
4. Border color on frame
5. Title bar drawing on frame (tabbed/stacked)
6. Expose event handler for title redraw
7. UnmapNotify / DestroyNotify frame cleanup
8. Shutdown / restart unreparent
9. Update existing integration tests
10. New integration tests for reparent behavior

### Phase C: Per-Output Bar
1. `GET_OUTPUTS` IPC message in zephwm
2. Output field in workspace IPC events
3. zephwm-bar: multi-window creation from output list
4. Per-output workspace button filtering
5. Shared status_command rendering
6. Output hot-plug handling
7. Integration tests with virtual multi-monitor (xrandr --setmonitor)

## Testing Strategy

| Area | Method |
|------|--------|
| Font fallback | Unit test: mock xcb_open_font failure, verify fallback progression |
| Font metrics | Unit test: verify tab_bar_height calculation from known metrics |
| Frame create/destroy | Integration test (Xephyr): map window, verify frame exists as parent |
| Reparent on unmap | Integration test: unmap client, verify frame destroyed |
| Title bar redraw | Integration test: switch to tabbed, verify Expose triggers redraw |
| Restart unreparent | Integration test: simulate restart, verify clients reparented to root |
| Per-output bar | Integration test: xrandr --setmonitor creates 2 virtual outputs, verify 2 bar windows |
| Bar workspace filter | Integration test: workspace on output A only shown in bar A |

## Non-Goals

- Xft / TrueType font support (future consideration)
- `border normal` with title bar in border (future, easy to add with frame windows in place)
- Embedded bar in WM process (stays as external process)
- Client-side decorations (CSD) negotiation
