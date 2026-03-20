const std = @import("std");
const tree = @import("tree");
const scratchpad = @import("scratchpad");

const Container = tree.Container;

test "getScratchWorkspace creates scratch workspace" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    const scratch = try scratchpad.getScratchWorkspace(root, alloc);
    try std.testing.expect(scratch.workspace != null);
    try std.testing.expectEqualStrings(scratchpad.SCRATCH_NAME, scratch.workspace.?.name);
    try std.testing.expect(scratch.is_scratchpad);
}

test "getScratchWorkspace returns same workspace on second call" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    const scratch1 = try scratchpad.getScratchWorkspace(root, alloc);
    const scratch2 = try scratchpad.getScratchWorkspace(root, alloc);
    try std.testing.expectEqual(scratch1, scratch2);
}

test "moveToScratchpad moves container" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    // Create a workspace with a window
    const ws = try Container.create(alloc, .workspace);
    root.appendChild(ws);
    const win = try Container.create(alloc, .window);
    ws.appendChild(win);

    try std.testing.expectEqual(@as(usize, 1), ws.children.len());

    // Move to scratchpad
    try scratchpad.moveToScratchpad(win, root, alloc);

    // Window should be removed from workspace
    try std.testing.expectEqual(@as(usize, 0), ws.children.len());

    // Window should be in scratchpad workspace
    try std.testing.expect(win.is_scratchpad);
    try std.testing.expect(win.is_floating);
    try std.testing.expect(win.parent != null);
    try std.testing.expectEqualStrings(scratchpad.SCRATCH_NAME, win.parent.?.workspace.?.name);
}
