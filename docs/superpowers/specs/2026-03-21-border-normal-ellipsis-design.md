# zephwm Visual Brush-Up: border normal + ellipsis

## Problem

1. `border normal` command is accepted but renders identically to `border pixel` — no title bar
2. Title text in tabbed/stacked headers is truncated without ellipsis indicator
3. `border normal <width>` argument is not parsed

## Scope

- Implement `border normal` title bar rendering (i3-compatible)
- Add ellipsis (`...`) for truncated title text
- Parse `border normal <width>` argument
- Extend Expose and PropertyNotify handlers for `border normal`
- Verify all changes via Docker screenshot tests

Out of scope: stacked header limit, floating window clamping, bindcode.

## Design

### 1. `border normal` Title Bar

#### Visual Spec

```
┌─[ window title... ]───────────┐   ← title bar height = tab_bar_height
│                                │      (font_ascent + font_descent + 4)
│        window content          │
│                                │   ← border width from border_width_override
└────────────────────────────────┘      or config default
```

- Title bar background: focused = `0x285577`, unfocused = `0x333333`
- Title bar text: white (`0xffffff`), left-aligned with 4px padding
- Title bar height: same as tabbed/stacked headers (`tab_bar_height`)
- Border drawn by X11 on all 4 sides of the frame (same as `border pixel`)
- Title bar background does NOT extend under X11 border pixels — it fills only the content area

#### When `border normal` Title Bar Appears

- Only on windows with `border_style == .normal`
- NOT inside tabbed/stacked containers with >1 children (those use the parent's tab headers)
- Applies to both tiling and floating windows

#### Layout Space Reservation (layout.zig)

Unlike the original design, `border normal` title bar space MUST be reserved in layout.zig to prevent overflow. Without this, the frame would grow upward by `tab_bar_height` pixels, potentially clipping into the bar or above the screen.

**Strategy**: In layout.zig, after computing child rects, if a child has `border_style == .normal` and is NOT inside tabbed/stacked with >1 children, shrink the child's `window_rect` by `tab_bar_height`:
- `window_rect.y += tab_bar_height`
- `window_rect.h -= tab_bar_height`

This way the title bar lives WITHIN the allocated layout space, not overflowing above it.

Note: layout.zig currently does not read `border_style`. We pass it through as part of the existing recursive layout application. The `border` parameter is already passed but unused for this purpose — we need access to the child container's `border_style` field, which is available since layout works directly on `Container` pointers.

Important: the monocle/single-child code path in layout.zig (line 47: `child.window_rect = child.rect`) also needs the `border normal` space reservation. Apply the same `tab_bar_height` adjustment there.

#### title_offset Logic (render.zig applyWindow)

```
title_offset = 0
if (parent is tabbed/stacked with >1 visible tiling children) {
    title_offset = (tabbed) ? tab_bar_height : tab_bar_height * visible_count
} else if (con.border_style == .normal) {
    title_offset = tab_bar_height
}
```

The two cases are mutually exclusive: tabbed/stacked containers manage their own headers, so individual `border normal` title bars are suppressed.

With layout space reservation, `frame_y = r.y - title_offset` keeps the title bar within the space already allocated by layout.zig (since `r.y` has been moved down by `tab_bar_height`).

#### New Function: drawNormalTitleBar

```
drawNormalTitleBar(conn, frame_id, content_w, title, is_focused) {
    // 1. Fill rectangle: (0, 0, content_w, tab_bar_height) with bg color
    // 2. Draw title text at (4, font_ascent + 2) with ellipsis if needed
}
```

#### Flush-Then-Draw Strategy

`drawNormalTitleBar` follows the same pattern as tabbed/stacked title bars: drawing must happen AFTER the frame has been configured and flushed.

**Concrete approach**: Collect `border normal` windows during the `applyRecursive` pass into a local buffer scoped to each `applyRecursive` call (same pattern as the existing `floating_buf`/`fullscreen_buf`). After tiling children are processed and before floating/fullscreen rendering:

Buffer entry type: `*tree.Container` pointer (same as floating_buf). The `drawNormalTitleBar` function recomputes `content_w` from the container's rect and border at draw time, so no pre-computed values need to be stored.

```
// In applyRecursive, after tiling children are processed:
_ = xcb.flush(conn);           // existing flush for tabbed/stacked
drawTitleBars(conn, con);      // existing tabbed/stacked

// NEW: draw border normal title bars
for (normal_border_buf[0..normal_border_count]) |child| {
    drawNormalTitleBar(conn, child.frame_id, child.content_w, child.title, child.is_focused);
}

// Then floating, then fullscreen (existing)
```

This ensures all frames are configured and flushed before any title bar drawing occurs.

#### Expose Handler Extension

In `handleExpose` (event.zig), extend the handler to redraw `border normal` title bars:

```
// Existing: redraw tabbed/stacked parent's title bars
if (parent.layout == .tabbed or .stacked) { redrawTitleBarsForContainer(...) }

// NEW: redraw border normal title bar on the window itself
if (con.border_style == .normal and not inside tabbed/stacked >1 children) {
    drawNormalTitleBar(conn, frame_id, ...)
}
```

#### PropertyNotify (Title Change) Handler Extension

`redrawTitleBarsForContainer` currently early-returns for non-tabbed/stacked layouts. When a window's title changes and it has `border_style == .normal`:

```
// In PropertyNotify handler, after updating wd.title:
if (con.border_style == .normal) {
    drawNormalTitleBar(conn, frame_id, ...)
    xcb.flush(conn)
}
// Existing: parent tabbed/stacked redraw
```

### 2. Text Ellipsis

Applied to all title text rendering: `drawTitleBars()` (tabbed/stacked) and `drawNormalTitleBar()`.

#### Logic

```
max_chars = (available_width - 8) / font_char_width
if (title.len > max_chars AND max_chars >= 4) {
    display = title[0..max_chars-3] + "..."
} else if (title.len > max_chars) {
    display = title[0..max_chars]       // too narrow for ellipsis
} else {
    display = title                      // fits
}
```

Uses a 256-byte stack buffer for the truncated+ellipsis string. No heap allocation. Note: `xcb_image_text_8` takes a `u8` length field (max 255 chars) — the existing `@min(max_chars, 255)` cap applies.

Note: byte-level truncation may split multi-byte UTF-8 characters. This is acceptable since `xcb_image_text_8` only handles Latin-1 encoding anyway.

### 3. `border normal <width>` Parsing

In `executeBorder()` (event.zig), add width argument parsing for `normal` — same pattern as `pixel`:

```zig
} else if (std.mem.eql(u8, arg, "normal")) {
    focused.border_style = .normal;
    if (cmd.args[1]) |width_str| {
        if (std.fmt.parseInt(i16, width_str, 10)) |w| {
            focused.border_width_override = w;
        } else |_| {}
    }
}
```

Known limitation: `border toggle` does not reset `border_width_override` when cycling styles. This is pre-existing behavior (affects `border pixel` too) and out of scope for this change.

### 4. Implementation Order

1. Parse `border normal <width>` in event.zig
2. Reserve layout space for `border normal` in layout.zig
3. Add title_offset for `border normal` in render.zig applyWindow
4. Implement `drawNormalTitleBar()` in render.zig with deferred flush-then-draw
5. Extend Expose handler for `border normal` redraw
6. Extend PropertyNotify handler for `border normal` title changes
7. Add ellipsis logic to drawTitleBars + drawNormalTitleBar
8. Docker screenshot verification for each step

### 5. Docker Test Cases

| Test | What to verify | Pixel check |
|------|---------------|-------------|
| border normal single window | Title bar visible at top | y=4 should be 0x285577 |
| border normal hsplit 2 windows | Both have title bars | Left and right title bars present |
| border normal → pixel → none → toggle | Style cycles correctly | Title bar appears/disappears |
| border normal with long title | Ellipsis visible | Text ends with "..." |
| tabbed inside: border normal suppressed | No double title bar | Only tab headers, no per-window bar |
| border normal 4 | Thick border + title bar | Border pixels visible at edges |
| floating + border normal | Title bar on floating window | Title bar present above float content |
| title change with border normal | Title bar updates | New title text appears after xdotool set_window --name |
| monocle (single window) + border normal | Title bar within screen bounds | Title bar does not overflow above workspace |

## Files Modified

- `src/render.zig` — drawNormalTitleBar(), title_offset for border normal, deferred draw buffer, ellipsis
- `src/layout.zig` — reserve space for border normal title bar
- `src/event.zig` — border normal width parsing, Expose handler, PropertyNotify handler
- `test_in_docker.sh` — new test cases
