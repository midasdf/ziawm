const std = @import("std");
const tree = @import("tree.zig");
const Allocator = std.mem.Allocator;

/// Find a workspace container by name under `root`. Searches recursively.
pub fn findByName(root: *tree.Container, name: []const u8) ?*tree.Container {
    if (root.type == .workspace) {
        if (root.workspace) |ws| {
            if (std.mem.eql(u8, ws.name, name)) return root;
        }
    }
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (findByName(child, name)) |found| return found;
    }
    return null;
}

/// Find a workspace container by number under `root`. Searches recursively.
pub fn findByNum(root: *tree.Container, num: i32) ?*tree.Container {
    if (root.type == .workspace) {
        if (root.workspace) |ws| {
            if (ws.num) |n| {
                if (n == num) return root;
            }
        }
    }
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (findByNum(child, num)) |found| return found;
    }
    return null;
}

/// Allocate a new workspace container with the given name and optional number.
/// The container is not attached to any parent; the caller is responsible for
/// inserting it into the tree.
pub fn create(allocator: Allocator, name: []const u8, num: i32) !*tree.Container {
    const con = try tree.Container.create(allocator, .workspace);
    con.workspace = tree.WorkspaceData{
        .name = name,
        .num = num,
    };
    return con;
}
