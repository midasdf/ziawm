const std = @import("std");
const log = std.log.scoped(.layout);
const tree = @import("tree.zig");
const render = @import("render.zig");

const MAX_TILING_CHILDREN: usize = 64;

/// Apply layout to a container's children. Recursively descends into split_con children.
/// gap: pixel gap between windows
/// border: border width in pixels
pub fn apply(con: *tree.Container, gap: u32, border: u32) void {
    // Collect tiling children (skip floating, cap at MAX_TILING_CHILDREN)
    var tiling: [MAX_TILING_CHILDREN]*tree.Container = undefined;
    var count: usize = 0;

    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        if (!child.is_floating and child.is_fullscreen == .none) {
            if (count < MAX_TILING_CHILDREN) {
                tiling[count] = child;
                count += 1;
            } else {
                log.warn("MAX_TILING_CHILDREN ({d}) exceeded, additional children will not be tiled", .{MAX_TILING_CHILDREN});
                break;
            }
        }
    }

    // Fullscreen children get the parent rect directly (not included in tiling)
    var fs_cur = con.children.first;
    while (fs_cur) |child| : (fs_cur = child.next) {
        if (child.is_fullscreen != .none) {
            child.rect = con.rect;
            child.window_rect = con.rect;
        }
    }

    if (count == 0) return;

    const rect = con.rect;

    switch (count) {
        1 => {
            // Monocle: single child fills entire area, no gap, no border adjustment
            const child = tiling[0];
            child.rect = rect;
            child.window_rect = child.rect;
            adjustForBorderNormal(child);
            child.dirty = false;
            recurse(child, gap, border);
        },
        else => {
            switch (con.layout) {
                .hsplit => applyHsplit(tiling[0..count], rect, gap, border),
                .vsplit => applyVsplit(tiling[0..count], rect, gap, border),
                .tabbed => applyTabbed(tiling[0..count], rect, gap, border),
                .stacked => applyStacked(tiling[0..count], rect, gap, border),
            }
        },
    }
}

fn applyHsplit(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const n = children.len;
    // Total gap space between children (n-1 gaps)
    const total_gap: u32 = gap * @as(u32, @intCast(n - 1));
    const available_w: u32 = if (rect.w > total_gap) rect.w - total_gap else 0;

    // Check if any child has a custom percent
    var has_percent = false;
    for (children) |child| {
        if (child.percent > 0.0) {
            has_percent = true;
            break;
        }
    }

    var x: i32 = rect.x;
    for (children, 0..) |child, i| {
        const w: u32 = blk: {
            if (i == children.len - 1) {
                // Last child gets remainder
                const used: u32 = if (x > rect.x) @intCast(x - rect.x) else 0;
                break :blk if (rect.w > used) rect.w - used else 0;
            }
            if (has_percent and child.percent > 0.0) {
                break :blk @intFromFloat(child.percent * @as(f32, @floatFromInt(available_w)));
            } else {
                // Equal distribution
                break :blk available_w / @as(u32, @intCast(n));
            }
        };

        child.rect = .{ .x = x, .y = rect.y, .w = w, .h = rect.h };
        child.window_rect = child.rect;
        adjustForBorderNormal(child);
        child.dirty = false;
        recurse(child, gap, border);

        x += @as(i32, @intCast(w)) + @as(i32, @intCast(gap));
    }
}

fn applyVsplit(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const n = children.len;
    const total_gap: u32 = gap * @as(u32, @intCast(n - 1));
    const available_h: u32 = if (rect.h > total_gap) rect.h - total_gap else 0;

    var has_percent = false;
    for (children) |child| {
        if (child.percent > 0.0) {
            has_percent = true;
            break;
        }
    }

    var y: i32 = rect.y;
    for (children, 0..) |child, i| {
        const h: u32 = blk: {
            if (i == children.len - 1) {
                const used: u32 = if (y > rect.y) @intCast(y - rect.y) else 0;
                break :blk if (rect.h > used) rect.h - used else 0;
            }
            if (has_percent and child.percent > 0.0) {
                break :blk @intFromFloat(child.percent * @as(f32, @floatFromInt(available_h)));
            } else {
                break :blk available_h / @as(u32, @intCast(n));
            }
        };

        child.rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = h };
        child.window_rect = child.rect;
        adjustForBorderNormal(child);
        child.dirty = false;
        recurse(child, gap, border);

        y += @as(i32, @intCast(h)) + @as(i32, @intCast(gap));
    }
}

fn applyTabbed(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const tbh: u32 = @intCast(render.tab_bar_height);
    const content_y: i32 = rect.y + @as(i32, @intCast(tbh));
    const content_h: u32 = if (rect.h > tbh) rect.h - tbh else 0;
    const child_rect: tree.Rect = .{ .x = rect.x, .y = content_y, .w = rect.w, .h = content_h };

    for (children) |child| {
        child.rect = child_rect;
        child.window_rect = child_rect;
        child.dirty = false;
        recurse(child, gap, border);
    }
}

fn applyStacked(children: []*tree.Container, rect: tree.Rect, gap: u32, border: u32) void {
    const n: u32 = @intCast(children.len);
    const tbh: u32 = @intCast(render.tab_bar_height);
    const header_h: u32 = tbh * n;
    const content_y: i32 = rect.y + @as(i32, @intCast(header_h));
    const content_h: u32 = if (rect.h > header_h) rect.h - header_h else 0;
    const child_rect: tree.Rect = .{ .x = rect.x, .y = content_y, .w = rect.w, .h = content_h };

    for (children) |child| {
        child.rect = child_rect;
        child.window_rect = child_rect;
        child.dirty = false;
        recurse(child, gap, border);
    }
}

/// Adjust window_rect for border normal title bar space.
/// Only applies if the child has border_style == .normal.
fn adjustForBorderNormal(child: *tree.Container) void {
    if (child.border_style != .normal) return;
    if (child.type != .window) return;
    const tbh: u32 = @intCast(render.tab_bar_height);
    if (child.window_rect.h > tbh) {
        child.window_rect.y += @intCast(tbh);
        child.window_rect.h -= tbh;
    }
}

/// Recurse into split_con children.
fn recurse(child: *tree.Container, gap: u32, border: u32) void {
    if (child.type == .split_con) {
        apply(child, gap, border);
    }
}
