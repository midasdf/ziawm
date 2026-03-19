// Render module — apply tree layout to X11 windows
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");

/// Walk the container tree and apply geometry to X11 windows.
/// Configures window position/size via xcb and sets border colors
/// based on focus state.
pub fn applyTree(
    conn: *xcb.Connection,
    root: *tree.Container,
    border_focus_color: u32,
    border_unfocus_color: u32,
) void {
    applyRecursive(conn, root, border_focus_color, border_unfocus_color);
    _ = xcb.flush(conn);
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

            var cur = con.children.first;
            while (cur) |child| : (cur = child.next) {
                if (child.is_floating) continue;

                if (hide_unfocused) {
                    if (child.is_focused) {
                        mapSubtree(conn, child);
                        applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                    } else {
                        unmapSubtree(conn, child);
                    }
                } else {
                    applyRecursive(conn, child, border_focus_color, border_unfocus_color);
                }
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
    const win_data = con.window orelse return;
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
    _ = xcb.configureWindow(conn, win_data.id, mask, &values);

    // Set border color based on focus
    const color = if (con.is_focused) border_focus_color else border_unfocus_color;
    const border_values = [_]u32{color};
    _ = xcb.changeWindowAttributes(conn, win_data.id, xcb.CW_BORDER_PIXEL, &border_values);

    // Ensure the window is mapped
    _ = xcb.mapWindow(conn, win_data.id);
}

/// Map all windows in a subtree.
fn mapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |win_data| {
            _ = xcb.mapWindow(conn, win_data.id);
        }
        return;
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        mapSubtree(conn, child);
    }
}

/// Unmap all windows in a subtree.
fn unmapSubtree(conn: *xcb.Connection, con: *tree.Container) void {
    if (con.type == .window) {
        if (con.window) |win_data| {
            _ = xcb.unmapWindow(conn, win_data.id);
        }
        return;
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        unmapSubtree(conn, child);
    }
}
