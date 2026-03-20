const std = @import("std");
const tree = @import("tree");
const workspace = @import("workspace");

const Container = tree.Container;

test "create workspace with name and number" {
    const alloc = std.testing.allocator;
    const ws = try workspace.create(alloc, "1", 1);
    defer ws.destroy(alloc);

    try std.testing.expectEqual(tree.ContainerType.workspace, ws.type);
    try std.testing.expect(ws.workspace != null);
    const wsd = ws.workspace.?;
    try std.testing.expectEqualStrings("1", wsd.name);
    try std.testing.expectEqual(@as(?i32, 1), wsd.num);
}

test "create workspace with named workspace" {
    const alloc = std.testing.allocator;
    const ws = try workspace.create(alloc, "dev", 0);
    defer ws.destroy(alloc);

    const wsd = ws.workspace.?;
    try std.testing.expectEqualStrings("dev", wsd.name);
    try std.testing.expectEqual(@as(?i32, 0), wsd.num);
}

test "findByName finds correct workspace" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    const ws1 = try workspace.create(alloc, "code", 1);
    root.appendChild(ws1);

    const ws2 = try workspace.create(alloc, "web", 2);
    root.appendChild(ws2);

    const found = workspace.findByName(root, "web");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("web", found.?.workspace.?.name);

    try std.testing.expect(workspace.findByName(root, "nonexistent") == null);
}

test "findByNum finds correct workspace" {
    const alloc = std.testing.allocator;
    const root = try Container.create(alloc, .root);
    defer root.destroy(alloc);

    const ws1 = try workspace.create(alloc, "1", 1);
    root.appendChild(ws1);

    const ws2 = try workspace.create(alloc, "2", 2);
    root.appendChild(ws2);

    const found = workspace.findByNum(root, 2);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("2", found.?.workspace.?.name);

    try std.testing.expect(workspace.findByNum(root, 99) == null);
}
