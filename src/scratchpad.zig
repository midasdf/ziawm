const std = @import("std");
const tree = @import("tree.zig");
const workspace = @import("workspace.zig");
const Allocator = std.mem.Allocator;

pub const SCRATCH_NAME = "__i3_scratch";

/// Return the scratchpad workspace under `root`, creating it if necessary.
/// The new workspace is appended as a direct child of `root`.
pub fn getScratchWorkspace(root: *tree.Container, allocator: Allocator) !*tree.Container {
    if (workspace.findByName(root, SCRATCH_NAME)) |ws| return ws;

    // Create and attach a new scratch workspace.
    const ws = try workspace.create(allocator, SCRATCH_NAME, -1);
    root.appendChild(ws);
    ws.is_scratchpad = true;
    return ws;
}

/// Move `con` from its current position in the tree into the scratchpad workspace.
/// `con` is unlinked from its current parent, marked as scratchpad and floating,
/// then appended to the scratchpad workspace.
pub fn moveToScratchpad(con: *tree.Container, root: *tree.Container, allocator: Allocator) !void {
    const scratch = try getScratchWorkspace(root, allocator);
    con.unlink();
    con.is_scratchpad = true;
    con.is_floating = true;
    scratch.appendChild(con);
}
