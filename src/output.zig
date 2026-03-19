// Output detection — screen/monitor setup via XRandR
const std = @import("std");
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");
const workspace = @import("workspace.zig");

const MAX_OUTPUTS: usize = 8;

/// Output info collected from RandR.
pub const OutputInfo = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn nameSlice(self: *const OutputInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Detect outputs via XRandR and create the initial tree structure.
/// Falls back to single output from root screen if RandR fails or finds no active outputs.
pub fn detectOutputs(
    conn: *xcb.Connection,
    tree_root: *tree.Container,
    allocator: std.mem.Allocator,
) !void {
    const screen = xcb.getScreen(conn) orelse return error.NoScreen;

    // Try RandR detection first
    var outputs: [MAX_OUTPUTS]OutputInfo = undefined;
    const count = queryRandrOutputs(conn, screen.root, &outputs);

    if (count > 0) {
        // Create output containers from RandR data
        var ws_num: i32 = 1;
        for (outputs[0..count]) |*info| {
            const output_con = try tree.Container.create(allocator, .output);
            output_con.rect = .{
                .x = info.x,
                .y = info.y,
                .w = info.w,
                .h = info.h,
            };
            // Store output name in workspace data (reusing WorkspaceData for output_name)
            const name = try allocator.dupe(u8, info.nameSlice());
            output_con.workspace = tree.WorkspaceData{
                .name = name,
                .output_name = name,
            };
            tree_root.appendChild(output_con);

            // Create default workspace under this output
            var ws_name_buf: [16]u8 = undefined;
            const ws_name = std.fmt.bufPrint(&ws_name_buf, "{d}", .{ws_num}) catch "1";
            const ws = try workspace.create(allocator, ws_name, ws_num);
            ws.rect = output_con.rect;
            output_con.appendChild(ws);

            if (ws_num == 1) ws.is_focused = true;
            ws_num += 1;
        }
        std.debug.print("zephwm: detected {d} output(s) via RandR\n", .{count});
    } else {
        // Fallback: single output from root screen
        const output_con = try tree.Container.create(allocator, .output);
        output_con.rect = .{
            .x = 0,
            .y = 0,
            .w = screen.width_in_pixels,
            .h = screen.height_in_pixels,
        };
        const name = try allocator.dupe(u8, "default");
        output_con.workspace = tree.WorkspaceData{
            .name = name,
            .output_name = name,
        };
        tree_root.appendChild(output_con);

        const ws = try workspace.create(allocator, "1", 1);
        ws.rect = output_con.rect;
        output_con.appendChild(ws);
        ws.is_focused = true;
        std.debug.print("zephwm: fallback single output ({d}x{d})\n", .{ screen.width_in_pixels, screen.height_in_pixels });
    }
}

/// Query RandR 1.5 monitors first (supports virtual monitors from xrandr --setmonitor).
/// Falls back to RandR outputs+CRTCs if no monitors found.
fn queryRandrOutputs(conn: *xcb.Connection, root: xcb.Window, out: *[MAX_OUTPUTS]OutputInfo) usize {
    // Try RandR 1.5 Monitors API first (handles virtual monitors + real monitors)
    const count = queryRandrMonitors(conn, root, out);
    if (count > 0) return count;

    // Fallback: RandR outputs + CRTCs (pre-1.5)
    return queryRandrCrtcs(conn, root, out);
}

/// Query RandR 1.5 monitors (includes virtual monitors from xrandr --setmonitor).
fn queryRandrMonitors(conn: *xcb.Connection, root: xcb.Window, out: *[MAX_OUTPUTS]OutputInfo) usize {
    const cookie = xcb.randrGetMonitors(conn, root, 1); // get_active=1
    const reply = xcb.randrGetMonitorsReply(conn, cookie, null) orelse return 0;
    defer std.c.free(reply);

    var iter = xcb.randrGetMonitorsMonitorsIterator(reply);
    var count: usize = 0;

    while (iter.rem > 0) : (xcb.randrMonitorInfoNext(&iter)) {
        if (count >= MAX_OUTPUTS) break;
        const mon = iter.data.*;

        // Skip monitors with zero dimensions
        if (mon.width == 0 or mon.height == 0) continue;

        var info = &out[count];
        info.x = mon.x;
        info.y = mon.y;
        info.w = mon.width;
        info.h = mon.height;

        // Get monitor name from atom
        const name = resolveAtomName(conn, mon.name);
        info.name_len = @intCast(@min(name.len, 64));
        @memcpy(info.name[0..info.name_len], name[0..info.name_len]);

        count += 1;
    }

    return count;
}

/// Resolve an X atom to its string name. Returns "?" on failure.
fn resolveAtomName(conn: *xcb.Connection, atom: xcb.Atom) []const u8 {
    if (atom == 0) return "?";
    const cookie = xcb.c.xcb_get_atom_name(conn, atom);
    const reply = xcb.c.xcb_get_atom_name_reply(conn, cookie, null) orelse return "?";
    defer std.c.free(reply);
    const ptr = xcb.c.xcb_get_atom_name_name(reply);
    const len: usize = @intCast(xcb.c.xcb_get_atom_name_name_length(reply));
    if (ptr == null or len == 0) return "?";
    const data: [*]const u8 = @ptrCast(ptr.?);
    return data[0..len];
}

/// Fallback: query RandR outputs + CRTCs (pre-1.5 method).
fn queryRandrCrtcs(conn: *xcb.Connection, root: xcb.Window, out: *[MAX_OUTPUTS]OutputInfo) usize {
    const res_cookie = xcb.randrGetScreenResources(conn, root);
    const res_reply = xcb.randrGetScreenResourcesReply(conn, res_cookie, null) orelse return 0;
    defer std.c.free(res_reply);

    const output_ids = xcb.randrGetScreenResourcesOutputs(res_reply);
    const num_outputs: usize = @intCast(xcb.randrGetScreenResourcesOutputsLength(res_reply));
    const timestamp = res_reply.config_timestamp;

    var count: usize = 0;
    for (0..num_outputs) |i| {
        if (count >= MAX_OUTPUTS) break;

        const oi_cookie = xcb.randrGetOutputInfo(conn, output_ids[i], timestamp);
        const oi_reply = xcb.randrGetOutputInfoReply(conn, oi_cookie, null) orelse continue;
        defer std.c.free(oi_reply);

        if (oi_reply.connection != xcb.RANDR_CONNECTION_CONNECTED) continue;
        if (oi_reply.crtc == 0) continue;

        const crtc_cookie = xcb.randrGetCrtcInfo(conn, oi_reply.crtc, timestamp);
        const crtc_reply = xcb.randrGetCrtcInfoReply(conn, crtc_cookie, null) orelse continue;
        defer std.c.free(crtc_reply);

        if (crtc_reply.width == 0 or crtc_reply.height == 0) continue;

        const name = xcb.randrGetOutputInfoName(oi_reply);
        var info = &out[count];
        info.x = crtc_reply.x;
        info.y = crtc_reply.y;
        info.w = crtc_reply.width;
        info.h = crtc_reply.height;
        info.name_len = @intCast(@min(name.len, 64));
        @memcpy(info.name[0..info.name_len], name[0..info.name_len]);

        count += 1;
    }

    return count;
}

/// Re-detect outputs and update the tree. Called on RandR screen change events.
/// New outputs get empty workspaces. Removed outputs have their workspaces moved to
/// the first remaining output.
pub fn updateOutputs(
    conn: *xcb.Connection,
    tree_root: *tree.Container,
    allocator: std.mem.Allocator,
) !void {
    const screen = xcb.getScreen(conn) orelse return;

    var new_outputs: [MAX_OUTPUTS]OutputInfo = undefined;
    const new_count = queryRandrOutputs(conn, screen.root, &new_outputs);
    if (new_count == 0) return; // Don't remove all outputs

    // Mark existing outputs as stale
    var out_cur = tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type == .output) out_con.dirty = true;
    }

    // Match new outputs to existing ones by name, update geometry or create new
    for (new_outputs[0..new_count]) |*info| {
        const name = info.nameSlice();
        var found = false;

        out_cur = tree_root.children.first;
        while (out_cur) |out_con| : (out_cur = out_con.next) {
            if (out_con.type != .output) continue;
            const out_name = if (out_con.workspace) |wsd| wsd.output_name else "";
            if (std.mem.eql(u8, out_name, name)) {
                // Update geometry
                out_con.rect = .{ .x = info.x, .y = info.y, .w = info.w, .h = info.h };
                out_con.dirty = false; // not stale
                // Update workspace rects
                var ws_cur = out_con.children.first;
                while (ws_cur) |ws| : (ws_cur = ws.next) {
                    if (ws.type == .workspace) ws.rect = out_con.rect;
                }
                found = true;
                break;
            }
        }

        if (!found) {
            // New output: create container + workspace
            const output_con = try tree.Container.create(allocator, .output);
            output_con.rect = .{ .x = info.x, .y = info.y, .w = info.w, .h = info.h };
            const owned_name = try allocator.dupe(u8, name);
            output_con.workspace = tree.WorkspaceData{
                .name = owned_name,
                .output_name = owned_name,
            };
            output_con.dirty = false;
            tree_root.appendChild(output_con);

            // Find next available workspace number
            var max_ws_num: i32 = 0;
            var scan = tree_root.children.first;
            while (scan) |s| : (scan = s.next) {
                if (s.type != .output) continue;
                var wsc = s.children.first;
                while (wsc) |ws| : (wsc = ws.next) {
                    if (ws.workspace) |wsd| {
                        if (wsd.num) |n| {
                            if (n > max_ws_num) max_ws_num = n;
                        }
                    }
                }
            }
            const ws_num = max_ws_num + 1;
            var ws_name_buf: [16]u8 = undefined;
            const ws_name = std.fmt.bufPrint(&ws_name_buf, "{d}", .{ws_num}) catch "99";
            const ws = try workspace.create(allocator, ws_name, ws_num);
            ws.rect = output_con.rect;
            output_con.appendChild(ws);

            std.debug.print("zephwm: new output: {s} ({d}x{d}+{d}+{d})\n", .{
                name, info.w, info.h, info.x, info.y,
            });
        }
    }

    // Handle removed outputs (still dirty): move workspaces to first remaining output
    const first_output = getFirstActiveOutput(tree_root);
    out_cur = tree_root.children.first;
    while (out_cur) |out_con| {
        const next = out_con.next;
        if (out_con.type == .output and out_con.dirty) {
            const out_name = if (out_con.workspace) |wsd| wsd.output_name else "?";
            std.debug.print("zephwm: output removed: {s}\n", .{out_name});

            // Move all workspaces to first_output
            if (first_output) |target| {
                var ws_cur = out_con.children.first;
                while (ws_cur) |ws| {
                    const ws_next = ws.next;
                    if (ws.type == .workspace) {
                        ws.unlink();
                        ws.rect = target.rect;
                        target.appendChild(ws);
                    }
                    ws_cur = ws_next;
                }
            }

            // Remove the output container
            out_con.unlink();
            out_con.destroy(allocator);
        }
        out_cur = next;
    }
}

fn getFirstActiveOutput(root: *tree.Container) ?*tree.Container {
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type == .output and !child.dirty) return child;
    }
    return null;
}

/// Find an output container by name.
pub fn findByName(root: *tree.Container, name: []const u8) ?*tree.Container {
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type != .output) continue;
        const out_name = if (child.workspace) |wsd| wsd.output_name else "";
        if (std.mem.eql(u8, out_name, name)) return child;
    }
    return null;
}

/// Find the output container to the left/right/up/down of the given output.
pub fn findAdjacent(root: *tree.Container, current: *tree.Container, direction: enum { left, right, up, down }) ?*tree.Container {
    var best: ?*tree.Container = null;
    var best_dist: i64 = std.math.maxInt(i64);

    const cx = current.rect.x + @as(i32, @intCast(current.rect.w / 2));
    const cy = current.rect.y + @as(i32, @intCast(current.rect.h / 2));

    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type != .output or child == current) continue;

        const ox = child.rect.x + @as(i32, @intCast(child.rect.w / 2));
        const oy = child.rect.y + @as(i32, @intCast(child.rect.h / 2));
        const dx = @as(i64, ox) - @as(i64, cx);
        const dy = @as(i64, oy) - @as(i64, cy);

        const valid = switch (direction) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };

        if (valid) {
            const dist = dx * dx + dy * dy;
            if (dist < best_dist) {
                best_dist = dist;
                best = child;
            }
        }
    }

    return best;
}
