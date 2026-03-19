const std = @import("std");
const tree = @import("tree");
const layout = @import("layout");

const Container = tree.Container;
const ContainerType = tree.ContainerType;
const Rect = tree.Rect;

// Helper: create a workspace container with a given rect.
fn makeWs(alloc: std.mem.Allocator, w: u32, h: u32) !*Container {
    const ws = try Container.create(alloc, .workspace);
    ws.rect = .{ .x = 0, .y = 0, .w = w, .h = h };
    return ws;
}

test "single tiling child fills entire area" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);

    const child = try Container.create(alloc, .window);
    ws.appendChild(child);

    layout.apply(ws, 0, 0);

    try std.testing.expectEqual(@as(i32, 0), child.rect.x);
    try std.testing.expectEqual(@as(i32, 0), child.rect.y);
    try std.testing.expectEqual(@as(u32, 720), child.rect.w);
    try std.testing.expectEqual(@as(u32, 720), child.rect.h);
    try std.testing.expectEqual(false, child.dirty);
}

test "hsplit two children equal width" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .hsplit;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 0, 0);

    try std.testing.expectEqual(@as(i32, 0), c1.rect.x);
    try std.testing.expectEqual(@as(u32, 360), c1.rect.w);
    try std.testing.expectEqual(@as(u32, 720), c1.rect.h);

    try std.testing.expectEqual(@as(i32, 360), c2.rect.x);
    // Last child gets remainder: 720 - 360 = 360
    try std.testing.expectEqual(@as(u32, 360), c2.rect.w);
    try std.testing.expectEqual(@as(u32, 720), c2.rect.h);
}

test "vsplit two children equal height" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .vsplit;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 0, 0);

    try std.testing.expectEqual(@as(i32, 0), c1.rect.y);
    try std.testing.expectEqual(@as(u32, 360), c1.rect.h);
    try std.testing.expectEqual(@as(u32, 720), c1.rect.w);

    try std.testing.expectEqual(@as(i32, 360), c2.rect.y);
    try std.testing.expectEqual(@as(u32, 360), c2.rect.h);
    try std.testing.expectEqual(@as(u32, 720), c2.rect.w);
}

test "hsplit two children with 4px gap" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .hsplit;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 4, 0);

    // available_w = 720 - 4 = 716; each = 716 / 2 = 358
    try std.testing.expectEqual(@as(i32, 0), c1.rect.x);
    try std.testing.expectEqual(@as(u32, 358), c1.rect.w);

    // c2 starts at 358 + 4 = 362; remainder = 720 - 362 = 358
    try std.testing.expectEqual(@as(i32, 362), c2.rect.x);
    try std.testing.expectEqual(@as(u32, 358), c2.rect.w);
}

test "hsplit custom percent 0.6 / 0.4" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 1000, 720);
    defer ws.destroy(alloc);
    ws.layout = .hsplit;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    c1.percent = 0.6;
    c2.percent = 0.4;
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 0, 0);

    // available_w = 1000 (no gap); c1 = 0.6 * 1000 = 600
    try std.testing.expectEqual(@as(u32, 600), c1.rect.w);
    try std.testing.expectEqual(@as(i32, 0), c1.rect.x);

    // c2 is last child: remainder = 1000 - 600 = 400
    try std.testing.expectEqual(@as(i32, 600), c2.rect.x);
    try std.testing.expectEqual(@as(u32, 400), c2.rect.w);
}

test "nested vsplit parent with hsplit child" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .vsplit;

    // Top half: a split_con with hsplit containing two windows
    const top = try Container.create(alloc, .split_con);
    top.layout = .hsplit;
    const bot = try Container.create(alloc, .window);

    ws.appendChild(top);
    ws.appendChild(bot);

    const tl = try Container.create(alloc, .window);
    const tr = try Container.create(alloc, .window);
    top.appendChild(tl);
    top.appendChild(tr);

    layout.apply(ws, 0, 0);

    // top gets upper half: y=0, h=360
    try std.testing.expectEqual(@as(i32, 0), top.rect.y);
    try std.testing.expectEqual(@as(u32, 360), top.rect.h);

    // bot gets lower half: y=360, h=360
    try std.testing.expectEqual(@as(i32, 360), bot.rect.y);
    try std.testing.expectEqual(@as(u32, 360), bot.rect.h);

    // tl and tr are split horizontally within top (720x360)
    try std.testing.expectEqual(@as(i32, 0), tl.rect.x);
    try std.testing.expectEqual(@as(u32, 360), tl.rect.w);
    try std.testing.expectEqual(@as(u32, 360), tl.rect.h);

    try std.testing.expectEqual(@as(i32, 360), tr.rect.x);
    try std.testing.expectEqual(@as(u32, 360), tr.rect.w);
    try std.testing.expectEqual(@as(u32, 360), tr.rect.h);
}

test "tabbed layout: all children same rect with 16px tab offset" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .tabbed;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    const c3 = try Container.create(alloc, .window);
    ws.appendChild(c1);
    ws.appendChild(c2);
    ws.appendChild(c3);

    layout.apply(ws, 0, 0);

    // All children get same rect: y=16, h=704, w=720
    for ([_]*Container{ c1, c2, c3 }) |child| {
        try std.testing.expectEqual(@as(i32, 16), child.rect.y);
        try std.testing.expectEqual(@as(u32, 704), child.rect.h);
        try std.testing.expectEqual(@as(u32, 720), child.rect.w);
        try std.testing.expectEqual(@as(i32, 0), child.rect.x);
        try std.testing.expectEqual(false, child.dirty);
    }
}

test "border reduces window_rect" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);

    const child = try Container.create(alloc, .window);
    ws.appendChild(child);

    layout.apply(ws, 0, 2);

    // rect is full 720x720, window_rect is 4px smaller on each axis
    try std.testing.expectEqual(@as(u32, 720), child.rect.w);
    try std.testing.expectEqual(@as(u32, 720), child.rect.h);

    try std.testing.expectEqual(@as(i32, 2), child.window_rect.x);
    try std.testing.expectEqual(@as(i32, 2), child.window_rect.y);
    try std.testing.expectEqual(@as(u32, 716), child.window_rect.w);
    try std.testing.expectEqual(@as(u32, 716), child.window_rect.h);
}

test "floating children excluded from tiling" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .hsplit;

    const tiler = try Container.create(alloc, .window);
    const floater = try Container.create(alloc, .window);
    floater.is_floating = true;

    ws.appendChild(tiler);
    ws.appendChild(floater);

    layout.apply(ws, 0, 0);

    // Only one tiling child → monocle behavior: fills entire area
    try std.testing.expectEqual(@as(u32, 720), tiler.rect.w);
    try std.testing.expectEqual(@as(u32, 720), tiler.rect.h);
    try std.testing.expectEqual(@as(i32, 0), tiler.rect.x);

    // Floating child rect should be unchanged (zero default)
    try std.testing.expectEqual(@as(u32, 0), floater.rect.w);
}

test "stacked layout: header scales with children count (16px per window)" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 800, 600);
    defer ws.destroy(alloc);
    ws.layout = .stacked;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 0, 0);

    // 2 children → header = 16 * 2 = 32px; content starts at y=32, h=568
    for ([_]*Container{ c1, c2 }) |child| {
        try std.testing.expectEqual(@as(i32, 32), child.rect.y);
        try std.testing.expectEqual(@as(u32, 568), child.rect.h);
        try std.testing.expectEqual(@as(u32, 800), child.rect.w);
    }
}

test "dirty flag cleared after apply" {
    const alloc = std.testing.allocator;
    const ws = try makeWs(alloc, 720, 720);
    defer ws.destroy(alloc);
    ws.layout = .hsplit;

    const c1 = try Container.create(alloc, .window);
    const c2 = try Container.create(alloc, .window);
    c1.dirty = true;
    c2.dirty = true;
    ws.appendChild(c1);
    ws.appendChild(c2);

    layout.apply(ws, 0, 0);

    try std.testing.expectEqual(false, c1.dirty);
    try std.testing.expectEqual(false, c2.dirty);
}
