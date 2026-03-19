const std = @import("std");
const tree = @import("tree");

const Container = tree.Container;
const ContainerType = tree.ContainerType;
const Layout = tree.Layout;
const FullscreenMode = tree.FullscreenMode;
const Rect = tree.Rect;
const WindowData = tree.WindowData;
const WorkspaceData = tree.WorkspaceData;

test "create root container" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    try std.testing.expectEqual(ContainerType.root, root.type);
    try std.testing.expectEqual(Layout.hsplit, root.layout);
    try std.testing.expect(root.parent == null);
    try std.testing.expect(root.children.first == null);
    try std.testing.expect(root.children.last == null);
    try std.testing.expectEqual(@as(f32, 0.0), root.percent);
    try std.testing.expectEqual(FullscreenMode.none, root.is_fullscreen);
    try std.testing.expectEqual(false, root.is_floating);
    try std.testing.expectEqual(false, root.is_focused);
    try std.testing.expectEqual(false, root.is_scratchpad);
    try std.testing.expectEqual(true, root.dirty);
    try std.testing.expectEqual(@as(u8, 0), root.mark_count);
}

test "appendChild and child ordering" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);
    const c3 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);
    root.appendChild(c3);

    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(root.children.last == c3);
    try std.testing.expectEqual(@as(usize, 3), root.children.len());

    try std.testing.expect(c1.parent == root);
    try std.testing.expect(c2.parent == root);
    try std.testing.expect(c3.parent == root);

    try std.testing.expect(c1.prev == null);
    try std.testing.expect(c1.next == c2);
    try std.testing.expect(c2.prev == c1);
    try std.testing.expect(c2.next == c3);
    try std.testing.expect(c3.prev == c2);
    try std.testing.expect(c3.next == null);
}

test "unlink removes from parent" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);
    const c3 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);
    root.appendChild(c3);

    // Unlink the middle child
    c2.unlink();
    defer alloc.destroy(c2);

    try std.testing.expectEqual(@as(usize, 2), root.children.len());
    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(root.children.last == c3);
    try std.testing.expect(c1.next == c3);
    try std.testing.expect(c3.prev == c1);
    try std.testing.expect(c2.parent == null);
    try std.testing.expect(c2.prev == null);
    try std.testing.expect(c2.next == null);
}

test "unlink first child" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);

    root.appendChild(c1);
    root.appendChild(c2);

    c1.unlink();
    defer alloc.destroy(c1);

    try std.testing.expectEqual(@as(usize, 1), root.children.len());
    try std.testing.expect(root.children.first == c2);
    try std.testing.expect(root.children.last == c2);
    try std.testing.expect(c2.prev == null);
    try std.testing.expect(c2.next == null);
}

test "unlink last child" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);

    root.appendChild(c1);
    root.appendChild(c2);

    c2.unlink();
    defer alloc.destroy(c2);

    try std.testing.expectEqual(@as(usize, 1), root.children.len());
    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(root.children.last == c1);
    try std.testing.expect(c1.prev == null);
    try std.testing.expect(c1.next == null);
}

test "promoteChild moves to head" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);
    const c3 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);
    root.appendChild(c3);

    root.promoteChild(c3);

    try std.testing.expect(root.children.first == c3);
    try std.testing.expect(c3.prev == null);
    try std.testing.expect(c3.next == c1);
    try std.testing.expect(c1.prev == c3);
    try std.testing.expect(c1.next == c2);
    try std.testing.expect(c2.prev == c1);
    try std.testing.expect(c2.next == null);
    try std.testing.expect(root.children.last == c2);
    try std.testing.expectEqual(@as(usize, 3), root.children.len());
}

test "promoteChild already at head is no-op" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);

    root.appendChild(c1);
    root.appendChild(c2);

    root.promoteChild(c1);

    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(root.children.last == c2);
    try std.testing.expectEqual(@as(usize, 2), root.children.len());
}

test "marks add/remove/has" {
    const alloc = std.testing.allocator;
    const c = try Container.create(alloc, .window);
    defer c.destroy(alloc);

    try std.testing.expectEqual(false, c.hasMark("urgent"));
    try std.testing.expectEqual(false, c.hasMark("foo"));

    const mark1 = try alloc.dupe(u8, "urgent");
    try c.addMark(mark1);
    try std.testing.expectEqual(true, c.hasMark("urgent"));
    try std.testing.expectEqual(@as(u8, 1), c.mark_count);

    const mark2 = try alloc.dupe(u8, "foo");
    try c.addMark(mark2);
    try std.testing.expectEqual(true, c.hasMark("foo"));
    try std.testing.expectEqual(@as(u8, 2), c.mark_count);

    // Adding duplicate mark should return DuplicateMark error
    {
        const dup = try alloc.dupe(u8, "urgent");
        try std.testing.expectError(error.DuplicateMark, c.addMark(dup));
        alloc.free(dup); // caller frees on error
    }
    try std.testing.expectEqual(@as(u8, 2), c.mark_count);

    c.removeMark(alloc, "urgent");
    try std.testing.expectEqual(false, c.hasMark("urgent"));
    try std.testing.expectEqual(true, c.hasMark("foo"));
    try std.testing.expectEqual(@as(u8, 1), c.mark_count);

    c.removeMark(alloc, "nonexistent"); // no-op
    try std.testing.expectEqual(@as(u8, 1), c.mark_count);

    c.removeMark(alloc, "foo");
    try std.testing.expectEqual(@as(u8, 0), c.mark_count);
}

test "marks capacity limit" {
    const alloc = std.testing.allocator;
    const c = try Container.create(alloc, .window);
    defer c.destroy(alloc);

    // Fill to max capacity (4)
    const mark_names = [_][]const u8{ "m1", "m2", "m3", "m4" };
    for (mark_names) |name| {
        const owned = try alloc.dupe(u8, name);
        try c.addMark(owned);
    }
    try std.testing.expectEqual(@as(u8, 4), c.mark_count);

    // Adding one more should return error
    {
        const overflow = try alloc.dupe(u8, "m5");
        try std.testing.expectError(error.MarksCapacityExceeded, c.addMark(overflow));
        alloc.free(overflow); // caller frees on error
    }
}

test "insertBefore" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);
    const c_new = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);

    // Insert c_new before c2
    root.insertBefore(c_new, c2);

    try std.testing.expectEqual(@as(usize, 3), root.children.len());
    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(c1.next == c_new);
    try std.testing.expect(c_new.prev == c1);
    try std.testing.expect(c_new.next == c2);
    try std.testing.expect(c2.prev == c_new);
    try std.testing.expect(root.children.last == c2);
}

test "insertBefore first element" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .split_con);
    const c_new = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.insertBefore(c_new, c1);

    try std.testing.expectEqual(@as(usize, 2), root.children.len());
    try std.testing.expect(root.children.first == c_new);
    try std.testing.expect(c_new.prev == null);
    try std.testing.expect(c_new.next == c1);
    try std.testing.expect(c1.prev == c_new);
    try std.testing.expect(root.children.last == c1);
}

test "tilingChildCount excludes floating" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    const c3 = try Container.create(alloc, .window);

    c2.is_floating = true;

    root.appendChild(c1);
    root.appendChild(c2);
    root.appendChild(c3);

    try std.testing.expectEqual(@as(usize, 3), root.children.len());
    try std.testing.expectEqual(@as(usize, 2), root.tilingChildCount());
}

test "tilingChildCount all tiling" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);

    try std.testing.expectEqual(@as(usize, 2), root.tilingChildCount());
}

test "tilingChildCount empty" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    try std.testing.expectEqual(@as(usize, 0), root.tilingChildCount());
}

test "focusedChild returns focused child" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    const c3 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);
    root.appendChild(c3);

    try std.testing.expect(root.focusedChild() == null);

    c2.is_focused = true;
    try std.testing.expect(root.focusedChild() == c2);
}

test "destroy cleans up children" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);

    const c1 = try Container.create(alloc, .split_con);
    const c2 = try Container.create(alloc, .split_con);
    const c3 = try Container.create(alloc, .window);

    root.appendChild(c1);
    root.appendChild(c2);
    c2.appendChild(c3);

    // destroy should recursively free all children
    root.destroy(alloc);
    // If we reach here without crash/leak, test passes (allocator checks for leaks)
}

test "Rect default values" {
    const r: Rect = .{};
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 0), r.w);
    try std.testing.expectEqual(@as(u32, 0), r.h);
}

test "WindowData fields" {
    const wd = WindowData{
        .id = 42,
        .class = "firefox",
        .title = "Mozilla Firefox",
        .window_role = "browser",
        .transient_for = null,
        .urgency = false,
    };
    try std.testing.expectEqual(@as(u32, 42), wd.id);
    try std.testing.expectEqualStrings("firefox", wd.class);
    try std.testing.expectEqualStrings("browser", wd.window_role);
}

test "WorkspaceData fields" {
    const ws = WorkspaceData{
        .name = "1",
        .num = 1,
        .output_name = "HDMI-1",
    };
    try std.testing.expectEqualStrings("1", ws.name);
    try std.testing.expectEqual(@as(?i32, 1), ws.num);
    try std.testing.expectEqualStrings("HDMI-1", ws.output_name);
}

test "ChildList len on single element" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .workspace);
    defer root.destroy(alloc);

    const c1 = try Container.create(alloc, .window);
    root.appendChild(c1);

    try std.testing.expectEqual(@as(usize, 1), root.children.len());
    try std.testing.expect(root.children.first == c1);
    try std.testing.expect(root.children.last == c1);
    try std.testing.expect(c1.prev == null);
    try std.testing.expect(c1.next == null);
}
