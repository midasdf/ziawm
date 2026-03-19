// Render module — apply tree layout to X11 windows
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");

/// Walk the container tree and apply geometry to X11 windows.
/// Only the focused (visible) workspace per output is rendered;
/// windows on other workspaces are unmapped.
pub fn applyTree(
    conn: *xcb.Connection,
    root: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
) void {
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
    _ = xcb.flush(conn);
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
        .window => applyWindow(conn, con, border_focus_color, border_unfocus_color),
        .root, .output, .workspace, .split_con => {
            // For tabbed/stacked: only the focused child should be mapped
            const hide_unfocused = (con.layout == .tabbed or con.layout == .stacked) and
                con.children.len() > 1;

            // Single pass: process tiling, collect floating/fullscreen for deferred rendering
            var floating_buf: [32]*tree.Container = undefined;
            var floating_count: usize = 0;
            var fullscreen_buf: [8]*tree.Container = undefined;
            var fullscreen_count: usize = 0;

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
                    const show = child.is_focused or (!anyTilingChildFocused(con) and isFirstTilingChild(con, child));
                    if (show) {
                        mapSubtree(conn, child);
                        applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                    } else {
                        unmapSubtree(conn, child);
                    }
                } else {
                    applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                }
            }

            // Render floating children (on top of tiling)
            for (floating_buf[0..floating_count]) |child| {
                applyRecursive(conn, child, border_focus_color, border_unfocus_color);
            }

            // Render fullscreen children last (on top of everything)
            for (fullscreen_buf[0..fullscreen_count]) |child| {
                applyFullscreen(conn, child, con);
            }
        },
    }
}

fn applyWindow(
    conn: *xcb.Connection,
    con: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
) void {
    if (con.window == null) return;
    const win_id = con.window.?.id;

    // Fullscreen windows are handled separately by applyFullscreen
    if (con.is_fullscreen != .none) return;

    const r = con.window_rect;

    // Configure window geometry
    const values = [_]u32{
        @bitCast(r.x),
        @bitCast(r.y),
        r.w,
        r.h,
    };
    const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
        xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
    _ = xcb.configureWindow(conn, win_id, mask, &values);

    // Set border color based on focus
    const color = if (con.is_focused) border_focus_color else border_unfocus_color;
    const border_values = [_]u32{color};
    _ = xcb.changeWindowAttributes(conn, win_id, xcb.CW_BORDER_PIXEL, &border_values);

    // Ensure the window is mapped
    _ = xcb.mapWindow(conn, win_id);
    con.window.?.mapped = true;
    con.window.?.pending_unmap = 0; // Reset stale unmap counter on map
}

/// Render a fullscreen window: fill entire output, no border, raise above all.
fn applyFullscreen(conn: *xcb.Connection, con: *tree.Container, parent_con: *tree.Container) void {
    if (con.window == null) return;
    const win_id = con.window.?.id;

    // Use parent's rect (output or workspace rect) for fullscreen
    const r = parent_con.rect;

    // Configure: position, size, border=0, raise to top
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
    _ = xcb.configureWindow(conn, win_id, mask, &values);

    _ = xcb.mapWindow(conn, win_id);
    con.window.?.mapped = true;
    con.window.?.pending_unmap = 0; // Reset stale unmap counter on map
}

/// Map all windows in a subtree.
fn mapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |*win_data| {
            _ = xcb.mapWindow(conn, win_data.id);
            win_data.mapped = true;
            win_data.pending_unmap = 0; // Reset stale unmap counter on map
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

/// Check if `child` is the first tiling (non-floating) child of `con`.
fn isFirstTilingChild(con: *tree.Container, child: *tree.Container) bool {
    var cur = con.children.first;
    while (cur) |c| : (cur = c.next) {
        if (!c.is_floating) return c == child;
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
                _ = xcb.unmapWindow(conn, win_data.id);
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
