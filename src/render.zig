// Render module — apply tree layout to X11 windows
const std = @import("std");
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");

/// Cached GC and font for title bar rendering. Initialized lazily.
var title_gc: u32 = 0;
var title_font: u32 = 0;
var title_gc_initialized: bool = false;

/// Font metrics, populated by ensureTitleGc
var font_ascent: u16 = 10;
var font_descent: u16 = 2;
var font_char_width: u16 = 6;

/// Dynamically computed from font metrics. Exported for layout.zig.
pub var tab_bar_height: u16 = 16;

/// Title bar colors (i3 defaults, configurable via setTitleBarColors)
var color_focused_bg: u32 = 0x285577;
var color_unfocused_bg: u32 = 0x222222;
var color_focused_text: u32 = 0xffffff;
var color_unfocused_text: u32 = 0x888888;

/// Set title bar colors from config. Called from main.zig after config load.
pub fn setTitleBarColors(focused_bg: u32, focused_text: u32, unfocused_bg: u32, unfocused_text: u32) void {
    color_focused_bg = focused_bg;
    color_unfocused_bg = unfocused_bg;
    color_focused_text = focused_text;
    color_unfocused_text = unfocused_text;
}

/// Draw title text with ellipsis truncation on a drawable window.
fn drawTitleText(conn: *xcb.Connection, drawable: u32, x: i16, y: i16, title: []const u8, max_width: u16, is_focused: bool) void {
    const max_chars: usize = if (font_char_width > 0 and max_width > 8)
        @intCast((max_width - 8) / font_char_width)
    else
        0;
    const capped_max: usize = @min(max_chars, 255);
    if (capped_max == 0) return;

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

    const text_fg = [_]u32{if (is_focused) color_focused_text else color_unfocused_text};
    _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND, &text_fg);
    _ = xcb.c.xcb_image_text_8(conn, text_len, drawable, title_gc, x, y, text_ptr);
}

/// Draw title bars for tabbed or stacked layout containers.
/// Draws on the visible (focused) child's frame window.
/// `precomputed_count`: if > 0, use as the tiling child count (avoids redundant O(N) walk).
fn drawTitleBars(conn: *xcb.Connection, con: *tree.Container, precomputed_count: usize) void {
    // Find the visible (focused) child — title bars are drawn on its frame
    const visible_child = blk: {
        var cur2 = con.children.first;
        while (cur2) |child| : (cur2 = child.next) {
            if (!child.is_floating and child.is_focused) break :blk child;
        }
        // Fallback to first tiling child
        cur2 = con.children.first;
        while (cur2) |child| : (cur2 = child.next) {
            if (!child.is_floating) break :blk child;
        }
        break :blk @as(?*tree.Container, null);
    };

    const target_child = visible_child orelse return;
    const frame_win = if (target_child.window) |wd_tc| wd_tc.frame_id else return;
    if (frame_win == 0) return;

    const visible_count: usize = if (precomputed_count > 0) precomputed_count else blk: {
        var count: usize = 0;
        var c = con.children.first;
        while (c) |ch| : (c = ch.next) {
            if (!ch.is_floating and ch.is_fullscreen == .none) count += 1;
        }
        break :blk count;
    };
    if (visible_count <= 1) return;

    const text_y_offset: i16 = @intCast(font_ascent + 2);
    const tbh: u16 = tab_bar_height;
    const r = con.rect; // Use parent container rect for width

    if (con.layout == .tabbed) {
        const base_tab_w: u16 = if (visible_count > 0) @intCast(r.w / @as(u32, @intCast(visible_count))) else @intCast(r.w);
        var x: i16 = 0; // relative to frame, not screen
        var tab_idx: usize = 0;
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            // Last visible tab extends to the frame edge to avoid gap
            tab_idx += 1;
            const tab_w: u16 = if (tab_idx == visible_count)
                @intCast(@as(u32, @intCast(r.w)) -| @as(u32, @intCast(x)))
            else
                base_tab_w;

            const bg = if (child.is_focused) color_focused_bg else color_unfocused_bg;
            const bg_val = [_]u32{ bg, bg }; // foreground, background (bit order)
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND | xcb.c.XCB_GC_BACKGROUND, &bg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = x, .y = 0, .width = tab_w, .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            drawTitleText(conn, frame_win, x + 4, text_y_offset, title, tab_w, child.is_focused);
            x += @intCast(tab_w);
        }
    } else if (con.layout == .stacked) {
        var y: i16 = 0; // relative to frame
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_floating) continue;
            const bg = if (child.is_focused) color_focused_bg else color_unfocused_bg;
            const bg_val = [_]u32{ bg, bg }; // foreground, background (bit order)
            _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND | xcb.c.XCB_GC_BACKGROUND, &bg_val);
            const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = 0, .y = y, .width = @intCast(r.w), .height = tbh }};
            _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_win, title_gc, 1, &rect);

            const title = if (child.window) |wd| wd.title else if (child.workspace) |wsd| wsd.name else "?";
            drawTitleText(conn, frame_win, 4, y + text_y_offset, title, @intCast(r.w), child.is_focused);
            y += @intCast(tbh);
        }
    }
}

/// Draw a title bar for a border normal window on its own frame.
pub fn drawNormalTitleBar(conn: *xcb.Connection, con: *tree.Container) void {
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

    const bg: u32 = if (con.is_focused) color_focused_bg else color_unfocused_bg;

    // Fill title bar background
    const bg_val = [_]u32{ bg, bg }; // foreground, background (bit order)
    _ = xcb.c.xcb_change_gc(conn, title_gc, xcb.c.XCB_GC_FOREGROUND | xcb.c.XCB_GC_BACKGROUND, &bg_val);
    const rect = [_]xcb.c.xcb_rectangle_t{.{ .x = 0, .y = 0, .width = content_w, .height = tbh }};
    _ = xcb.c.xcb_poly_fill_rectangle(conn, frame_id, title_gc, 1, &rect);

    drawTitleText(conn, frame_id, 4, text_y_offset, wd.title, content_w, con.is_focused);
}

/// Redraw title bars for a tabbed/stacked container. Called from Expose handler.
pub fn redrawTitleBarsForContainer(conn: *xcb.Connection, con: *tree.Container) void {
    if (!title_gc_initialized or title_gc == 0) return;
    if (con.layout != .tabbed and con.layout != .stacked) return;
    if (con.children.len() <= 1) return;
    drawTitleBars(conn, con, 0); // 0 = compute count internally
}


pub fn ensureTitleGc(conn: *xcb.Connection, root_window: xcb.Window) void {
    if (title_gc_initialized) return;
    title_gc_initialized = true;

    // Font fallback list — try each until one succeeds
    const font_names = [_]struct { name: [*]const u8, len: u16 }{
        .{ .name = "fixed", .len = 5 },
        .{ .name = "-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1", .len = 64 },
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
        font_ascent = @intCast(reply.*.font_ascent);
        font_descent = @intCast(reply.*.font_descent);
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

/// Default border width from config, set by applyTree for use in applyWindow.
var config_border_px: u16 = 1;

/// hide_edge_borders setting from config
var hide_edge_borders: @import("config.zig").HideEdgeBorders = .none;

/// Set hide_edge_borders from config.
pub fn setHideEdgeBorders(val: @import("config.zig").HideEdgeBorders) void {
    hide_edge_borders = val;
}

pub fn applyTree(
    conn: *xcb.Connection,
    root: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
    root_window: xcb.Window,
    default_border: u16,
) void {
    config_border_px = default_border;
    ensureTitleGc(conn, root_window);
    // Iterate over outputs
    var out_cur = root.children.first;
    while (out_cur) |output_con| : (out_cur = output_con.next) {
        if (output_con.type != .output) continue;

        // Find the visible (focused) workspace for this output
        const visible_ws = getVisibleWorkspace(output_con);

        // Iterate workspaces: render visible, unmap others
        var ws_cur = output_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type != .workspace) continue;
            if (visible_ws != null and ws == visible_ws.?) {
                applyRecursive(conn, ws, border_focus_color, border_unfocus_color);
            } else {
                unmapSubtree(conn, ws);
            }
        }
    }
    // Note: flush is NOT done here — the caller (relayoutAndRender) does a single
    // flush after both rendering and ConfigureNotify sends, reducing syscalls.
}

/// Find the focused workspace under an output. Falls back to first workspace.
fn getVisibleWorkspace(output_con: *tree.Container) ?*tree.Container {
    var first_ws: ?*tree.Container = null;
    var cur = output_con.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type != .workspace) continue;
        if (first_ws == null) first_ws = child;
        if (child.is_focused) return child;
    }
    return first_ws;
}

fn applyRecursive(
    conn: *xcb.Connection,
    con: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
) void {
    switch (con.type) {
        .window => applyWindow(conn, con, border_focus_color, border_unfocus_color, 0),
        .root, .output, .workspace, .split_con => {
            // For tabbed/stacked: only the focused child should be mapped
            const hide_unfocused = (con.layout == .tabbed or con.layout == .stacked) and
                con.children.len() > 1;

            // Single pass: process tiling, collect floating/fullscreen/border-normal
            var floating_buf: [32]*tree.Container = undefined;
            var floating_count: usize = 0;
            var fullscreen_buf: [8]*tree.Container = undefined;
            var fullscreen_count: usize = 0;
            var normal_border_buf: [32]*tree.Container = undefined;
            var normal_border_count: usize = 0;

            // For tabbed/stacked: pre-count tiling children, find focused tiling
            // child and first tiling child in a single O(N) walk BEFORE the main
            // loop. This ensures the full count is available when applyWindow is
            // called (stacked layout needs total count for title_offset).
            var tiling_count: u16 = 0;
            var has_focused_tiling: bool = false;
            var first_tiling: ?*tree.Container = null;
            if (hide_unfocused) {
                var pre = con.children.first;
                while (pre) |ch| : (pre = ch.next) {
                    if (!ch.is_floating and ch.is_fullscreen == .none) {
                        tiling_count += 1;
                        if (first_tiling == null) first_tiling = ch;
                        if (ch.is_focused) has_focused_tiling = true;
                    }
                }
            }

            var cur = con.children.first;
            while (cur) |child| : (cur = child.next) {
                if (child.is_fullscreen != .none) {
                    if (fullscreen_count < 8) {
                        fullscreen_buf[fullscreen_count] = child;
                        fullscreen_count += 1;
                    }
                    continue;
                }
                if (child.is_floating) {
                    if (floating_count < 32) {
                        floating_buf[floating_count] = child;
                        floating_count += 1;
                    }
                    continue;
                }

                // Tiling child
                if (hide_unfocused) {
                    const show = child.is_focused or (!has_focused_tiling and child == first_tiling.?);
                    if (show) {
                        mapSubtree(conn, child);
                        // Pass final tiling_count so applyWindow has correct title_offset
                        if (child.type == .window) {
                            applyWindow(conn, child, border_focus_color, border_unfocus_color, tiling_count);
                        } else {
                            applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                        }
                    } else {
                        unmapSubtree(conn, child);
                    }
                } else {
                    applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                    // Collect border normal windows inline (avoid second pass)
                    if (child.type == .window and child.border_style == .normal) {
                        if (normal_border_count < 32) {
                            normal_border_buf[normal_border_count] = child;
                            normal_border_count += 1;
                        }
                    }
                }
            }

            // Draw tab bar / stacked headers AFTER frames are configured.
            // Pass precomputed tiling_count to avoid redundant O(N) recount.
            if (hide_unfocused and title_gc != 0) {
                drawTitleBars(conn, con, tiling_count);
            }

            // Draw border normal title bars
            if (normal_border_count > 0 and title_gc != 0) {
                for (normal_border_buf[0..normal_border_count]) |child| {
                    drawNormalTitleBar(conn, child);
                }
            }

            // Render floating children (on top of tiling)
            for (floating_buf[0..floating_count]) |child| {
                applyRecursive(conn, child, border_focus_color, border_unfocus_color);
            }

            // Draw border normal title bars on floating windows (single pass)
            if (title_gc != 0) {
                for (floating_buf[0..floating_count]) |child| {
                    if (child.type == .window and child.border_style == .normal) {
                        drawNormalTitleBar(conn, child);
                    }
                }
            }

            // Render fullscreen children last (on top of everything)
            for (fullscreen_buf[0..fullscreen_count]) |child| {
                applyFullscreen(conn, child, con);
            }
        },
    }
}

/// `parent_tiling_count`: if > 0, use as the parent's tiling child count
/// (avoids redundant O(N) sibling walk for tabbed/stacked title offset).
fn applyWindow(
    conn: *xcb.Connection,
    con: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
    parent_tiling_count: u16,
) void {
    if (con.window == null) return;
    const wd = &con.window.?;
    const frame_id = wd.frame_id;

    // Fullscreen windows are handled separately by applyFullscreen
    if (con.is_fullscreen != .none) return;

    const r = con.window_rect;

    // Determine title bar offset for tabbed/stacked (only for tiling children)
    var title_offset: u16 = 0;
    if (con.parent) |parent| {
        if (!con.is_floating and con.is_fullscreen == .none) {
            if ((parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1) {
                // Use precomputed count if available, otherwise count siblings
                const visible_count: u16 = if (parent_tiling_count > 0) parent_tiling_count else blk: {
                    var count: u16 = 0;
                    var c = parent.children.first;
                    while (c) |ch| : (c = ch.next) {
                        if (!ch.is_floating and ch.is_fullscreen == .none) count += 1;
                    }
                    break :blk count;
                };
                if (visible_count > 1) {
                    title_offset = if (parent.layout == .tabbed) tab_bar_height else tab_bar_height * visible_count;
                }
            } else if (con.border_style == .normal) {
                // border normal: individual title bar on this window
                title_offset = tab_bar_height;
            }
        }
    }
    // Also handle border normal for floating windows
    if (con.is_floating and con.border_style == .normal) {
        title_offset = tab_bar_height;
    }

    // Configure frame: position and size (includes title bar area)
    const frame_h: u32 = r.h + @as(u32, title_offset);
    const frame_y: i32 = r.y - @as(i32, @intCast(title_offset));
    if (frame_id != 0) {
        // Compute effective border width from per-window style
        const effective_border: u16 = blk: {
            if (con.border_style == .none) break :blk 0;
            // hide_edge_borders: hide borders when window is the only tiling child
            if (hide_edge_borders != .none and !con.is_floating) {
                if (con.parent) |parent| {
                    if (parent.type == .workspace and parent.tilingChildCount() == 1) {
                        break :blk 0;
                    }
                }
            }
            if (con.border_width_override >= 0) break :blk @intCast(con.border_width_override);
            break :blk config_border_px;
        };
        // Frame content width/height = allocated rect minus borders on both sides.
        // X11 draws borders OUTSIDE the configured size, so we shrink the content
        // so that content + 2*border fits within the layout-allocated rect.
        const b2: u32 = @as(u32, effective_border) * 2;
        const content_w: u32 = if (r.w > b2) r.w - b2 else 1;
        const content_h: u32 = if (frame_h > b2) frame_h - b2 else 1;
        const values = [_]u32{
            @bitCast(r.x),
            @bitCast(frame_y),
            content_w,
            content_h,
            @as(u32, effective_border),
        };
        const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT |
            xcb.CONFIG_WINDOW_BORDER_WIDTH;
        _ = xcb.configureWindow(conn, frame_id, mask, &values);

        // Configure client inside frame (fills frame content area)
        const client_w: u32 = content_w;
        const client_h: u32 = if (content_h > @as(u32, title_offset)) content_h - @as(u32, title_offset) else 1;
        const client_values = [_]u32{
            0, // x = 0 inside frame
            @as(u32, title_offset), // y = below title bar
            client_w,
            client_h,
        };
        const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
        _ = xcb.configureWindow(conn, wd.id, client_mask, &client_values);

        // Border color on frame
        const color = if (con.is_focused) border_focus_color else border_unfocus_color;
        const border_values = [_]u32{color};
        _ = xcb.changeWindowAttributes(conn, frame_id, xcb.CW_BORDER_PIXEL, &border_values);

        // Map frame
        _ = xcb.mapWindow(conn, frame_id);
    } else {
        // No frame — configure client directly (fallback)
        const values = [_]u32{
            @bitCast(r.x),
            @bitCast(r.y),
            r.w,
            r.h,
        };
        const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
        _ = xcb.configureWindow(conn, wd.id, mask, &values);

        const color = if (con.is_focused) border_focus_color else border_unfocus_color;
        const border_values = [_]u32{color};
        _ = xcb.changeWindowAttributes(conn, wd.id, xcb.CW_BORDER_PIXEL, &border_values);

        _ = xcb.mapWindow(conn, wd.id);
    }
    wd.mapped = true;
}

/// Render a fullscreen window: fill entire output, no border, raise above all.
fn applyFullscreen(conn: *xcb.Connection, con: *tree.Container, parent_con: *tree.Container) void {
    if (con.window == null) return;
    const wd = &con.window.?;
    const frame_id = wd.frame_id;

    // Use parent's rect (output or workspace rect) for fullscreen
    const r = parent_con.rect;

    if (frame_id != 0) {
        // Configure frame: position, size, border=0, raise to top
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
        const client_values = [_]u32{ 0, 0, if (r.w > 0) r.w else 1, if (r.h > 0) r.h else 1 };
        const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
        _ = xcb.configureWindow(conn, wd.id, client_mask, &client_values);

        _ = xcb.mapWindow(conn, frame_id);
    } else {
        // No frame — configure client directly (fallback)
        const values = [_]u32{
            @bitCast(r.x),
            @bitCast(r.y),
            r.w,
            r.h,
            0,
            xcb.STACK_MODE_ABOVE,
        };
        const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
            xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT |
            xcb.CONFIG_WINDOW_BORDER_WIDTH | xcb.CONFIG_WINDOW_STACK_MODE;
        _ = xcb.configureWindow(conn, wd.id, mask, &values);

        _ = xcb.mapWindow(conn, wd.id);
    }
    wd.mapped = true;
}

/// Map all windows in a subtree.
fn mapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |*win_data| {
            if (win_data.frame_id != 0) {
                _ = xcb.mapWindow(conn, win_data.frame_id);
                // Also map client window inside frame — it may have been
                // unmapped by the client or lost its map state.
                _ = xcb.mapWindow(conn, win_data.id);
            } else {
                _ = xcb.mapWindow(conn, win_data.id);
            }
            win_data.mapped = true;
        }
        return;
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        mapSubtree(conn, child);
    }
}

/// Check if any tiling (non-floating) child has is_focused set.
fn anyTilingChildFocused(con: *tree.Container) bool {
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        if (!child.is_floating and child.is_focused) return true;
    }
    return false;
}

/// Unmap all windows in a subtree.
/// Only unmaps windows that are currently mapped (tracked by WindowData.mapped).
/// Increments pending_unmap counter so UnmapNotify from WM-initiated unmaps is ignored.
pub fn unmapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |*win_data| {
            if (win_data.mapped) {
                if (win_data.frame_id != 0) {
                    // Unmap the frame — children become invisible but their
                    // X11 map state is preserved. Do NOT increment pending_unmap
                    // because the client itself does not receive UnmapNotify
                    // when its parent is unmapped.
                    _ = xcb.unmapWindow(conn, win_data.frame_id);
                } else {
                    // No frame — unmap client directly. This DOES generate
                    // UnmapNotify for the client, so increment counter.
                    _ = xcb.unmapWindow(conn, win_data.id);
                    win_data.pending_unmap +|= 1;
                }
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
