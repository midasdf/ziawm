# zephwm Visual Brush-Up: border normal + ellipsis

## Problem

1. `border normal` command is accepted but renders identically to `border pixel` — no title bar
2. Title text in tabbed/stacked headers is truncated without ellipsis indicator
3. `border normal <width>` argument is not parsed

## Scope

- Implement `border normal` title bar rendering (i3-compatible)
- Add ellipsis (`...`) for truncated title text
- Parse `border normal <width>` argument
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

#### When `border normal` Title Bar Appears

- Only on windows with `border_style == .normal`
- NOT inside tabbed/stacked containers with >1 children (those use the parent's tab headers)
- Applies to both tiling and floating windows

#### title_offset Logic (render.zig applyWindow)

Current logic calculates title_offset only for tabbed/stacked parent containers. Add a new case:

```
title_offset = 0
if (parent is tabbed/stacked with >1 visible tiling children) {
    title_offset = (tabbed) ? tab_bar_height : tab_bar_height * visible_count
} else if (con.border_style == .normal) {
    title_offset = tab_bar_height
}
```

The two cases are mutually exclusive: tabbed/stacked containers manage their own headers, so individual `border normal` title bars are suppressed.

#### New Function: drawNormalTitleBar

```
drawNormalTitleBar(conn, frame_id, content_w, title, is_focused) {
    // 1. Fill rectangle: (0, 0, content_w, tab_bar_height) with bg color
    // 2. Draw title text at (4, font_ascent + 2) with ellipsis if needed
}
```

Called from `applyWindow()` after frame configure, only when:
- `border_style == .normal`
- Not inside tabbed/stacked parent with >1 children
- `title_gc` is initialized

Drawing must happen AFTER `xcb_flush()` to avoid X11 clear-on-resize race (same pattern as existing `drawTitleBars`).

### 2. Text Ellipsis

Applied to all title text rendering: `drawTitleBars()` (tabbed/stacked) and `drawNormalTitleBar()`.

#### Logic

```
max_chars = (available_width - 8) / font_char_width
if (title.len > max_chars AND max_chars >= 4) {
    display = title[0..max_chars-3] + "..."
else if (title.len > max_chars) {
    display = title[0..max_chars]       // too narrow for ellipsis
} else {
    display = title                      // fits
}
```

Uses a 256-byte stack buffer for the truncated+ellipsis string. No heap allocation.

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

### 4. Implementation Order

1. Parse `border normal <width>` in event.zig
2. Add title_offset for `border normal` in render.zig applyWindow
3. Implement `drawNormalTitleBar()` in render.zig
4. Add ellipsis logic to drawTitleBars + drawNormalTitleBar
5. Docker screenshot verification for each step

### 5. Docker Test Cases

| Test | What to verify | Pixel check |
|------|---------------|-------------|
| border normal single window | Title bar visible at top | y=4 should be 0x285577 |
| border normal hsplit 2 windows | Both have title bars | Left and right title bars present |
| border normal → pixel → none → toggle | Style cycles correctly | Title bar appears/disappears |
| border normal with long title | Ellipsis visible | Text ends with "..." |
| tabbed inside: border normal suppressed | No double title bar | Only tab headers, no per-window bar |
| border normal 4 | Thick border + title bar | Border pixels visible at edges |

## Files Modified

- `src/render.zig` — drawNormalTitleBar(), title_offset for border normal, ellipsis
- `src/event.zig` — border normal width parsing
- `test_in_docker.sh` — new test cases
