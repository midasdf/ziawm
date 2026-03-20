# Visual Quality Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add font detection with fallback, reparenting frame windows for stable title bars, and per-output bar rendering.

**Architecture:** Three phases in dependency order. Phase A adds robust font handling used by all rendering. Phase B replaces root-window title bar drawing with frame-window-based rendering via full X11 reparenting. Phase C extends zephwm-bar to create one window per output.

**Tech Stack:** Zig, XCB (libxcb), Xft (zephwm-bar only), X11 core fonts (zephwm WM)

**Spec:** `docs/superpowers/specs/2026-03-20-visual-quality-design.md`

---

## Chunk 1: Font Detection & Metrics (Phase A)

### Task 1: Add font metrics module variables and fallback init

**Files:**
- Modify: `src/render.zig:5-15` (module state + constant)
- Modify: `src/render.zig:75-88` (`ensureTitleGc`)

- [ ] **Step 1: Add font metrics variables to render.zig**

Replace the module-level state block (lines 5-15) with:

```zig
/// Cached GC and font for title bar rendering. Initialized lazily.
var title_gc: u32 = 0;
var title_font: u32 = 0;
var title_gc_initialized: bool = false;
var cached_root_window: xcb.Window = 0;

/// Font metrics, populated by ensureTitleGc
var font_ascent: u16 = 10;
var font_descent: u16 = 2;
var font_char_width: u16 = 6;

/// Dynamically computed from font metrics. Exported for layout.zig.
pub var tab_bar_height: u16 = 16;
```

Remove the old `const TAB_BAR_HEIGHT: u16 = 16;` line.

- [ ] **Step 2: Rewrite ensureTitleGc with fallback loop + metrics**

Replace `ensureTitleGc` (lines 75-88) with:

```zig
fn ensureTitleGc(conn: *xcb.Connection, root_window: xcb.Window) void {
    if (title_gc_initialized) return;
    title_gc_initialized = true;

    // Font fallback list — try each until one succeeds
    const font_names = [_]struct { name: [*]const u8, len: u16 }{
        .{ .name = "fixed", .len = 5 },
        .{ .name = "-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1", .len = 65 },
        .{ .name = "-misc-fixed-medium-r-normal--14-130-75-75-c-70-iso10646-1", .len = 57 },
        .{ .name = "cursor", .len = 6 },
    };

    title_font = xcb.generateId(conn);
    var font_opened = false;
    for (font_names) |f| {
        const cookie = xcb.c.xcb_open_font_checked(conn, title_font, f.len, f.name);
        const err = xcb.c.xcb_request_check(conn, cookie);
        if (err == null) {
            font_opened = true;
            break;
        }
        std.c.free(err);
    }

    if (!font_opened) {
        // All fonts failed — title bars will have no text
        title_gc_initialized = false;
        return;
    }

    // Query font metrics
    const qf_cookie = xcb.c.xcb_query_font(conn, title_font);
    if (xcb.c.xcb_query_font_reply(conn, qf_cookie, null)) |reply| {
        font_ascent = reply.*.font_ascent;
        font_descent = reply.*.font_descent;
        font_char_width = if (reply.*.max_bounds.character_width > 0)
            @intCast(reply.*.max_bounds.character_width)
        else
            6;
        std.c.free(reply);
    }

    tab_bar_height = font_ascent + font_descent + 4;

    title_gc = xcb.generateId(conn);
    const gc_values = [_]u32{ 0xffffff, 0x285577, title_font };
    _ = xcb.c.xcb_create_gc(conn, title_gc, root_window,
        xcb.c.XCB_GC_FOREGROUND | xcb.c.XCB_GC_BACKGROUND | xcb.c.XCB_GC_FONT,
        &gc_values);
}
```

- [ ] **Step 3: Build and verify compilation**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compilation succeeds (or only layout.zig errors about old TAB_BAR_HEIGHT reference)

- [ ] **Step 4: Commit**

```bash
git add src/render.zig
git commit -m "feat: add font fallback detection with metrics in render.zig"
```

### Task 2: Use dynamic tab_bar_height in layout.zig

**Files:**
- Modify: `src/layout.zig:1-6` (imports + constant)
- Modify: `src/layout.zig:138-166` (`applyTabbed` + `applyStacked`)

- [ ] **Step 1: Import render and remove hardcoded constant**

Replace lines 1-6 of layout.zig:

```zig
const std = @import("std");
const log = std.log.scoped(.layout);
const tree = @import("tree.zig");
const render = @import("render.zig");

const MAX_TILING_CHILDREN: usize = 64;
```

- [ ] **Step 2: Update applyTabbed to use render.tab_bar_height**

Replace `applyTabbed` (lines 138-150):

```zig
fn applyTabbed(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const tbh: u32 = @intCast(render.tab_bar_height);
    const content_y: i32 = rect.y + @as(i32, @intCast(tbh));
    const content_h: u32 = if (rect.h > tbh) rect.h - tbh else 0;
    const child_rect: tree.Rect = .{ .x = rect.x, .y = content_y, .w = rect.w, .h = content_h };

    for (children) |child| {
        child.rect = child_rect;
        child.window_rect = shrinkByBorder(child_rect, border);
        child.dirty = false;
        recurse(child, gap, border);
    }
}
```

- [ ] **Step 3: Update applyStacked to use render.tab_bar_height**

Replace `applyStacked` (lines 152-166):

```zig
fn applyStacked(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const n: u32 = @intCast(children.len);
    const tbh: u32 = @intCast(render.tab_bar_height);
    const header_h: u32 = tbh * n;
    const content_y: i32 = rect.y + @as(i32, @intCast(header_h));
    const content_h: u32 = if (rect.h > header_h) rect.h - header_h else 0;
    const child_rect: tree.Rect = .{ .x = rect.x, .y = content_y, .w = rect.w, .h = content_h };

    for (children) |child| {
        child.rect = child_rect;
        child.window_rect = shrinkByBorder(child_rect, border);
        child.dirty = false;
        recurse(child, gap, border);
    }
}
```

- [ ] **Step 4: Build and run tests**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`

Note: layout tests use hardcoded 16px expectations. They should still pass because `tab_bar_height` defaults to 16 until font init runs (which doesn't happen in unit tests — no X connection).

Expected: Build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/layout.zig
git commit -m "feat: use dynamic tab_bar_height from font metrics in layout"
```

### Task 3: Text truncation and metrics-based positioning in drawTitleBars

**Files:**
- Modify: `src/render.zig:19-73` (`drawTitleBars`)

- [ ] **Step 1: Rewrite drawTitleBars with metrics-based positioning and truncation**

Replace `drawTitleBars` (lines 19-73):

```zig
fn drawTitleBars(conn: *xcb.Connection, con: *tree.Container) void {
    const root_win = cached_root_window;
    const r = con.rect;
    const child_count = con.children.len();
    if (child_count == 0) return;

    const text_y_offset: i16 = @intCast(font_ascent + 2);
    const tbh: u16 = tab_bar_height;

    if (con.layout == .tabbed) {
        const tab_w: u16 = @intCast(r.w / @as(u32, @intCast(child_count)));
        var x: i16 = @intCast(r.x);
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            const bg = if (child.is_focused) @as(u32, 0x285577) else @as(u32, 0x333333);
            const bg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_BACKGROUND, &bg_val);
            const fg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &fg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = x, .y = @intCast(r.y), .width = tab_w, .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, root_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            // Truncate to fit tab width (leave 8px padding)
            const max_chars: usize = if (font_char_width > 0 and tab_w > 8)
                @intCast((tab_w - 8) / font_char_width)
            else
                0;
            const text_len: u8 = @intCast(@min(title.len, @min(max_chars, 255)));
            if (text_len > 0) {
                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, root_win, title_gc, x + 4, @as(i16, @intCast(r.y)) + text_y_offset, title.ptr);
            }
            x += @intCast(tab_w);
        }
    } else if (con.layout == .stacked) {
        var y: i16 = @intCast(r.y);
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            const bg = if (child.is_focused) @as(u32, 0x285577) else @as(u32, 0x333333);
            const bg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &bg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = @intCast(r.x), .y = y, .width = @intCast(r.w), .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, root_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            const max_chars: usize = if (font_char_width > 0 and r.w > 8)
                @intCast((r.w - 8) / font_char_width)
            else
                0;
            const text_len: u8 = @intCast(@min(title.len, @min(max_chars, 255)));
            if (text_len > 0) {
                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, root_win, title_gc, @as(i16, @intCast(r.x)) + 4, y + text_y_offset, title.ptr);
            }
            y += @intCast(tbh);
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles successfully.

- [ ] **Step 3: Run all tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All 373+ tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/render.zig
git commit -m "feat: text truncation and metrics-based title bar positioning"
```

---

## Chunk 2: Frame Windows — Data Model & Creation (Phase B, Part 1)

### Task 4: Add frame_id to WindowData

**Files:**
- Modify: `src/tree.zig:16-32` (WindowData struct)

- [ ] **Step 1: Add frame_id field to WindowData**

Add `frame_id: u32 = 0,` after the `id` field in WindowData (line 17):

```zig
pub const WindowData = struct {
    id: u32,
    frame_id: u32 = 0,
    class: []const u8 = "",
    instance: []const u8 = "",
    title: []const u8 = "",
    window_role: []const u8 = "",
    window_type: []const u8 = "",
    transient_for: ?u32 = null,
    urgency: bool = false,
    pending_unmap: u16 = 0,
    mapped: bool = true,
};
```

- [ ] **Step 2: Build and run tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All tests pass (frame_id defaults to 0, no behavioral change).

- [ ] **Step 3: Commit**

```bash
git add src/tree.zig
git commit -m "feat: add frame_id field to WindowData for reparenting support"
```

### Task 5: Frame creation and reparenting in MapRequest

**Files:**
- Modify: `src/event.zig:632-778` (`handleMapRequest`)

- [ ] **Step 1: Add frame creation after container creation in handleMapRequest**

After the container is created and window properties are read (after line 674 `con.is_floating = should_float;`), insert frame creation code. Replace lines 665-677 with:

```zig
    // Create frame window
    const frame_id = xcb.generateId(ctx.conn);
    const border_w: u16 = if (ctx.config) |cfg| @intCast(cfg.border_width) else 2;
    {
        const frame_values = [_]u32{
            xcb.EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                xcb.EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                xcb.EVENT_MASK_EXPOSURE |
                xcb.EVENT_MASK_ENTER_WINDOW,
        };
        _ = xcb.c.xcb_create_window(
            ctx.conn,
            xcb.c.XCB_COPY_FROM_PARENT, // depth
            frame_id,
            ctx.root_window, // parent
            0,
            0,
            1,
            1, // geometry set by render
            border_w,
            xcb.c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            xcb.c.XCB_COPY_FROM_PARENT, // visual
            xcb.c.XCB_CW_EVENT_MASK,
            &frame_values,
        );
    }

    // Reparent client window into frame
    _ = xcb.c.xcb_reparent_window(ctx.conn, window, frame_id, 0, 0);

    con.window = tree.WindowData{
        .id = window,
        .frame_id = frame_id,
        .class = wm_class.class,
        .instance = wm_class.instance,
        .title = title,
        .window_type = win_type,
        .window_role = win_role,
        .transient_for = transient,
        .pending_unmap = 1, // absorb synthetic UnmapNotify from reparent
    };
    con.is_floating = should_float;

    // Register both client and frame in window lookup map
    registerWindow(ctx, window, con);
    registerWindow(ctx, frame_id, con);
```

- [ ] **Step 2: Update the map call to map frame instead of client**

Replace line 753 (`_ = xcb.mapWindow(ctx.conn, window);`) with:

```zig
    // Map frame (client is mapped inside frame)
    _ = xcb.mapWindow(ctx.conn, frame_id);
    _ = xcb.mapWindow(ctx.conn, window);
```

- [ ] **Step 3: Update event subscription to be on the client window (unchanged) and remove border width setting**

The event mask subscription on the client window (lines 729-736) stays the same. The grabButton on the client window (lines 738-750) stays the same — grabs work on the client inside the frame.

- [ ] **Step 4: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`

Check for missing XCB constants. If `EVENT_MASK_SUBSTRUCTURE_REDIRECT` etc. don't exist as xcb.zig exports, use `xcb.c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT` directly.

Expected: Compiles (possibly with warnings about unused).

- [ ] **Step 5: Commit**

```bash
git add src/event.zig
git commit -m "feat: create frame window and reparent client in MapRequest"
```

### Task 6: Frame cleanup in UnmapNotify and DestroyNotify

**Files:**
- Modify: `src/event.zig:780-840` (`handleUnmapNotify`, `handleDestroyNotify`)

- [ ] **Step 1: Update handleUnmapNotify for frame-aware logic**

Replace `handleUnmapNotify` (lines 780-817):

```zig
fn handleUnmapNotify(ctx: *EventContext, ev: *xcb.UnmapNotifyEvent) void {
    // With reparenting: synthetic unmap from xcb_reparent_window has
    // ev.event == root_window, ev.window == client_id.
    // Client-initiated unmap has ev.event == frame_id, ev.window == client_id.
    // The old guard (ev.event == ev.window) filters StructureNotify — keep it.
    if (ev.event == ev.window) return;

    const con = findContainerByWindow(ctx, ev.window) orelse return;

    if (con.window) |*wd| {
        if (wd.pending_unmap > 0) {
            wd.pending_unmap -= 1;
            return;
        }
    }

    // Client-initiated unmap — reparent client back to root, destroy frame
    if (con.window) |wd| {
        _ = xcb.c.xcb_reparent_window(ctx.conn, wd.id, ctx.root_window,
            @intCast(con.rect.x), @intCast(con.rect.y));
        _ = xcb.c.xcb_destroy_window(ctx.conn, wd.frame_id);
        unregisterWindow(ctx, wd.frame_id);
    }

    if (con.is_focused) {
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    unregisterWindow(ctx, ev.window);
    con.unlink();
    con.destroy(ctx.allocator);

    updateAllEwmh(ctx);
    relayoutAndRender(ctx);
    broadcastIpcEvent(ctx, .window, "{\"change\":\"close\"}");
}
```

- [ ] **Step 2: Update handleDestroyNotify for frame cleanup**

Replace `handleDestroyNotify` (lines 819-840):

```zig
fn handleDestroyNotify(ctx: *EventContext, ev: *xcb.DestroyNotifyEvent) void {
    if (ev.event == ev.window) return;

    const con = findContainerByWindow(ctx, ev.window) orelse return;

    // Destroy frame window and unregister frame_id
    if (con.window) |wd| {
        if (wd.frame_id != 0) {
            _ = xcb.c.xcb_destroy_window(ctx.conn, wd.frame_id);
            unregisterWindow(ctx, wd.frame_id);
        }
    }

    if (con.is_focused) {
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    unregisterWindow(ctx, ev.window);
    con.unlink();
    con.destroy(ctx.allocator);

    updateAllEwmh(ctx);
    relayoutAndRender(ctx);
}
```

- [ ] **Step 3: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 4: Commit**

```bash
git add src/event.zig
git commit -m "feat: frame cleanup in UnmapNotify and DestroyNotify"
```

---

## Chunk 3: Frame Windows — Rendering & Expose (Phase B, Part 2)

### Task 7: Render via frame windows

**Files:**
- Modify: `src/render.zig:201-316` (`applyWindow`, `applyFullscreen`, `mapSubtree`, `unmapSubtree`)

- [ ] **Step 1: Rewrite applyWindow to configure frame + client separately**

Replace `applyWindow` (lines 201-235):

```zig
fn applyWindow(
    conn: *xcb.Connection,
    con: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
) void {
    if (con.window == null) return;
    const wd = &con.window.?;
    const frame_id = wd.frame_id;

    if (con.is_fullscreen != .none) return;

    const r = con.rect;

    // Determine title bar offset for tabbed/stacked
    var title_offset: u16 = 0;
    if (con.parent) |parent| {
        if ((parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1) {
            if (parent.layout == .tabbed) {
                title_offset = tab_bar_height;
            } else {
                title_offset = tab_bar_height * @as(u16, @intCast(parent.children.len()));
            }
        }
    }

    // Configure frame: position and size (includes title bar area)
    const frame_h = r.h + @as(u32, title_offset);
    const frame_y = r.y - @as(i32, @intCast(title_offset));
    {
        const values = [_]u32{
            @bitCast(r.x),
            @bitCast(frame_y),
            r.w,
            frame_h,
        };
        const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
        _ = xcb.configureWindow(conn, frame_id, mask, &values);
    }

    // Configure client inside frame
    {
        const values = [_]u32{
            0, // x = 0 inside frame
            @as(u32, title_offset), // y = below title bar
            r.w,
            r.h,
        };
        const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
        _ = xcb.configureWindow(conn, wd.id, mask, &values);
    }

    // Border color on frame
    const color = if (con.is_focused) border_focus_color else border_unfocus_color;
    const border_values = [_]u32{color};
    _ = xcb.changeWindowAttributes(conn, frame_id, xcb.CW_BORDER_PIXEL, &border_values);

    // Map frame
    _ = xcb.mapWindow(conn, frame_id);
    wd.mapped = true;
    wd.pending_unmap = 0;
}
```

- [ ] **Step 2: Update applyFullscreen to use frame_id**

Replace `applyFullscreen` (lines 238-262):

```zig
fn applyFullscreen(conn: *xcb.Connection, con: *tree.Container, parent_con: *tree.Container) void {
    if (con.window == null) return;
    const wd = &con.window.?;
    const frame_id = wd.frame_id;

    const r = parent_con.rect;

    // Configure frame: fill output, no border, raise to top
    const values = [_]u32{
        @bitCast(r.x),
        @bitCast(r.y),
        r.w,
        r.h,
        0, // border_width = 0
        xcb.STACK_MODE_ABOVE,
    };
    const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
        xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT |
        xcb.CONFIG_WINDOW_BORDER_WIDTH | xcb.CONFIG_WINDOW_STACK_MODE;
    _ = xcb.configureWindow(conn, frame_id, mask, &values);

    // Client fills entire frame
    const client_values = [_]u32{ 0, 0, r.w, r.h };
    const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
        xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
    _ = xcb.configureWindow(conn, wd.id, client_mask, &client_values);

    _ = xcb.mapWindow(conn, frame_id);
    wd.mapped = true;
    wd.pending_unmap = 0;
}
```

- [ ] **Step 3: Update mapSubtree and unmapSubtree to use frame_id**

Replace `mapSubtree` (lines 265-278):

```zig
fn mapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |*win_data| {
            _ = xcb.mapWindow(conn, win_data.frame_id);
            win_data.mapped = true;
            win_data.pending_unmap = 0;
        }
        return;
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        mapSubtree(conn, child);
    }
}
```

Replace `unmapSubtree` (lines 301-316):

```zig
pub fn unmapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |*win_data| {
            if (win_data.mapped) {
                _ = xcb.unmapWindow(conn, win_data.frame_id);
                win_data.pending_unmap +|= 1;
                win_data.mapped = false;
            }
        }
        return;
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        unmapSubtree(conn, child);
    }
}
```

- [ ] **Step 4: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 5: Commit**

```bash
git add src/render.zig
git commit -m "feat: render via frame windows — configure frame + client separately"
```

### Task 8: Draw title bars on frame instead of root window

**Files:**
- Modify: `src/render.zig:19-73` (`drawTitleBars`)
- Modify: `src/render.zig:133-199` (`applyRecursive`)

- [ ] **Step 1: Change drawTitleBars to draw on the focused child's frame**

The function currently draws on `cached_root_window`. Change it to find the visible child and draw on its frame.

Replace `drawTitleBars`:

```zig
fn drawTitleBars(conn: *xcb.Connection, con: *tree.Container) void {
    // Find the visible (focused) child — title bars are drawn on its frame
    const visible_child = blk: {
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (!child.is_floating and child.is_focused) break :blk child;
        }
        // Fallback to first tiling child
        cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (!child.is_floating) break :blk child;
        }
        break :blk @as(?*tree.Container, null);
    };

    const target_child = visible_child orelse return;
    const frame_win = if (target_child.window) |wd| wd.frame_id else return;
    if (frame_win == 0) return;

    const child_count = con.children.len();
    if (child_count == 0) return;

    const text_y_offset: i16 = @intCast(font_ascent + 2);
    const tbh: u16 = tab_bar_height;
    const r = con.rect; // Use parent container rect for width

    if (con.layout == .tabbed) {
        const tab_w: u16 = @intCast(r.w / @as(u32, @intCast(child_count)));
        var x: i16 = 0; // relative to frame, not screen
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            const bg = if (child.is_focused) @as(u32, 0x285577) else @as(u32, 0x333333);
            const bg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_BACKGROUND, &bg_val);
            const fg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &fg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = x, .y = 0, .width = tab_w, .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            const max_chars: usize = if (font_char_width > 0 and tab_w > 8)
                @intCast((tab_w - 8) / font_char_width)
            else
                0;
            const text_len: u8 = @intCast(@min(title.len, @min(max_chars, 255)));
            if (text_len > 0) {
                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, frame_win, title_gc, x + 4, text_y_offset, title.ptr);
            }
            x += @intCast(tab_w);
        }
    } else if (con.layout == .stacked) {
        var y: i16 = 0; // relative to frame
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            const bg = if (child.is_focused) @as(u32, 0x285577) else @as(u32, 0x333333);
            const bg_val = [_]u32{bg};
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &bg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = 0, .y = y, .width = @intCast(r.w), .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            const max_chars: usize = if (font_char_width > 0 and r.w > 8)
                @intCast((r.w - 8) / font_char_width)
            else
                0;
            const text_len: u8 = @intCast(@min(title.len, @min(max_chars, 255)));
            if (text_len > 0) {
                const text_fg = [_]u32{0xffffff};
                _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
                _ = xcb.c.xcb_image_text_8(conn, text_len, frame_win, title_gc, 4, y + text_y_offset, title.ptr);
            }
            y += @intCast(tbh);
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
git add src/render.zig
git commit -m "feat: draw title bars on frame window instead of root"
```

### Task 9: Add Expose event handler

**Files:**
- Modify: `src/event.zig` (event dispatch switch + new handler)

- [ ] **Step 1: Find the event dispatch switch and add Expose handler**

In the main event dispatch function (look for `switch (response_type)`), add a case for `xcb.c.XCB_EXPOSE`:

```zig
xcb.c.XCB_EXPOSE => {
    const expose_ev: *xcb.c.xcb_expose_event_t = @ptrCast(@alignCast(ev));
    handleExpose(ctx, expose_ev);
},
```

- [ ] **Step 2: Write handleExpose function**

Add near the other event handlers:

```zig
fn handleExpose(ctx: *EventContext, ev: *xcb.c.xcb_expose_event_t) void {
    // Only redraw on final expose event (count == 0)
    if (ev.count != 0) return;

    // Find container whose frame matches this window
    const con = findContainerByWindow(ctx, ev.window) orelse return;

    // If this container's parent is tabbed/stacked, redraw title bars
    if (con.parent) |parent| {
        if (parent.layout == .tabbed or parent.layout == .stacked) {
            render.redrawTitleBarsForContainer(ctx.conn, parent);
        }
    }
}
```

- [ ] **Step 3: Add redrawTitleBarsForContainer to render.zig**

Add a public function at the end of render.zig:

```zig
/// Redraw title bars for a tabbed/stacked container. Called from Expose handler.
pub fn redrawTitleBarsForContainer(conn: *xcb.Connection, con: *tree.Container) void {
    if (!title_gc_initialized or title_gc == 0) return;
    if (con.layout != .tabbed and con.layout != .stacked) return;
    if (con.children.len() <= 1) return;
    drawTitleBars(conn, con);
    _ = xcb.flush(conn);
}
```

- [ ] **Step 4: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 5: Commit**

```bash
git add src/event.zig src/render.zig
git commit -m "feat: add Expose event handler for frame title bar redraw"
```

### Task 10: Unreparent on shutdown and restart

**Files:**
- Modify: `src/event.zig:1920-1943` (`executeRestart`)
- Modify: `src/main.zig:875-896` (shutdown cleanup)

- [ ] **Step 1: Add unreparentAll helper to event.zig**

Add before `executeRestart`:

```zig
/// Reparent all client windows back to root (ICCCM compliance for WM exit/restart).
pub fn unreparentAll(ctx: *EventContext) void {
    var it = ctx.window_map.iterator();
    while (it.next()) |entry| {
        const con = entry.value_ptr.*;
        if (con.window) |wd| {
            if (wd.frame_id != 0 and wd.id == entry.key_ptr.*) {
                // Only process client ID entries (skip frame_id entries)
                _ = xcb.c.xcb_reparent_window(ctx.conn, wd.id, ctx.root_window,
                    @intCast(con.rect.x), @intCast(con.rect.y));
                _ = xcb.mapWindow(ctx.conn, wd.id);
            }
        }
    }
    _ = xcb.flush(ctx.conn);
}
```

- [ ] **Step 2: Call unreparentAll before execvp in executeRestart**

`executeRestart` is currently a free function with no ctx. It needs to become a method or take ctx. Find where it's called and pass ctx.

Change the signature and add the unreparent call:

```zig
pub fn executeRestart(ctx: *EventContext) void {
    std.debug.print("zephwm: restarting via execvp\n", .{});

    // Unreparent all clients back to root before re-exec
    unreparentAll(ctx);

    _ = setenv("ZEPHWM_RESTART", "1", 1);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.readLinkAbsolute("/proc/self/exe", &exe_buf) catch {
        std.debug.print("zephwm: restart failed: cannot read /proc/self/exe\n", .{});
        return;
    };
    if (exe_path.len >= exe_buf.len) return;
    exe_buf[exe_path.len] = 0;
    const exe_z: [*:0]const u8 = @ptrCast(exe_buf[0..exe_path.len :0]);

    const argv = [_:null]?[*:0]const u8{exe_z};
    _ = execvp(exe_z, &argv);
    std.debug.print("zephwm: restart execvp failed\n", .{});
}
```

Update **both** call sites:
- In `executeCommand` (event.zig): change `executeRestart()` to `executeRestart(ctx)`
- In `main.zig` SIGHUP handler (~line 847): change `event.executeRestart()` to `event.executeRestart(&ctx)`

- [ ] **Step 3: Add unreparent call to main.zig shutdown**

In main.zig shutdown block (around line 875), before the cleanup code, add:

```zig
    // Unreparent all client windows back to root (ICCCM)
    event.unreparentAll(&ctx);
```

- [ ] **Step 4: Build and run tests**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/event.zig src/main.zig
git commit -m "feat: unreparent all clients on shutdown and restart (ICCCM)"
```

### Task 11: Update ConfigureRequest for frame windows

**Files:**
- Modify: `src/event.zig:1010-1067` (`handleConfigureRequest`)

- [ ] **Step 1: Update floating ConfigureRequest to configure frame**

In `handleConfigureRequest`, find the floating window branch (the `else` block around line 1020 that calls `xcb.configureWindow(ctx.conn, ev.window, ...)`). This branch forwards the configure request directly to the client window.

Change it to: (a) configure the **frame** with the requested position/size, and (b) configure the **client** at `(0, 0)` inside the frame.

Replace the existing `xcb.configureWindow(ctx.conn, ev.window, ...)` call in the floating branch with:

```zig
// Configure frame with the requested geometry
if (con) |c| {
    if (c.window) |wd| {
        if (wd.frame_id != 0) {
            _ = xcb.configureWindow(ctx.conn, wd.frame_id, mask, &values);
            // Client fills frame at (0,0)
            const client_values = [_]u32{ 0, 0, @bitCast(ev.width), @bitCast(ev.height) };
            const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
                xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
            _ = xcb.configureWindow(ctx.conn, wd.id, client_mask, &client_values);
        } else {
            _ = xcb.configureWindow(ctx.conn, ev.window, mask, &values);
        }
    }
} else {
    // Unmanaged window — forward directly
    _ = xcb.configureWindow(ctx.conn, ev.window, mask, &values);
}
```

- [ ] **Step 2: Build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
git add src/event.zig
git commit -m "feat: handle ConfigureRequest for frame windows in floating mode"
```

### Task 12: Update floating drag to use frame_id

**Files:**
- Modify: `src/event.zig` (floating drag move/resize handlers)

- [ ] **Step 1: Find drag handlers and update to move frame**

Search for `drag_window` usage. When the WM moves/resizes a floating window during drag, it needs to configure the frame_id instead of the client window directly.

Find `xcb.configureWindow(ctx.conn, wd.id, ...)` calls in drag handlers and change `wd.id` to `wd.frame_id`. Keep client at `(0, 0, w, h)` inside frame.

- [ ] **Step 2: Build and test**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/event.zig
git commit -m "feat: floating drag move/resize operates on frame window"
```

---

## Chunk 4: Frame Windows — Layout Adjustment & Integration Tests (Phase B, Part 3)

### Task 13: Adjust layout shrinkByBorder for frame windows

**Files:**
- Modify: `src/layout.zig:176-186` (`shrinkByBorder`)

- [ ] **Step 1: Remove border shrinking from layout**

With frame windows, X11 borders are on the frame. The client is positioned inside the frame at `(0, y_offset)` — no border shrinking needed in layout.zig. `window_rect` should equal `rect` (the render phase handles client positioning inside frame).

Replace `shrinkByBorder` usage: change all calls to just assign `child.window_rect = child.rect;` OR keep shrinkByBorder but make it a no-op when frames are in use.

Simplest approach — since ALL windows now have frames, just make `window_rect = rect`:

In `applyHsplit` (line 94): change `child.window_rect = shrinkByBorder(child.rect, border);` to `child.window_rect = child.rect;`

Same for `applyVsplit` (line 130), `applyTabbed` (line 146), `applyStacked` (line 162), and the single-child case (line 47).

Delete the `shrinkByBorder` function entirely (Zig errors on unused private functions).

- [ ] **Step 2: Build and run layout tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`

Layout tests will fail — the test `"border reduces window_rect"` (test_layout.zig ~line 188) expects `window_rect` to be shrunk by border. After the change, `window_rect == rect`.

- [ ] **Step 3: Update layout test expectations**

In `tests/test_layout.zig`, find the test `"border reduces window_rect"`. It currently expects:
```zig
try std.testing.expectEqual(@as(i32, 2), child.window_rect.x);
try std.testing.expectEqual(@as(i32, 2), child.window_rect.y);
try std.testing.expectEqual(@as(u32, 716), child.window_rect.w);
try std.testing.expectEqual(@as(u32, 716), child.window_rect.h);
```

Change to expect `window_rect == rect` (border is now on the frame, not subtracted from window_rect):
```zig
try std.testing.expectEqual(@as(i32, 0), child.window_rect.x);
try std.testing.expectEqual(@as(i32, 0), child.window_rect.y);
try std.testing.expectEqual(@as(u32, 720), child.window_rect.w);
try std.testing.expectEqual(@as(u32, 720), child.window_rect.h);
```

Also check for any other tests that call `layout.apply(ws, gap, border)` with `border > 0` and verify their `window_rect` expectations.

- [ ] **Step 4: Run tests again**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/layout.zig tests/test_layout.zig
git commit -m "feat: window_rect equals rect — borders handled by frame window"
```

### Task 14: End-to-end build and smoke test

- [ ] **Step 1: Full build all three binaries**

Run: `cd /home/midasdf/zephwm && zig build 2>&1`
Expected: All three binaries (zephwm, zephwm-msg, zephwm-bar) compile.

- [ ] **Step 2: Run all unit tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1`
Expected: All tests pass.

- [ ] **Step 3: Commit if any fixups needed**

```bash
git add -A
git commit -m "fix: compilation and test fixups for frame window integration"
```

---

## Chunk 5: Per-Output Bar (Phase C)

### Task 15: Add output field to workspace IPC events

**Files:**
- Modify: `src/event.zig` (workspace event broadcasting)

- [ ] **Step 1: Find workspace event broadcasts and add output field**

Search for `broadcastIpcEvent(ctx, .workspace, ...)` calls. They currently send hardcoded JSON like `{"change":"focus"}`.

Add output name by looking up the workspace's parent output:

```zig
fn getWorkspaceOutputName(ws: *tree.Container) []const u8 {
    if (ws.parent) |parent| {
        if (parent.type == .output) {
            // Output containers store their name in workspace.output_name
            if (parent.workspace) |wsd| return wsd.output_name;
        }
    }
    return "default";
}
```

Update workspace event broadcasts to include output:

```zig
var ev_buf: [256]u8 = undefined;
var ev_fbs = std.io.fixedBufferStream(&ev_buf);
const ev_w = ev_fbs.writer();
ev_w.print("{{\"change\":\"focus\",\"current\":{{\"name\":\"{s}\",\"output\":\"{s}\"}}}}", .{
    ws_name, output_name,
}) catch {};
broadcastIpcEvent(ctx, .workspace, ev_fbs.getWritten());
```

- [ ] **Step 2: Build and test IPC**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/event.zig
git commit -m "feat: add output field to workspace IPC events"
```

### Task 16: Multi-window bar — refactor zephwm-bar

**Files:**
- Modify: `zephwm-bar/main.zig`

- [ ] **Step 1: Add BarWindow struct and output discovery**

Add after the constants:

```zig
const BarWindow = struct {
    output_name: [64]u8 = undefined,
    output_name_len: u8 = 0,
    window_id: u32 = 0,
    draw: ?*c.XftDraw = null,
    x: i16 = 0,
    width: u16 = 0,
};

const MAX_OUTPUTS = 8;
```

- [ ] **Step 2: Add output discovery via IPC GET_OUTPUTS**

Add function to query outputs and create bar windows:

```zig
fn discoverOutputs(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    bars: *[MAX_OUTPUTS]BarWindow,
    bar_count: *usize,
    conn: *c.xcb_connection_t,
    dpy: *c.Display,
    root: c.Window,
    visual: *c.Visual,
    colormap: c.Colormap,
    position_top: bool,
) void {
    const response = ipc.sendRequest(allocator, sock_path, .get_outputs, "") orelse return;
    defer allocator.free(response);

    bar_count.* = 0;
    var pos: usize = 0;

    while (pos < response.len and bar_count.* < MAX_OUTPUTS) {
        // Parse output name
        const name_key = std.mem.indexOf(u8, response[pos..], "\"name\":\"") orelse break;
        const name_start = pos + name_key + 8;
        const name_end = std.mem.indexOfScalar(u8, response[name_start..], '"') orelse break;
        const name = response[name_start .. name_start + name_end];

        // Parse rect
        const rect_key = std.mem.indexOf(u8, response[name_start..], "\"rect\":{") orelse break;
        const rect_start = name_start + rect_key;

        const ox = parseJsonInt(response, rect_start, "\"x\":") orelse 0;
        const oy = parseJsonInt(response, rect_start, "\"y\":") orelse 0;
        const ow = parseJsonInt(response, rect_start, "\"width\":") orelse 0;
        const oh = parseJsonInt(response, rect_start, "\"height\":") orelse 0;
        _ = oy;

        if (ow == 0) {
            pos = name_start + name_end + 1;
            continue;
        }

        const idx = bar_count.*;
        const copy_len = @min(name.len, 64);
        @memcpy(bars[idx].output_name[0..copy_len], name[0..copy_len]);
        bars[idx].output_name_len = @intCast(copy_len);
        bars[idx].x = @intCast(ox);
        bars[idx].width = @intCast(ow);

        // Create bar window for this output
        const bar_y: i16 = if (position_top) @intCast(0) else @intCast(oh - BAR_HEIGHT);
        const bar_win = c.xcb_generate_id(conn);
        {
            const values = [_]u32{
                BG_COLOR,
                1, // override_redirect
                c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS,
            };
            _ = c.xcb_create_window(
                conn,
                c.XCB_COPY_FROM_PARENT,
                bar_win,
                @intCast(root),
                @intCast(ox),
                bar_y,
                @intCast(ow),
                BAR_HEIGHT,
                0,
                c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
                @intCast(visual.*.visualid),
                c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK,
                &values,
            );
        }

        // Set DOCK type
        const type_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE");
        const dock_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
        if (type_atom != 0 and dock_atom != 0) {
            const val = [_]u32{dock_atom};
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, bar_win, type_atom, c.XCB_ATOM_ATOM, 32, 1, @ptrCast(&val));
        }

        // Set _NET_WM_STRUT_PARTIAL scoped to this output's x-range
        const strut_partial_atom = internAtom(conn, "_NET_WM_STRUT_PARTIAL");
        if (strut_partial_atom != 0) {
            // 12 values: left, right, top, bottom, left_start_y, left_end_y,
            //            right_start_y, right_end_y, top_start_x, top_end_x,
            //            bottom_start_x, bottom_end_x
            var strut = [_]u32{0} ** 12;
            if (position_top) {
                strut[2] = BAR_HEIGHT; // top
                strut[8] = @intCast(ox); // top_start_x
                strut[9] = @intCast(ox + ow - 1); // top_end_x
            } else {
                strut[3] = BAR_HEIGHT; // bottom
                strut[10] = @intCast(ox); // bottom_start_x
                strut[11] = @intCast(ox + ow - 1); // bottom_end_x
            }
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, bar_win,
                strut_partial_atom, c.XCB_ATOM_CARDINAL, 32, 12, @ptrCast(&strut));
        }

        _ = c.xcb_map_window(conn, bar_win);
        bars[idx].window_id = bar_win;

        // Create XftDraw for this window
        _ = c.XSync(dpy, 0);
        bars[idx].draw = c.XftDrawCreate(dpy, bar_win, visual, colormap);

        bar_count.* += 1;
        pos = name_start + name_end + 1;
    }
    _ = c.xcb_flush(conn);
}

fn parseJsonInt(json: []const u8, start: usize, key: []const u8) ?i32 {
    const key_pos = std.mem.indexOf(u8, json[start..], key) orelse return null;
    const val_start = start + key_pos + key.len;
    var end = val_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '-')) : (end += 1) {}
    return std.fmt.parseInt(i32, json[val_start..end], 10) catch null;
}
```

- [ ] **Step 3: Add ws_output tracking to refreshWorkspaces**

Add output arrays alongside existing workspace arrays (after line 201):

```zig
var ws_outputs: [MaxWorkspaces][64]u8 = undefined;
var ws_output_lens: [MaxWorkspaces]u8 = .{0} ** MaxWorkspaces;
```

In `refreshWorkspaces`, add output name parsing and a new parameter. After parsing `"urgent"`, parse `"output"`:

```zig
// After is_urgent parsing:
var out_name: []const u8 = "";
if (std.mem.indexOf(u8, response[name_start..], "\"output\":\"")) |out_key| {
    const out_start = name_start + out_key + 10;
    if (std.mem.indexOfScalar(u8, response[out_start..], '"')) |out_end| {
        out_name = response[out_start .. out_start + out_end];
    }
}
const out_copy_len = @min(out_name.len, 64);
@memcpy(ws_outputs[idx][0..out_copy_len], out_name[0..out_copy_len]);
ws_output_lens[idx] = @intCast(out_copy_len);
```

Add `ws_outputs` and `ws_output_lens` to the function signature (both as pointer params like existing arrays).

- [ ] **Step 4: Refactor main() — replace single bar window with multi-window**

Remove the single bar window creation block (lines 76-129 in current zephwm-bar/main.zig: the `bar_win` create, DOCK type, strut, map). Replace with:

```zig
// Discover outputs and create per-output bar windows
var bars: [MAX_OUTPUTS]BarWindow = undefined;
var bar_count: usize = 0;
discoverOutputs(allocator, sock_path, &bars, &bar_count, conn, dpy, root, visual, colormap, position_top);

if (bar_count == 0) {
    // Fallback: single bar for the whole screen (no outputs reported)
    std.debug.print("zephwm-bar: no outputs found, using full screen\n", .{});
    bar_count = 1;
    bars[0].x = 0;
    bars[0].width = screen_width;
    // Create single fallback bar window (same as old code)
    const fb_win = c.xcb_generate_id(conn);
    const fb_y: i16 = if (position_top) 0 else @intCast(screen_height - BAR_HEIGHT);
    {
        const values = [_]u32{ BG_COLOR, 1, c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS };
        _ = c.xcb_create_window(conn, c.XCB_COPY_FROM_PARENT, fb_win, @intCast(root),
            0, fb_y, screen_width, BAR_HEIGHT, 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            @intCast(visual.*.visualid),
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK, &values);
    }
    _ = c.xcb_map_window(conn, fb_win);
    _ = c.xcb_flush(conn);
    _ = c.XSync(dpy, 0);
    bars[0].window_id = fb_win;
    bars[0].draw = c.XftDrawCreate(dpy, fb_win, visual, colormap);
}
```

Remove the old `draw` and `gc` per-window setup; create a single shared `gc`:

```zig
const gc = c.xcb_generate_id(conn);
{
    const gc_values = [_]u32{ BG_COLOR, 0 };
    _ = c.xcb_create_gc(conn, gc, bars[0].window_id, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &gc_values);
}
defer _ = c.xcb_free_gc(conn, gc);
```

- [ ] **Step 5: Update drawBar signature and main loop to iterate all bars**

Change drawBar to take a `BarWindow` pointer instead of `bar_win` + `screen_width`:

```zig
fn drawBar(
    conn: *c.xcb_connection_t,
    dpy: *c.Display,
    bar: *const BarWindow,
    font: *c.XftFont,
    gc: u32,
    ws_names: *[16][32]u8,
    ws_name_lens: *[16]u8,
    ws_focused: *[16]bool,
    ws_urgent: *[16]bool,
    ws_count: usize,
    ws_outputs: *[16][64]u8,
    ws_output_lens: *[16]u8,
    status: []const u8,
    focused_fg: *c.XftColor,
    unfocused_fg: *c.XftColor,
    fg_color: *c.XftColor,
) void {
    const bar_win = bar.window_id;
    const draw = bar.draw orelse return;
    const bar_width = bar.width;
    const bar_output = bar.output_name[0..bar.output_name_len];
```

In the workspace button loop, add output filtering:

```zig
    for (0..ws_count) |i| {
        const name_len = ws_name_lens[i];
        if (name_len == 0) continue;

        // Filter: only show workspaces belonging to this bar's output
        if (bar_output.len > 0 and ws_output_lens[i] > 0) {
            const ws_out = ws_outputs[i][0..ws_output_lens[i]];
            if (!std.mem.eql(u8, ws_out, bar_output)) continue;
        }

        // ... rest of button drawing (unchanged, use bar_win and bar_width)
```

In the main loop, change the single `drawBar` call to iterate all bars:

```zig
for (bars[0..bar_count]) |*bar| {
    drawBar(conn, dpy, bar, font, gc, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, ws_count, &ws_outputs, &ws_output_lens, status_text[0..status_len], &focused_fg, &unfocused_fg, &fg_color);
}
```

Similarly update the handleClick to determine which bar was clicked and filter accordingly.

- [ ] **Step 6: Build all binaries**

Run: `cd /home/midasdf/zephwm && zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 7: Commit**

```bash
git add zephwm-bar/main.zig
git commit -m "feat: per-output bar — multi-window rendering with output filtering"
```

### Task 17: Final integration and cleanup

- [ ] **Step 1: Full build**

Run: `cd /home/midasdf/zephwm && zig build 2>&1`
Expected: All three binaries compile cleanly.

- [ ] **Step 2: Run all tests**

Run: `cd /home/midasdf/zephwm && zig build test 2>&1`
Expected: All tests pass.

- [ ] **Step 3: Remove dead code**

Check for unused `cached_root_window` in render.zig (may no longer be needed if title bars no longer draw on root). Remove if unused.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: cleanup dead code after visual quality improvements"
```

- [ ] **Step 5: Update NEXT_SESSION.md**

Update to reflect completed work and remaining items.

```bash
git add NEXT_SESSION.md
git commit -m "docs: update NEXT_SESSION.md after visual quality improvements"
```
