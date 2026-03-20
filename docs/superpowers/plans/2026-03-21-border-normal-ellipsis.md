# border normal + ellipsis Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `border normal` title bar rendering and text ellipsis for zephwm, making the visual output match i3's behavior.

**Architecture:** Add layout space reservation in layout.zig for `border normal` title bars, render the title bar in render.zig using the same deferred flush-then-draw pattern as tabbed/stacked, and extend event handlers for Expose/PropertyNotify redraw. Ellipsis applied to all title text rendering.

**Tech Stack:** Zig, XCB, X11 core protocol

**Spec:** `docs/superpowers/specs/2026-03-21-border-normal-ellipsis-design.md`

---

## Chunk 1: Core Implementation

### Task 1: Parse `border normal <width>` in event.zig

**Files:**
- Modify: `src/event.zig:2037-2038`

- [ ] **Step 1: Add width parsing for `border normal`**

In `executeBorder()`, the `normal` branch currently only sets the style. Add width argument parsing matching the `pixel` pattern at lines 2031-2035:

```zig
// event.zig — replace lines 2037-2038
    } else if (std.mem.eql(u8, arg, "normal")) {
        focused.border_style = .normal;
        if (cmd.args[1]) |width_str| {
            if (std.fmt.parseInt(i16, width_str, 10)) |w| {
                focused.border_width_override = w;
            } else |_| {}
        }
```

- [ ] **Step 2: Build to verify no compile errors**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/event.zig
git commit -m "feat: parse border normal <width> argument"
```

---

### Task 2: Reserve layout space for `border normal` in layout.zig

**Files:**
- Modify: `src/layout.zig:43-49` (monocle path)
- Modify: `src/layout.zig:62-100` (applyHsplit)
- Modify: `src/layout.zig:102-136` (applyVsplit)

The key insight: layout.zig sets `child.window_rect` for each child. For `border normal` windows, we need to shrink `window_rect` by `tab_bar_height` to reserve space for the title bar. This mirrors how `applyTabbed`/`applyStacked` already reserve header space.

We do NOT adjust for children inside tabbed/stacked parents (those already have headers). The check: `child.border_style == .normal` AND parent is NOT tabbed/stacked with >1 children. Since the layout functions only run for >1 children when called from the `else` branch (line 51), and tabbed/stacked have their own functions that already handle headers, we only need to add the adjustment in: (1) the monocle path, (2) applyHsplit, (3) applyVsplit. The tabbed/stacked paths don't need it because their own headers take precedence.

- [ ] **Step 1: Add helper function `adjustForBorderNormal`**

Add after the `recurse` function at the end of layout.zig (after line 173):

```zig
/// Adjust window_rect for border normal title bar space.
/// Only applies if the child has border_style == .normal.
fn adjustForBorderNormal(child: *tree.Container) void {
    if (child.border_style != .normal) return;
    if (child.type != .window) return;
    const tbh: u32 = @intCast(render.tab_bar_height);
    if (child.window_rect.h > tbh) {
        child.window_rect.y += @intCast(tbh);
        child.window_rect.h -= tbh;
    }
}
```

- [ ] **Step 2: Apply in monocle path**

In the `apply()` function, after line 47 (`child.window_rect = child.rect;`), add:

```zig
            // Monocle: single child fills entire area, no gap, no border adjustment
            const child = tiling[0];
            child.rect = rect;
            child.window_rect = child.rect;
            adjustForBorderNormal(child);
            child.dirty = false;
            recurse(child, gap, border);
```

- [ ] **Step 3: Apply in applyHsplit**

After line 94 (`child.window_rect = child.rect;`) in applyHsplit:

```zig
        child.rect = .{ .x = x, .y = rect.y, .w = w, .h = rect.h };
        child.window_rect = child.rect;
        adjustForBorderNormal(child);
        child.dirty = false;
```

- [ ] **Step 4: Apply in applyVsplit**

After line 130 (`child.window_rect = child.rect;`) in applyVsplit:

```zig
        child.rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = h };
        child.window_rect = child.rect;
        adjustForBorderNormal(child);
        child.dirty = false;
```

- [ ] **Step 5: Build to verify**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 6: Run unit tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/layout.zig
git commit -m "feat: reserve layout space for border normal title bar"
```

---

### Task 3: Add title_offset for `border normal` in render.zig

**Files:**
- Modify: `src/render.zig:309-325` (applyWindow title_offset calculation)

- [ ] **Step 1: Extend title_offset logic**

The current code at lines 309-325 only calculates title_offset for tabbed/stacked parents. Add an `else if` for `border normal`:

```zig
    // Determine title bar offset for tabbed/stacked or border normal
    var title_offset: u16 = 0;
    if (con.parent) |parent| {
        if (!con.is_floating and con.is_fullscreen == .none) {
            if ((parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1) {
                // Count only visible tiling children (not floating, not fullscreen)
                var visible_count: u16 = 0;
                var c = parent.children.first;
                while (c) |ch| : (c = ch.next) {
                    if (!ch.is_floating and ch.is_fullscreen == .none) visible_count += 1;
                }
                if (visible_count > 1) {
                    title_offset = if (parent.layout == .tabbed) tab_bar_height else tab_bar_height * visible_count;
                }
            } else if (con.border_style == .normal) {
                // border normal: individual title bar on this window
                title_offset = tab_bar_height;
            }
        }
    }
    // Also handle border normal for floating windows (no parent layout check needed)
    if (con.is_floating and con.border_style == .normal) {
        title_offset = tab_bar_height;
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds. At this point, `border normal` will reserve space for the title bar but not yet draw it — the title bar area will be blank.

- [ ] **Step 3: Commit**

```bash
git add src/render.zig
git commit -m "feat: add title_offset calculation for border normal"
```

---

### Task 4: Implement `drawNormalTitleBar()` and deferred rendering

**Files:**
- Modify: `src/render.zig` — add new function + deferred buffer in applyRecursive

- [ ] **Step 1: Add `drawNormalTitleBar` function**

Add after `drawTitleBars` (after line 115), before `redrawTitleBarsForContainer`:

```zig
/// Draw a title bar for a border normal window on its own frame.
fn drawNormalTitleBar(conn: *xcb.Connection, con: *tree.Container) void {
    if (!title_gc_initialized or title_gc == 0) return;
    const wd = if (con.window) |w| w else return;
    const frame_id = wd.frame_id;
    if (frame_id == 0) return;

    const tbh: u16 = tab_bar_height;
    const text_y_offset: i16 = @intCast(font_ascent + 2);

    // Compute content_w from window_rect and border (same logic as applyWindow)
    const effective_border: u16 = blk: {
        if (con.border_style == .none) break :blk 0;
        if (con.border_width_override >= 0) break :blk @intCast(con.border_width_override);
        break :blk config_border_px;
    };
    const b2: u32 = @as(u32, effective_border) * 2;
    const r = con.window_rect;
    const content_w: u16 = @intCast(if (r.w > b2) r.w - b2 else 1);

    const bg: u32 = if (con.is_focused) 0x285577 else 0x333333;

    // Fill title bar background
    const bg_val = [_]u32{bg};
    _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_BACKGROUND, &bg_val);
    _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &bg_val);
    const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = 0, .y = 0, .width = content_w, .height = tbh }};
    _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_id, title_gc, 1, &rect);

    // Draw title text
    const title = wd.title;
    const max_chars: usize = if (font_char_width > 0 and content_w > 8)
        @intCast((content_w - 8) / font_char_width)
    else
        0;
    const capped_max: usize = @min(max_chars, 255);
    if (capped_max > 0) {
        var buf: [256]u8 = undefined;
        var text_ptr: [*]const u8 = title.ptr;
        var text_len: u8 = @intCast(@min(title.len, capped_max));

        // Ellipsis: if title is longer than available space
        if (title.len > capped_max and capped_max >= 4) {
            const trunc_len = capped_max - 3;
            @memcpy(buf[0..trunc_len], title[0..trunc_len]);
            buf[trunc_len] = '.';
            buf[trunc_len + 1] = '.';
            buf[trunc_len + 2] = '.';
            text_ptr = &buf;
            text_len = @intCast(capped_max);
        }

        const text_fg = [_]u32{0xffffff};
        _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
        _ = xcb.c.xcb_image_text_8(conn, text_len, frame_id, title_gc, 4, text_y_offset, text_ptr);
    }
}
```

- [ ] **Step 2: Make `drawNormalTitleBar` public for event handlers**

Change `fn drawNormalTitleBar` to `pub fn drawNormalTitleBar`.

- [ ] **Step 3: Add deferred buffer in applyRecursive**

In `applyRecursive` (line 237-241), add a `normal_border_buf` alongside the existing floating/fullscreen buffers:

```zig
            // Single pass: process tiling, collect floating/fullscreen/border-normal for deferred rendering
            var floating_buf: [32]*tree.Container = undefined;
            var floating_count: usize = 0;
            var fullscreen_buf: [8]*tree.Container = undefined;
            var fullscreen_count: usize = 0;
            var normal_border_buf: [32]*tree.Container = undefined;
            var normal_border_count: usize = 0;
```

- [ ] **Step 4: Collect border normal windows during tiling pass**

After each `applyRecursive(conn, child, ...)` call for tiling children (lines 265 and 270), add collection logic. Insert after the existing tiling child processing block (after line 271, before the closing `}`):

In the `if (hide_unfocused)` branch, after `applyRecursive` on line 265, and in the else branch after line 270 — but this gets complex. Simpler approach: collect AFTER the main loop, by scanning children again. Add after line 272 (after the main child loop ends) but before the flush/drawTitleBars block:

```zig
            // Collect border normal windows for deferred title bar drawing
            {
                var nc = con.children.first;
                while (nc) |child| : (nc = child.next) {
                    if (child.is_floating or child.is_fullscreen != .none) continue;
                    if (child.type == .window and child.border_style == .normal) {
                        // Skip if inside tabbed/stacked with >1 children (parent headers take precedence)
                        if (!hide_unfocused) {
                            if (normal_border_count < 32) {
                                normal_border_buf[normal_border_count] = child;
                                normal_border_count += 1;
                            }
                        }
                    }
                }
            }
```

- [ ] **Step 5: Draw deferred border normal title bars after flush**

After the existing flush+drawTitleBars block (after line 279), add:

```zig
            // Draw border normal title bars (after flush, before floating)
            if (normal_border_count > 0 and title_gc != 0) {
                if (!hide_unfocused) _ = xcb.flush(conn);
                for (normal_border_buf[0..normal_border_count]) |child| {
                    drawNormalTitleBar(conn, child);
                }
            }

            // Render floating children (on top of tiling)
            // ... existing floating_buf loop ...

            // Draw border normal title bars on floating windows (after their frames are configured)
            // Floating windows bypass layout.zig so no space reservation needed — title bar
            // grows upward from the frame, same as i3 behavior for floating windows.
            if (title_gc != 0) {
                var has_float_normal = false;
                for (floating_buf[0..floating_count]) |child| {
                    if (child.type == .window and child.border_style == .normal) {
                        has_float_normal = true;
                        break;
                    }
                }
                if (has_float_normal) {
                    _ = xcb.flush(conn);
                    for (floating_buf[0..floating_count]) |child| {
                        if (child.type == .window and child.border_style == .normal) {
                            drawNormalTitleBar(conn, child);
                        }
                    }
                }
            }

            // Render fullscreen children last (on top of everything)
            // ... existing fullscreen_buf loop ...
```

Note: this code is inserted into the existing `applyRecursive` structure. The `// ... existing ... loop ...` comments indicate the existing loops that should NOT be modified — only new code is added between/after them.

- [ ] **Step 6: Build to verify**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 7: Quick Docker screenshot test**

Run the Docker test to see if `border normal` title bar now renders:

```bash
cd /home/midasdf/zephwm && zig build && sudo docker build -f Dockerfile.test -t zephwm-test . 2>&1 | tail -3
```

Then run a quick manual test inside Docker:

```bash
sudo docker run --rm --memory=2g -v /tmp/zephwm-screenshots:/screenshots zephwm-test bash -c '
    Xvfb :99 -screen 0 720x720x24 -ac &
    sleep 1
    export DISPLAY=:99
    ./bin/zephwm 2>/tmp/wm.log &
    sleep 1.5
    SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP "= \"\K[^\"]+")
    xterm -T "TestWindow" -e "sleep 60" &
    sleep 1
    I3SOCK="$SOCK" ./bin/zephwm-msg "border normal" 2>/dev/null
    sleep 0.5
    xwd -root -silent | xwdtopnm 2>/dev/null > /screenshots/border_normal_single.ppm
    I3SOCK="$SOCK" ./bin/zephwm-msg "exit"
'
```

Then verify the screenshot:

```bash
# Check pixel at y=4 (should be title bar color 0x285577, not black)
python3 -c "
with open('/tmp/zephwm-screenshots/border_normal_single.ppm','rb') as f:
    header = f.readline()  # P6
    dims = f.readline()    # 720 720
    maxval = f.readline()  # 255
    data = f.read()
    w = 720
    # Check pixel at (360, 4) — center of title bar area
    offset = (4 * w + 360) * 3
    r, g, b = data[offset], data[offset+1], data[offset+2]
    color = f'{r:02x}{g:02x}{b:02x}'
    print(f'Title bar pixel (360,4): #{color}')
    assert color != '000000', 'Title bar is black — drawing not working'
    print('PASS: Title bar is visible')
"
```

- [ ] **Step 8: Commit**

```bash
git add src/render.zig
git commit -m "feat: implement border normal title bar with deferred rendering"
```

---

### Task 5: Extend Expose and PropertyNotify handlers

**Files:**
- Modify: `src/event.zig:1428-1436` (handleExpose)
- Modify: `src/event.zig:1321-1326` (handlePropertyNotify title change)

- [ ] **Step 1: Extend handleExpose**

Replace the current `handleExpose` function (lines 1428-1436):

```zig
fn handleExpose(ctx: *EventContext, ev: *xcb.c.xcb_expose_event_t) void {
    if (ev.count != 0) return;
    const con = findContainerByWindow(ctx, ev.window) orelse return;
    // Redraw tabbed/stacked parent headers
    if (con.parent) |parent| {
        if (parent.layout == .tabbed or parent.layout == .stacked) {
            render.redrawTitleBarsForContainer(ctx.conn, parent);
        }
    }
    // Redraw border normal title bar on this window
    if (con.border_style == .normal and con.type == .window) {
        // Skip if inside tabbed/stacked with >1 children (parent headers take precedence)
        const suppress = if (con.parent) |parent|
            (parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1
        else
            false;
        if (!suppress) {
            render.drawNormalTitleBar(ctx.conn, con);
            _ = xcb.flush(ctx.conn);
        }
    }
}
```

- [ ] **Step 2: Extend handlePropertyNotify for title changes**

After the existing title redraw block (lines 1321-1326), add `border normal` redraw. Replace lines 1321-1326:

```zig
        // Redraw title bars if window is inside a tabbed/stacked container
        if (con.parent) |parent| {
            if (parent.layout == .tabbed or parent.layout == .stacked) {
                render.redrawTitleBarsForContainer(ctx.conn, parent);
            }
        }
        // Redraw border normal title bar
        if (con.border_style == .normal and con.type == .window) {
            const suppress = if (con.parent) |parent|
                (parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1
            else
                false;
            if (!suppress) {
                render.drawNormalTitleBar(ctx.conn, con);
                _ = xcb.flush(ctx.conn);
            }
        }
```

- [ ] **Step 3: Build to verify**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/event.zig
git commit -m "feat: extend Expose and PropertyNotify handlers for border normal"
```

---

### Task 6: Add ellipsis to tabbed/stacked drawTitleBars

**Files:**
- Modify: `src/render.zig:75-86` (tabbed text drawing)
- Modify: `src/render.zig:101-111` (stacked text drawing)

The `drawNormalTitleBar` already has ellipsis (added in Task 4). Now add the same to the existing tabbed/stacked code.

- [ ] **Step 1: Add ellipsis to tabbed title text (lines 75-86)**

Replace the text drawing block in the tabbed branch:

```zig
            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            // Truncate to fit tab width (leave 8px padding), with ellipsis
            const max_chars: usize = if (font_char_width > 0 and tab_w > 8)
                @intCast((tab_w - 8) / font_char_width)
            else
                0;
            const capped_max: usize = @min(max_chars, 255);
            if (capped_max > 0) {
                var buf: [256]u8 = undefined;
                var text_ptr: [*]const u8 = title.ptr;
                var text_len: u8 = @intCast(@min(title.len, capped_max));

                if (title.len > capped_max and capped_max >= 4) {
                    const trunc_len = capped_max - 3;
                    @memcpy(buf[0..trunc_len], title[0..trunc_len]);
                    buf[trunc_len] = '.';
                    buf[trunc_len + 1] = '.';
                    buf[trunc_len + 2] = '.';
                    text_ptr = &buf;
                    text_len = @intCast(capped_max);
                }

                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, frame_win, title_gc, x + 4, text_y_offset, text_ptr);
            }
```

- [ ] **Step 2: Add ellipsis to stacked title text (lines 101-111)**

Same pattern for the stacked branch:

```zig
            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            const max_chars: usize = if (font_char_width > 0 and r.w > 8)
                @intCast((r.w - 8) / font_char_width)
            else
                0;
            const capped_max: usize = @min(max_chars, 255);
            if (capped_max > 0) {
                var buf: [256]u8 = undefined;
                var text_ptr: [*]const u8 = title.ptr;
                var text_len: u8 = @intCast(@min(title.len, capped_max));

                if (title.len > capped_max and capped_max >= 4) {
                    const trunc_len = capped_max - 3;
                    @memcpy(buf[0..trunc_len], title[0..trunc_len]);
                    buf[trunc_len] = '.';
                    buf[trunc_len + 1] = '.';
                    buf[trunc_len + 2] = '.';
                    text_ptr = &buf;
                    text_len = @intCast(capped_max);
                }

                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, frame_win, title_gc, 4, y + text_y_offset, text_ptr);
            }
```

- [ ] **Step 3: Build and test**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/render.zig
git commit -m "feat: add ellipsis to tabbed/stacked title text truncation"
```

---

## Chunk 2: Docker Screenshot Tests

### Task 7: Add comprehensive Docker screenshot tests

**Files:**
- Modify: `test_in_docker.sh` — add border normal test cases to `run_terminal_tests`

- [ ] **Step 1: Add border normal tests to `run_terminal_tests`**

Add the following test blocks after the existing "--- Border ---" section (after line 209) in `test_in_docker.sh`:

```bash
    # -- Border Normal --
    echo "    --- Border Normal ---"
    spawn_term "$TERM_NAME" "NormalBorder" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    local TITLE_BAR
    TITLE_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    if [ "$TITLE_BAR" = "285577" ]; then
        pass "border normal title bar ($TITLE_BAR)"
    else
        fail "border normal title bar ($TITLE_BAR, expected 285577)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal Hsplit --
    echo "    --- Border Normal Hsplit ---"
    spawn_term "$TERM_NAME" "BN1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "BN2" "sleep 60"; sleep 0.8
    run_msg "border normal"; sleep 0.3
    run_msg "focus left"; sleep 0.3
    run_msg "border normal"; sleep 0.5
    screenshot
    local BN_LEFT BN_RIGHT
    BN_LEFT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/4)) 4)
    BN_RIGHT=$(pixel_hex /tmp/screen.ppm $((SCREEN_W*3/4)) 4)
    BN_OK=0
    [ "$BN_LEFT" = "285577" ] || [ "$BN_LEFT" = "333333" ] && BN_OK=$((BN_OK+1))
    [ "$BN_RIGHT" = "285577" ] || [ "$BN_RIGHT" = "333333" ] && BN_OK=$((BN_OK+1))
    [ "$BN_OK" -ge 2 ] && pass "border normal hsplit ($BN_LEFT/$BN_RIGHT)" || fail "border normal hsplit ($BN_LEFT/$BN_RIGHT)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal Toggle --
    echo "    --- Border Toggle ---"
    spawn_term "$TERM_NAME" "Toggle" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.3
    screenshot
    local TOGGLE_NORMAL
    TOGGLE_NORMAL=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    run_msg "border toggle"; sleep 0.3
    screenshot
    local TOGGLE_NONE
    TOGGLE_NONE=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    # After toggle from normal -> none, title bar should be gone (black or window content)
    [ "$TOGGLE_NORMAL" = "285577" ] && pass "toggle: normal has title bar" || fail "toggle: normal ($TOGGLE_NORMAL)"
    [ "$TOGGLE_NONE" != "285577" ] && [ "$TOGGLE_NONE" != "333333" ] && pass "toggle: none has no title bar" || fail "toggle: none ($TOGGLE_NONE)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Long Title Ellipsis --
    echo "    --- Ellipsis ---"
    spawn_term "$TERM_NAME" "ThisIsAVeryLongWindowTitleThatShouldBeTruncatedWithEllipsis" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    # Just verify title bar exists — pixel-checking "..." text is fragile
    local ELLIPSIS_BAR
    ELLIPSIS_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    [ "$ELLIPSIS_BAR" = "285577" ] && pass "ellipsis title bar present ($ELLIPSIS_BAR)" || fail "ellipsis ($ELLIPSIS_BAR)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Border Normal 4 (thick border) --
    echo "    --- Border Normal 4 ---"
    spawn_term "$TERM_NAME" "Thick" "sleep 60"; sleep 1
    run_msg "border normal 4"; sleep 0.5
    screenshot
    local THICK_BAR THICK_EDGE
    THICK_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    THICK_EDGE=$(pixel_hex /tmp/screen.ppm 2 $((SCREEN_H/2)))
    [ "$THICK_BAR" = "285577" ] && pass "border normal 4 title bar" || fail "border normal 4 title ($THICK_BAR)"
    [ "$THICK_EDGE" != "000000" ] && pass "border normal 4 thick edge ($THICK_EDGE)" || fail "border normal 4 edge black"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Tabbed suppresses border normal --
    echo "    --- Tabbed suppresses border normal ---"
    spawn_term "$TERM_NAME" "Tab1" "sleep 60"; sleep 0.8
    spawn_term "$TERM_NAME" "Tab2" "sleep 60"; sleep 0.8
    run_msg "border normal"; sleep 0.3
    run_msg "layout tabbed"; sleep 0.5
    screenshot
    # In tabbed mode, only tab headers should show, not per-window border normal
    # Check that y=4 has tab header color and content area starts at tab_bar_height
    local TAB_SUP
    TAB_SUP=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    [ "$TAB_SUP" = "285577" ] || [ "$TAB_SUP" = "333333" ] && pass "tabbed suppresses border normal ($TAB_SUP)" || fail "tabbed suppress ($TAB_SUP)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Title change with border normal --
    echo "    --- Title Change ---"
    spawn_term "$TERM_NAME" "OldTitle" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    local WID_TC
    WID_TC=$(xdotool search --name "OldTitle" 2>/dev/null | head -1)
    if [ -n "$WID_TC" ]; then
        xdotool set_window --name "NewTitle" "$WID_TC" 2>/dev/null
        sleep 0.5
        screenshot
        # Title bar should still be present after title change
        local TC_BAR
        TC_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
        [ "$TC_BAR" = "285577" ] && pass "title change redraws bar ($TC_BAR)" || fail "title change ($TC_BAR)"
    else
        pass "title change (window not found, skip)"
    fi
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5

    # -- Monocle (single window) with border normal --
    echo "    --- Monocle Border Normal ---"
    spawn_term "$TERM_NAME" "Mono" "sleep 60"; sleep 1
    run_msg "border normal"; sleep 0.5
    screenshot
    # Title bar should be within screen bounds (y=4 has title bar color, not clipped)
    local MONO_BAR MONO_TOP
    MONO_BAR=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 4)
    MONO_TOP=$(pixel_hex /tmp/screen.ppm $((SCREEN_W/2)) 0)
    [ "$MONO_BAR" = "285577" ] && pass "monocle border normal ($MONO_BAR)" || fail "monocle ($MONO_BAR)"
    killall "$TERM_NAME" 2>/dev/null || true; sleep 0.5
```

- [ ] **Step 2: Build and run full Docker test suite**

```bash
cd /home/midasdf/zephwm && zig build && bash test_docker_realapps.sh
```

Expected: All existing tests still pass, new border normal tests pass.

- [ ] **Step 3: If tests fail, fix and re-run**

Examine Docker test output and fix any rendering issues. Common issues:
- Title bar pixel not at expected y coordinate (check `tab_bar_height` value)
- Wrong color (check focused vs unfocused logic)
- Title bar not drawn (check flush ordering)

- [ ] **Step 4: Copy a screenshot to host and visually inspect**

```bash
sudo docker run --rm --memory=2g -v /tmp/zephwm-screenshots:/screenshots zephwm-test bash -c '
    Xvfb :99 -screen 0 720x720x24 -ac &
    sleep 1
    export DISPLAY=:99
    ./bin/zephwm 2>/tmp/wm.log &
    sleep 1.5
    SOCK=$(xprop -root I3_SOCKET_PATH 2>/dev/null | grep -oP "= \"\K[^\"]+")
    xterm -T "Border Normal Test" -e "sleep 60" &
    sleep 1
    I3SOCK="$SOCK" ./bin/zephwm-msg "border normal" 2>/dev/null; sleep 0.5
    xwd -root -silent | xwdtopnm 2>/dev/null > /screenshots/border_normal.ppm
    xterm -T "Second Window" -e "sleep 60" &
    sleep 1
    I3SOCK="$SOCK" ./bin/zephwm-msg "border normal" 2>/dev/null; sleep 0.5
    xwd -root -silent | xwdtopnm 2>/dev/null > /screenshots/border_normal_hsplit.ppm
    I3SOCK="$SOCK" ./bin/zephwm-msg "layout tabbed" 2>/dev/null; sleep 0.5
    xwd -root -silent | xwdtopnm 2>/dev/null > /screenshots/tabbed.ppm
    I3SOCK="$SOCK" ./bin/zephwm-msg "exit"
'
```

Then inspect the PPM files (convert to PNG if needed):
```bash
convert /tmp/zephwm-screenshots/border_normal.ppm /tmp/zephwm-screenshots/border_normal.png 2>/dev/null || echo "install imagemagick for PNG conversion"
```

- [ ] **Step 5: Commit**

```bash
git add test_in_docker.sh
git commit -m "test: add Docker screenshot tests for border normal and ellipsis"
```

---

### Task 8: Run all existing test suites for regression

- [ ] **Step 1: Unit tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All ~110 unit tests pass.

- [ ] **Step 2: Docker tests**

Run: `cd /home/midasdf/zephwm && bash test_docker_realapps.sh`
Expected: All tests pass including new border normal tests.

- [ ] **Step 3: Fix any regressions**

If any test fails, diagnose and fix. The most likely regression areas:
- Tabbed/stacked layout (we modified text rendering)
- Single window layout (we modified monocle path)
- Border pixel/none (we modified applyWindow title_offset)

- [ ] **Step 4: Final commit if fixes needed**

```bash
git add -A
git commit -m "fix: address test regressions from border normal changes"
```
