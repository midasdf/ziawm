// Output detection — screen/monitor setup
const std = @import("std");
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");
const workspace = @import("workspace.zig");

/// Detect outputs and create the initial tree structure.
/// For now: single output matching the root screen dimensions.
/// TODO: XRandR multi-monitor detection.
pub fn detectOutputs(
    conn: *xcb.Connection,
    tree_root: *tree.Container,
    allocator: std.mem.Allocator,
) !void {
    const screen = xcb.getScreen(conn) orelse return error.NoScreen;

    // Create a single output container
    const output_con = try tree.Container.create(allocator, .output);
    output_con.rect = .{
        .x = 0,
        .y = 0,
        .w = screen.width_in_pixels,
        .h = screen.height_in_pixels,
    };
    tree_root.appendChild(output_con);

    // Create default workspace "1" under the output
    const ws = try workspace.create(allocator, "1", 1);
    ws.rect = output_con.rect;
    output_con.appendChild(ws);
    ws.is_focused = true;
}
