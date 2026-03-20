// Event dispatch — X11 event handling
const std = @import("std");
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");
const atoms_mod = @import("atoms.zig");
const config_mod = @import("config.zig");
const command_mod = @import("command.zig");
const workspace = @import("workspace.zig");
const scratchpad = @import("scratchpad.zig");
const criteria = @import("criteria.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");
const output = @import("output.zig");
const ipc = @import("ipc.zig");

pub const WindowMap = std.AutoHashMapUnmanaged(u32, *tree.Container);

/// IPC event subscription bitmask
pub const IPC_EVENT_WORKSPACE: u8 = 0x01;
pub const IPC_EVENT_OUTPUT: u8 = 0x02;
pub const IPC_EVENT_MODE: u8 = 0x04;
pub const IPC_EVENT_WINDOW: u8 = 0x08;
pub const IPC_EVENT_BINDING: u8 = 0x10;

pub const MAX_IPC_SUBS: usize = 16;

pub const EventContext = struct {
    conn: *xcb.Connection,
    root_window: xcb.Window,
    atoms: atoms_mod.Atoms,
    tree_root: *tree.Container,
    allocator: std.mem.Allocator,
    running: *bool,
    current_mode: []const u8,
    focus_follows_mouse: bool,
    config: ?*const config_mod.Config,
    key_symbols: ?*xcb.KeySymbols,
    border_focus_color: u32,
    border_unfocus_color: u32,
    randr_base_event: u8 = 0,
    /// O(1) window ID → container lookup. Updated on map/unmap/destroy.
    window_map: WindowMap = .{},
    /// IPC subscription tracking: fd → event bitmask. -1 = unused slot.
    ipc_sub_fds: *[MAX_IPC_SUBS]std.posix.fd_t = undefined,
    ipc_sub_masks: *[MAX_IPC_SUBS]u8 = undefined,
    /// Previous workspace name for back_and_forth
    prev_workspace: [32]u8 = undefined,
    prev_workspace_len: u8 = 0,
    /// Drag state for floating window move/resize
    drag_window: ?*tree.Container = null,
    drag_button: u8 = 0, // 1=move, 3=resize
    drag_start_x: i16 = 0,
    drag_start_y: i16 = 0,
    drag_orig_x: i32 = 0,
    drag_orig_y: i32 = 0,
    drag_orig_w: u32 = 0,
    drag_orig_h: u32 = 0,
};

/// Dispatch an X11 event to the appropriate handler.
/// Write a JSON-escaped string to writer.
fn jsonEscapeWrite(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => {
                if (ch >= 0x20) try w.writeByte(ch);
            },
        }
    }
}

/// Get the output name for a workspace container.
fn getWorkspaceOutputName(ws: *tree.Container) []const u8 {
    if (ws.parent) |parent| {
        if (parent.type == .output) {
            if (parent.workspace) |wsd| {
                if (wsd.output_name.len > 0) return wsd.output_name;
            }
        }
    }
    return "default";
}

/// Broadcast an IPC event to all subscribed clients.
pub fn broadcastIpcEvent(ctx: *EventContext, event_type: ipc.EventType, payload: []const u8) void {
    const mask_bit: u8 = switch (event_type) {
        .workspace => IPC_EVENT_WORKSPACE,
        .output => IPC_EVENT_OUTPUT,
        .mode => IPC_EVENT_MODE,
        .window => IPC_EVENT_WINDOW,
        .binding => IPC_EVENT_BINDING,
        else => return,
    };

    var send_buf: [4096 + ipc.HEADER_SIZE]u8 = undefined;
    const msg = ipc.encodeEvent(event_type, payload, &send_buf);

    for (0..MAX_IPC_SUBS) |i| {
        if (ctx.ipc_sub_fds[i] != -1 and (ctx.ipc_sub_masks[i] & mask_bit) != 0) {
            _ = std.posix.write(ctx.ipc_sub_fds[i], msg) catch {
                // Client disconnected, will be cleaned up by main loop
            };
        }
    }
}

pub fn handleEvent(ctx: *EventContext, event: *xcb.GenericEvent) void {
    const response_type = event.response_type & 0x7f; // mask out sent-event bit

    switch (response_type) {
        xcb.MAP_REQUEST => handleMapRequest(ctx, @ptrCast(event)),
        xcb.UNMAP_NOTIFY => handleUnmapNotify(ctx, @ptrCast(event)),
        xcb.DESTROY_NOTIFY => handleDestroyNotify(ctx, @ptrCast(event)),
        xcb.KEY_PRESS => handleKeyPress(ctx, @ptrCast(event)),
        xcb.ENTER_NOTIFY => handleEnterNotify(ctx, @ptrCast(event)),
        xcb.CONFIGURE_REQUEST => handleConfigureRequest(ctx, @ptrCast(event)),
        xcb.PROPERTY_NOTIFY => handlePropertyNotify(ctx, @ptrCast(event)),
        xcb.CLIENT_MESSAGE => handleClientMessage(ctx, @ptrCast(event)),
        xcb.BUTTON_PRESS => handleButtonPress(ctx, @ptrCast(event)),
        xcb.c.XCB_BUTTON_RELEASE => handleButtonRelease(ctx),
        xcb.c.XCB_MOTION_NOTIFY => handleMotionNotify(ctx, @ptrCast(event)),
        xcb.c.XCB_EXPOSE => handleExpose(ctx, @ptrCast(@alignCast(event))),
        xcb.FOCUS_IN => handleFocusIn(ctx, @ptrCast(event)),
        xcb.MAPPING_NOTIFY => handleMappingNotify(ctx, event),
        else => {
            // Check for RandR events (dynamic event type based on extension base)
            if (ctx.randr_base_event > 0 and response_type == ctx.randr_base_event) {
                handleRandrScreenChange(ctx);
            }
        },
    }
}

fn handleRandrScreenChange(ctx: *EventContext) void {
    std.debug.print("zephwm: RandR screen change detected, updating outputs\n", .{});
    output.updateOutputs(ctx.conn, ctx.tree_root, ctx.allocator) catch |err| {
        std.debug.print("zephwm: failed to update outputs: {}\n", .{err});
        return;
    };
    broadcastIpcEvent(ctx, .output, "{\"change\":\"unspecified\"}");
    relayoutAndRender(ctx);
    updateAllEwmh(ctx);
}

// --- Tree helpers ---

/// Find a container by X11 window ID using the O(1) HashMap.
fn findContainerByWindow(ctx: *EventContext, window: xcb.Window) ?*tree.Container {
    return ctx.window_map.get(window);
}

/// Register a window in the lookup map.
fn registerWindow(ctx: *EventContext, window: xcb.Window, con: *tree.Container) void {
    ctx.window_map.put(ctx.allocator, window, con) catch {};
}

/// Unregister a window from the lookup map.
fn unregisterWindow(ctx: *EventContext, window: xcb.Window) void {
    _ = ctx.window_map.remove(window);
}

/// Find the deepest focused container (leaf) in a subtree.
fn findFocusedLeaf(root: *tree.Container) ?*tree.Container {
    // Walk down following is_focused children
    var cur = root;
    while (true) {
        // If this is a window or has no children, it's the leaf
        if (cur.type == .window or cur.children.first == null) return cur;
        // Find focused child, or fall back to first child
        var found_focused = false;
        var it = cur.children.first;
        while (it) |child| : (it = child.next) {
            if (child.is_focused) {
                cur = child;
                found_focused = true;
                break;
            }
        }
        if (!found_focused) {
            // No focused child — use first child
            cur = cur.children.first orelse return cur;
        }
    }
}

/// Find the focused workspace by walking down from root.
fn getFocusedWorkspace(root: *tree.Container) ?*tree.Container {
    // Walk: root -> output (focused) -> workspace (focused)
    var cur = root.children.first;
    // Find focused output (or first output)
    var output_con: ?*tree.Container = null;
    while (cur) |child| : (cur = child.next) {
        if (child.type == .output) {
            if (child.is_focused or output_con == null) {
                output_con = child;
                if (child.is_focused) break;
            }
        }
    }
    const out = output_con orelse return null;

    // Find focused workspace under output
    cur = out.children.first;
    var ws: ?*tree.Container = null;
    while (cur) |child| : (cur = child.next) {
        if (child.type == .workspace) {
            if (child.is_focused or ws == null) {
                ws = child;
                if (child.is_focused) break;
            }
        }
    }
    return ws;
}

/// Find the deepest focused container (leaf) from root.
fn getFocusedContainer(root: *tree.Container) ?*tree.Container {
    var con = root;
    while (true) {
        if (con.focusedChild()) |child| {
            con = child;
        } else {
            break;
        }
    }
    if (con == root) return null;
    return con;
}

/// Get the first output container.
fn getFirstOutput(root: *tree.Container) ?*tree.Container {
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type == .output) return child;
    }
    return null;
}

/// Get the output containing the currently focused workspace.
fn getFocusedOutput(root: *tree.Container) ?*tree.Container {
    const ws = getFocusedWorkspace(root) orelse return getFirstOutput(root);
    return ws.parent;
}

/// Get the workspace containing a container (walk up parents).
fn getWorkspaceFor(con: *tree.Container) ?*tree.Container {
    var c: ?*tree.Container = con;
    while (c) |current| {
        if (current.type == .workspace) return current;
        c = current.parent;
    }
    return null;
}

/// Set focus on a container, clearing old focus.
fn setFocus(ctx: *EventContext, con: *tree.Container) void {
    // Clear old focused path: walk from root following is_focused children,
    // clearing each node. O(depth) instead of O(total_nodes).
    clearFocusedPath(ctx.tree_root);

    // Set focus on the container and all its ancestors
    var c: ?*tree.Container = con;
    while (c) |current| {
        current.is_focused = true;
        c = current.parent;
    }

    // Set X11 input focus
    if (con.window) |wd| {
        _ = xcb.setInputFocus(ctx.conn, xcb.INPUT_FOCUS_POINTER_ROOT, wd.id, xcb.CURRENT_TIME);
        updateActiveWindow(ctx, wd.id);
    } else {
        // No window (e.g. focusing a workspace) — clear active window
        updateActiveWindow(ctx, xcb.WINDOW_NONE);
    }
}

/// Clear is_focused along the currently focused path only. O(depth).
fn clearFocusedPath(root: *tree.Container) void {
    var con = root;
    while (true) {
        con.is_focused = false;
        // Find the focused child to continue down
        var found_child: ?*tree.Container = null;
        var cur = con.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_focused) {
                found_child = child;
                break;
            }
        }
        if (found_child) |child| {
            con = child;
        } else {
            break;
        }
    }
}

/// Apply layout and render for a workspace.
fn relayoutAndRender(ctx: *EventContext) void {
    // Apply layout to all workspaces
    const cfg = ctx.config;
    const gap: u32 = if (cfg) |c| c.gap_inner else 0;
    const gap_outer: u32 = if (cfg) |c| c.gap_outer else 0;
    const border: u32 = if (cfg) |c| c.border_px else 1;

    // Reserve space for bar (20px default bar height)
    var bar_height: u32 = 0;
    var bar_top: bool = true;
    if (cfg) |c_cfg| {
        if (c_cfg.bar.status_command.len > 0) {
            bar_height = 20;
            bar_top = !std.mem.eql(u8, c_cfg.bar.position, "bottom");
        }
    }

    var cur = ctx.tree_root.children.first;
    while (cur) |output_con| : (cur = output_con.next) {
        if (output_con.type != .output) continue;

        // Find the visible (focused) workspace for this output
        var visible_ws: ?*tree.Container = null;
        var first_ws_on_out: ?*tree.Container = null;
        {
            var scan = output_con.children.first;
            while (scan) |s| : (scan = s.next) {
                if (s.type != .workspace) continue;
                if (first_ws_on_out == null) first_ws_on_out = s;
                if (s.is_focused) { visible_ws = s; break; }
            }
        }
        const ws_to_layout = visible_ws orelse first_ws_on_out;

        // Only compute layout for the visible workspace (hidden ones don't need geometry)
        if (ws_to_layout) |ws| {
                // Start from output rect, apply bar reservation + outer gaps
                var r = output_con.rect;

                // Reserve bar space
                if (bar_height > 0) {
                    if (bar_top) {
                        r.y += @intCast(bar_height);
                        r.h = if (r.h > bar_height) r.h - bar_height else 0;
                    } else {
                        r.h = if (r.h > bar_height) r.h - bar_height else 0;
                    }
                }

                // Apply outer gaps
                if (gap_outer > 0) {
                    const og: i32 = @intCast(gap_outer);
                    const og2: u32 = gap_outer * 2;
                    r.x += og;
                    r.y += og;
                    r.w = if (r.w > og2) r.w - og2 else 0;
                    r.h = if (r.h > og2) r.h - og2 else 0;
                }

                ws.rect = r;
                layout.apply(ws, gap, border);
            }
    }

    const default_border: u16 = if (ctx.config) |c| @intCast(c.border_px) else 1;
    render.applyTree(ctx.conn, ctx.tree_root, ctx.border_focus_color, ctx.border_unfocus_color, ctx.root_window, default_border);

    // Send synthetic ConfigureNotify to all managed windows (ICCCM requirement).
    // Reparented clients need this to know their actual screen position and size.
    sendConfigureNotifyAll(ctx);
}

// --- EWMH property update helpers ---

/// Collect all managed window IDs and set _NET_CLIENT_LIST on the root window.
pub fn updateClientList(ctx: *EventContext) void {
    // Build client list from window_map (O(n) where n = managed windows, no tree walk)
    var ids: [1024]u32 = undefined;
    var count: usize = 0;
    var iter = ctx.window_map.iterator();
    while (iter.next()) |entry| {
        if (count >= 1024) break;
        const con = entry.value_ptr.*;
        const wd = con.window orelse continue;
        if (entry.key_ptr.* != wd.id) continue; // skip frame_id entries
        ids[count] = entry.key_ptr.*;
        count += 1;
    }

    _ = xcb.changeProperty(
        ctx.conn,
        xcb.PROP_MODE_REPLACE,
        ctx.root_window,
        ctx.atoms.net_client_list,
        xcb.ATOM_WINDOW,
        32,
        @intCast(count),
        if (count > 0) @ptrCast(&ids) else null,
    );
}

/// Set _NET_CURRENT_DESKTOP on the root window.
pub fn updateCurrentDesktop(ctx: *EventContext) void {
    // Find the focused workspace index
    var idx: u32 = 0;
    var found: u32 = 0;
    var out_cur = ctx.tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type != .output) continue;
        var ws_cur = out_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type != .workspace) continue;
            if (ws.is_focused) {
                found = idx;
            }
            idx += 1;
        }
    }

    const val = [_]u32{found};
    _ = xcb.changeProperty(
        ctx.conn,
        xcb.PROP_MODE_REPLACE,
        ctx.root_window,
        ctx.atoms.net_current_desktop,
        xcb.ATOM_CARDINAL,
        32,
        1,
        @ptrCast(&val),
    );
}

/// Set _NET_DESKTOP_NAMES on root window (null-separated UTF8 string list).
pub fn updateDesktopNames(ctx: *EventContext) void {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;

    var out_cur = ctx.tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type != .output) continue;
        var ws_cur = out_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type != .workspace) continue;
            const name = if (ws.workspace) |wsd| wsd.name else "?";
            if (pos + name.len + 1 > buf.len) break;
            @memcpy(buf[pos..][0..name.len], name);
            pos += name.len;
            buf[pos] = 0; // null separator
            pos += 1;
        }
    }

    _ = xcb.changeProperty(
        ctx.conn,
        xcb.PROP_MODE_REPLACE,
        ctx.root_window,
        ctx.atoms.net_desktop_names,
        ctx.atoms.utf8_string,
        8,
        @intCast(pos),
        if (pos > 0) @ptrCast(&buf) else null,
    );
}

/// Set _NET_NUMBER_OF_DESKTOPS on root window.
pub fn updateNumberOfDesktops(ctx: *EventContext) void {
    var count: u32 = 0;
    var out_cur = ctx.tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type != .output) continue;
        var ws_cur = out_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type == .workspace) count += 1;
        }
    }

    const val = [_]u32{count};
    _ = xcb.changeProperty(
        ctx.conn,
        xcb.PROP_MODE_REPLACE,
        ctx.root_window,
        ctx.atoms.net_number_of_desktops,
        xcb.ATOM_CARDINAL,
        32,
        1,
        @ptrCast(&val),
    );
}

/// Set _NET_ACTIVE_WINDOW on root window.
pub fn updateActiveWindow(ctx: *EventContext, window_id: u32) void {
    const val = [_]u32{window_id};
    _ = xcb.changeProperty(
        ctx.conn,
        xcb.PROP_MODE_REPLACE,
        ctx.root_window,
        ctx.atoms.net_active_window,
        xcb.ATOM_WINDOW,
        32,
        1,
        @ptrCast(&val),
    );
}

/// Update all EWMH properties (convenience for after structural changes).
fn updateAllEwmh(ctx: *EventContext) void {
    updateClientList(ctx);
    updateNumberOfDesktops(ctx);
    updateCurrentDesktop(ctx);
    updateDesktopNames(ctx);
}

// --- X11 property helpers ---

/// Read a string property from a window. Returns slice into reply data (freed with reply).
fn getStringProperty(conn: *xcb.Connection, window: xcb.Window, property: xcb.Atom, prop_type: xcb.Atom) ?struct { data: []const u8, reply: *xcb.GetPropertyReply } {
    const cookie = xcb.getProperty(conn, 0, window, property, prop_type, 0, 256);
    const reply = xcb.getPropertyReply(conn, cookie, null) orelse return null;
    const len = xcb.getPropertyValueLength(reply);
    if (len <= 0) {
        std.c.free(reply);
        return null;
    }
    const ptr = xcb.getPropertyValue(reply) orelse {
        std.c.free(reply);
        return null;
    };
    const data: [*]const u8 = @ptrCast(ptr);
    return .{ .data = data[0..@intCast(len)], .reply = reply };
}

/// Read WM_CLASS property (two null-terminated strings: instance, class).
/// Returns allocator-owned copies of the strings.
fn readWmClass(allocator: std.mem.Allocator, conn: *xcb.Connection, window: xcb.Window) struct { instance: []const u8, class: []const u8 } {
    const result = getStringProperty(conn, window, xcb.ATOM_WM_CLASS, xcb.ATOM_STRING) orelse
        return .{ .instance = "", .class = "" };
    defer std.c.free(result.reply);

    const data = result.data;
    // Find first null (end of instance)
    const null_pos = std.mem.indexOfScalar(u8, data, 0) orelse {
        return .{ .instance = allocator.dupe(u8, data) catch "", .class = "" };
    };
    const instance = allocator.dupe(u8, data[0..null_pos]) catch "";
    const rest = data[null_pos + 1 ..];
    // Find second null (end of class) or use rest of data
    const class_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const class = allocator.dupe(u8, rest[0..class_end]) catch {
        // Free instance to avoid leak on class allocation failure
        if (instance.len > 0) allocator.free(instance);
        return .{ .instance = "", .class = "" };
    };
    return .{ .instance = instance, .class = class };
}

/// Read window title (_NET_WM_NAME or WM_NAME).
/// Returns an allocator-owned copy of the string.
fn readTitle(allocator: std.mem.Allocator, conn: *xcb.Connection, window: xcb.Window, atoms: atoms_mod.Atoms) []const u8 {
    // Try _NET_WM_NAME (UTF8) first
    if (getStringProperty(conn, window, atoms.net_wm_name, atoms.utf8_string)) |result| {
        defer std.c.free(result.reply);
        return allocator.dupe(u8, result.data) catch "";
    }
    // Fallback to WM_NAME
    if (getStringProperty(conn, window, xcb.ATOM_WM_NAME, xcb.ATOM_STRING)) |result| {
        defer std.c.free(result.reply);
        return allocator.dupe(u8, result.data) catch "";
    }
    return "";
}

/// Read WM_TRANSIENT_FOR property.
fn readTransientFor(conn: *xcb.Connection, window: xcb.Window) ?u32 {
    const cookie = xcb.getProperty(conn, 0, window, xcb.ATOM_WM_TRANSIENT_FOR, xcb.ATOM_WINDOW, 0, 1);
    const reply = xcb.getPropertyReply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    const len = xcb.getPropertyValueLength(reply);
    if (len < 4) return null;
    const ptr = xcb.getPropertyValue(reply) orelse return null;
    const win_ptr: *const u32 = @ptrCast(@alignCast(ptr));
    const win = win_ptr.*;
    if (win == 0 or win == xcb.WINDOW_NONE) return null;
    return win;
}

/// Read _NET_WM_WINDOW_TYPE and return a type name string ("normal", "dialog",
/// "splash", "notification", "toolbar", "menu", "utility", "dock", or "").
/// Caller owns the returned allocator string (free if len > 0).
fn readWindowTypeName(allocator: std.mem.Allocator, conn: *xcb.Connection, window: xcb.Window, atoms: atoms_mod.Atoms) []const u8 {
    const cookie = xcb.getProperty(conn, 0, window, atoms.net_wm_window_type, xcb.ATOM_ATOM, 0, 32);
    const reply = xcb.getPropertyReply(conn, cookie, null) orelse return "";
    defer std.c.free(reply);
    const len = xcb.getPropertyValueLength(reply);
    if (len <= 0) return "";
    const ptr = xcb.getPropertyValue(reply) orelse return "";
    const atom_ptr: [*]const xcb.Atom = @ptrCast(@alignCast(ptr));
    const count: usize = @intCast(@divTrunc(len, 4));
    if (count == 0) return "";
    // Use the first (highest priority) type atom
    const type_atom = atom_ptr[0];
    const type_name: []const u8 = if (type_atom == atoms.net_wm_window_type_normal) "normal" else if (type_atom == atoms.net_wm_window_type_dialog) "dialog" else if (type_atom == atoms.net_wm_window_type_splash) "splash" else if (type_atom == atoms.net_wm_window_type_notification) "notification" else if (type_atom == atoms.net_wm_window_type_toolbar) "toolbar" else if (type_atom == atoms.net_wm_window_type_menu) "menu" else if (type_atom == atoms.net_wm_window_type_utility) "utility" else if (type_atom == atoms.net_wm_window_type_dock) "dock" else "";
    if (type_name.len == 0) return "";
    return allocator.dupe(u8, type_name) catch "";
}

/// Read WM_WINDOW_ROLE property. Returns allocator-owned string.
fn readWindowRole(allocator: std.mem.Allocator, conn: *xcb.Connection, window: xcb.Window, atoms: atoms_mod.Atoms) []const u8 {
    if (getStringProperty(conn, window, atoms.wm_window_role, xcb.ATOM_STRING)) |result| {
        defer std.c.free(result.reply);
        return allocator.dupe(u8, result.data) catch "";
    }
    return "";
}

/// Check _NET_WM_WINDOW_TYPE for dialog/splash/notification types.
fn shouldFloatByType(conn: *xcb.Connection, window: xcb.Window, atoms: atoms_mod.Atoms) bool {
    const cookie = xcb.getProperty(conn, 0, window, atoms.net_wm_window_type, xcb.ATOM_ATOM, 0, 32);
    const reply = xcb.getPropertyReply(conn, cookie, null) orelse return false;
    defer std.c.free(reply);
    const len = xcb.getPropertyValueLength(reply);
    if (len <= 0) return false;
    const ptr = xcb.getPropertyValue(reply) orelse return false;
    const atom_ptr: [*]const xcb.Atom = @ptrCast(@alignCast(ptr));
    const count: usize = @intCast(@divTrunc(len, 4));
    for (atom_ptr[0..count]) |atom| {
        if (atom == atoms.net_wm_window_type_dialog or
            atom == atoms.net_wm_window_type_splash or
            atom == atoms.net_wm_window_type_notification)
        {
            return true;
        }
    }
    return false;
}

/// Free allocator-owned strings stored in a container's WindowData.
fn freeWindowStrings(allocator: std.mem.Allocator, con: *tree.Container) void {
    if (con.window) |*wd| {
        if (wd.class.len > 0) allocator.free(wd.class);
        if (wd.instance.len > 0) allocator.free(wd.instance);
        if (wd.title.len > 0) allocator.free(wd.title);
        if (wd.window_type.len > 0) allocator.free(wd.window_type);
        wd.class = "";
        wd.instance = "";
        wd.title = "";
        wd.window_type = "";
    }
}

// --- Event handlers ---

fn handleMapRequest(ctx: *EventContext, ev: *xcb.MapRequestEvent) void {
    const window = ev.window;

    // Check if already managed
    if (findContainerByWindow(ctx,window) != null) {
        _ = xcb.mapWindow(ctx.conn, window);
        return;
    }

    // Check override_redirect
    const attr_cookie = xcb.getWindowAttributes(ctx.conn, window);
    if (xcb.getWindowAttributesReply(ctx.conn, attr_cookie, null)) |attr_reply| {
        defer std.c.free(attr_reply);
        if (attr_reply.override_redirect != 0) {
            _ = xcb.mapWindow(ctx.conn, window);
            return;
        }
    }

    // Create new container
    const con = tree.Container.create(ctx.allocator, .window) catch return;

    // Read window properties (allocator-owned copies)
    const wm_class = readWmClass(ctx.allocator, ctx.conn, window);
    const title = readTitle(ctx.allocator, ctx.conn, window, ctx.atoms);
    const transient = readTransientFor(ctx.conn, window);
    const win_type = readWindowTypeName(ctx.allocator, ctx.conn, window, ctx.atoms);
    const win_role = readWindowRole(ctx.allocator, ctx.conn, window, ctx.atoms);
    var should_float = transient != null;
    if (!should_float) {
        should_float = shouldFloatByType(ctx.conn, window, ctx.atoms);
    }

    // Create frame window
    const frame_id = xcb.generateId(ctx.conn);
    const border_w: u16 = if (ctx.config) |cfg| @intCast(cfg.border_px) else 2;
    {
        const frame_values = [_]u32{
            xcb.c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                xcb.c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                xcb.c.XCB_EVENT_MASK_EXPOSURE |
                xcb.c.XCB_EVENT_MASK_ENTER_WINDOW,
        };
        _ = xcb.c.xcb_create_window(
            ctx.conn,
            xcb.c.XCB_COPY_FROM_PARENT,
            frame_id,
            ctx.root_window,
            0, 0, 1, 1,
            border_w,
            xcb.c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            xcb.c.XCB_COPY_FROM_PARENT,
            xcb.c.XCB_CW_EVENT_MASK,
            &frame_values,
        );
    }

    // Add client to save-set for crash recovery (ICCCM requirement)
    _ = xcb.c.xcb_change_save_set(ctx.conn, xcb.c.XCB_SET_MODE_INSERT, window);

    // Reparent client window into frame
    _ = xcb.c.xcb_reparent_window(ctx.conn, window, frame_id, 0, 0);

    con.window = tree.WindowData{
        .id = window,
        .frame_id = frame_id,
        .class = wm_class.class,
        .instance = wm_class.instance,
        .title = title,
        .window_type = win_type,
        .window_role = win_role,
        .transient_for = transient,
        .pending_unmap = 1, // absorb synthetic UnmapNotify from reparent
    };
    con.is_floating = should_float;

    // Register both client and frame in window lookup map
    registerWindow(ctx, window, con);
    registerWindow(ctx, frame_id, con);

    // Determine target workspace
    var target_ws = getFocusedWorkspace(ctx.tree_root);

    // Check assign rules from config
    if (ctx.config) |cfg| {
        for (cfg.assign_rules.items) |rule| {
            if (criteria.matches(&rule.criteria, con)) {
                // Find or create workspace
                if (workspace.findByName(ctx.tree_root, rule.workspace)) |ws| {
                    target_ws = ws;
                } else {
                    // Parse workspace number
                    const num = std.fmt.parseInt(i32, rule.workspace, 10) catch 0;
                    if (workspace.create(ctx.allocator, rule.workspace, num)) |ws| {
                        // Attach to first output
                        if (getFirstOutput(ctx.tree_root)) |out| {
                            out.appendChild(ws);
                            ws.rect = out.rect;
                        }
                        target_ws = ws;
                    } else |_| {}
                }
                break;
            }
        }
    }

    // Attach to the focused container's parent (or the focused split_con itself)
    // This ensures new windows open inside the currently focused split container
    if (target_ws) |ws| {
        // Find where to insert: if focused container is a split_con, insert into it.
        // If focused container is a window, insert as sibling (into its parent).
        const focused = findFocusedLeaf(ws);
        if (focused) |f| {
            if (f.parent) |p| {
                if (p.type == .split_con or p.type == .workspace) {
                    p.appendChild(con);
                } else {
                    ws.appendChild(con);
                }
            } else {
                ws.appendChild(con);
            }
        } else {
            ws.appendChild(con);
        }
    } else {
        ctx.tree_root.appendChild(con);
    }

    // Subscribe to window events
    const event_mask = [_]u32{
        xcb.EVENT_MASK_ENTER_WINDOW |
            xcb.EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.EVENT_MASK_PROPERTY_CHANGE |
            xcb.EVENT_MASK_FOCUS_CHANGE,
    };
    _ = xcb.changeWindowAttributes(ctx.conn, window, xcb.CW_EVENT_MASK, &event_mask);

    // Grab Button1 for click-to-focus
    _ = xcb.grabButton(
        ctx.conn,
        0, // owner_events: false so we get the event
        window,
        xcb.EVENT_MASK_BUTTON_PRESS,
        xcb.GRAB_MODE_ASYNC,
        xcb.GRAB_MODE_ASYNC,
        xcb.WINDOW_NONE,
        xcb.NONE,
        xcb.BUTTON_INDEX_1,
        xcb.MOD_MASK_ANY,
    );

    // Map the frame and client window
    _ = xcb.mapWindow(ctx.conn, frame_id);
    _ = xcb.mapWindow(ctx.conn, window);

    // Check for_window rules from config
    if (ctx.config) |cfg| {
        for (cfg.window_rules.items) |rule| {
            if (criteria.matches(&rule.criteria, con)) {
                // Execute matching command
                if (command_mod.parse(rule.command)) |cmd| {
                    executeCommand(ctx, cmd);
                }
            }
        }
    }

    // Set focus to new window
    setFocus(ctx, con);

    // Update EWMH properties
    updateAllEwmh(ctx);

    // Layout and render
    relayoutAndRender(ctx);

    // Broadcast window new event
    broadcastIpcEvent(ctx, .window, "{\"change\":\"new\"}");
}

fn handleUnmapNotify(ctx: *EventContext, ev: *xcb.UnmapNotifyEvent) void {
    if (ev.event == ev.window) return;

    const con = findContainerByWindow(ctx, ev.window) orelse return;
    const wd = con.window orelse return;
    if (ev.window == wd.frame_id) return; // ignore frame unmap events

    if (con.window) |*wd_ptr| {
        if (wd_ptr.pending_unmap > 0) {
            wd_ptr.pending_unmap -= 1;
            return;
        }
    }

    // Client-initiated unmap — reparent client back to root, destroy frame
    _ = xcb.c.xcb_reparent_window(ctx.conn, wd.id, ctx.root_window, @intCast(con.rect.x), @intCast(con.rect.y));
    _ = xcb.c.xcb_destroy_window(ctx.conn, wd.frame_id);
    unregisterWindow(ctx, wd.frame_id);

    if (con.is_focused) {
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    unregisterWindow(ctx, ev.window);
    con.unlink();
    con.destroy(ctx.allocator);

    updateAllEwmh(ctx);
    relayoutAndRender(ctx);
    broadcastIpcEvent(ctx, .window, "{\"change\":\"close\"}");
}

fn handleDestroyNotify(ctx: *EventContext, ev: *xcb.DestroyNotifyEvent) void {
    if (ev.event == ev.window) return;

    const con = findContainerByWindow(ctx, ev.window) orelse return;

    // Destroy frame window and unregister frame_id
    if (con.window) |wd| {
        if (wd.frame_id != 0) {
            _ = xcb.c.xcb_destroy_window(ctx.conn, wd.frame_id);
            unregisterWindow(ctx, wd.frame_id);
        }
    }

    if (con.is_focused) {
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    unregisterWindow(ctx, ev.window);
    con.unlink();
    con.destroy(ctx.allocator);

    updateAllEwmh(ctx);
    relayoutAndRender(ctx);
}

fn handleKeyPress(ctx: *EventContext, ev: *xcb.KeyPressEvent) void {
    const syms = ctx.key_symbols orelse return;
    const cfg = ctx.config orelse return;

    // Get keysym from keycode
    const keysym = xcb.keySymbolsGetKeysym(syms, ev.detail, 0);
    if (keysym == 0) return;

    // Convert keysym to string for matching against config keybinds
    var keysym_name: [64]u8 = undefined;
    const name = keysymToName(keysym, &keysym_name) orelse return;

    // Build modifier bitmask from event state
    var mods: u8 = 0;
    if (ev.state & xcb.MOD_MASK_4 != 0) mods |= config_mod.MOD_SUPER;
    if (ev.state & xcb.MOD_MASK_SHIFT != 0) mods |= config_mod.MOD_SHIFT;
    if (ev.state & xcb.MOD_MASK_CONTROL != 0) mods |= config_mod.MOD_CTRL;
    if (ev.state & xcb.MOD_MASK_1 != 0) mods |= config_mod.MOD_ALT;

    // Look up matching keybind
    for (cfg.keybinds.items) |kb| {
        if (kb.modifiers == mods and
            std.mem.eql(u8, kb.mode, ctx.current_mode) and
            std.ascii.eqlIgnoreCase(kb.key, name))
        {
            // Broadcast binding event before executing the command
            {
                var bind_buf: [512]u8 = undefined;
                var bind_fbs = std.io.fixedBufferStream(&bind_buf);
                const bind_w = bind_fbs.writer();
                bind_w.writeAll("{\"change\":\"run\",\"binding\":{\"command\":\"") catch {};
                jsonEscapeWrite(bind_w, kb.command) catch {};
                bind_w.writeAll("\",\"event_state_mask\":[") catch {};
                var first_mod = true;
                if (ev.state & xcb.MOD_MASK_4 != 0) {
                    if (!first_mod) bind_w.writeAll(",") catch {};
                    bind_w.writeAll("\"Mod4\"") catch {};
                    first_mod = false;
                }
                if (ev.state & xcb.MOD_MASK_SHIFT != 0) {
                    if (!first_mod) bind_w.writeAll(",") catch {};
                    bind_w.writeAll("\"Shift\"") catch {};
                    first_mod = false;
                }
                if (ev.state & xcb.MOD_MASK_CONTROL != 0) {
                    if (!first_mod) bind_w.writeAll(",") catch {};
                    bind_w.writeAll("\"Control\"") catch {};
                    first_mod = false;
                }
                if (ev.state & xcb.MOD_MASK_1 != 0) {
                    if (!first_mod) bind_w.writeAll(",") catch {};
                    bind_w.writeAll("\"Mod1\"") catch {};
                    first_mod = false;
                }
                bind_w.writeAll("],\"input_type\":\"keyboard\",\"symbol\":\"") catch {};
                jsonEscapeWrite(bind_w, name) catch {};
                bind_w.writeAll("\"}}") catch {};
                const bind_json = bind_fbs.getWritten();
                if (bind_json.len > 0 and bind_json.len < bind_buf.len) broadcastIpcEvent(ctx, .binding, bind_json);
            }
            // Parse and execute command
            if (command_mod.parse(kb.command)) |cmd| {
                executeCommand(ctx, cmd);
            }
            return;
        }
    }
}

/// Convert a keysym value to its name string using xkb_keysym_get_name.
/// buf must be at least 64 bytes. Returns null if keysym is unknown.
fn keysymToName(keysym: xcb.Keysym, buf: *[64]u8) ?[]const u8 {
    const n = xcb.xkb_keysym_get_name(keysym, buf, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

fn handleEnterNotify(ctx: *EventContext, ev: *xcb.EnterNotifyEvent) void {
    if (!ctx.focus_follows_mouse) return;

    const con = findContainerByWindow(ctx,ev.event) orelse return;
    setFocus(ctx, con);

}

fn handleButtonPress(ctx: *EventContext, ev: *xcb.ButtonPressEvent) void {
    const con = findContainerByWindow(ctx, ev.event) orelse return;
    setFocus(ctx, con);

    // Check for floating_modifier (Mod4) + button for drag move/resize
    if (ev.state & xcb.MOD_MASK_4 != 0) {
        if (con.is_floating and (ev.detail == 1 or ev.detail == 3)) {
            // Start drag: Button1=move, Button3=resize
            ctx.drag_window = con;
            ctx.drag_button = ev.detail;
            ctx.drag_start_x = ev.root_x;
            ctx.drag_start_y = ev.root_y;
            ctx.drag_orig_x = con.rect.x;
            ctx.drag_orig_y = con.rect.y;
            ctx.drag_orig_w = con.rect.w;
            ctx.drag_orig_h = con.rect.h;

            // Grab pointer for drag
            _ = xcb.c.xcb_grab_pointer(
                ctx.conn,
                0,
                ctx.root_window,
                xcb.c.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.c.XCB_EVENT_MASK_POINTER_MOTION,
                xcb.c.XCB_GRAB_MODE_ASYNC,
                xcb.c.XCB_GRAB_MODE_ASYNC,
                xcb.c.XCB_WINDOW_NONE,
                xcb.c.XCB_CURSOR_NONE,
                xcb.c.XCB_CURRENT_TIME,
            );
            return;
        }

        // Tiling window: Mod4 + right-click drag for resize
        if (!con.is_floating and ev.detail == 3) {
            ctx.drag_window = con;
            ctx.drag_button = 3;
            ctx.drag_start_x = ev.root_x;
            ctx.drag_start_y = ev.root_y;
            ctx.drag_orig_w = 0; // sentinel: tiling mode
            _ = xcb.c.xcb_grab_pointer(
                ctx.conn, 0, ctx.root_window,
                xcb.c.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.c.XCB_EVENT_MASK_POINTER_MOTION,
                xcb.c.XCB_GRAB_MODE_ASYNC, xcb.c.XCB_GRAB_MODE_ASYNC,
                xcb.c.XCB_WINDOW_NONE, xcb.c.XCB_CURSOR_NONE, xcb.c.XCB_CURRENT_TIME,
            );
            return;
        }
    }

    // Allow the click to pass through to the application
    _ = xcb.c.xcb_allow_events(ctx.conn, xcb.c.XCB_ALLOW_REPLAY_POINTER, xcb.CURRENT_TIME);
}

fn handleMotionNotify(ctx: *EventContext, ev: *xcb.c.xcb_motion_notify_event_t) void {
    const con = ctx.drag_window orelse return;

    const dx: i32 = @as(i32, ev.root_x) - @as(i32, ctx.drag_start_x);
    const dy: i32 = @as(i32, ev.root_y) - @as(i32, ctx.drag_start_y);

    if (ctx.drag_button == 1 and con.is_floating) {
        // Floating move
        con.rect.x = ctx.drag_orig_x + dx;
        con.rect.y = ctx.drag_orig_y + dy;
        con.window_rect = con.rect;
    } else if (ctx.drag_button == 3 and con.is_floating) {
        // Floating resize
        const new_w = @as(i32, @intCast(ctx.drag_orig_w)) + dx;
        const new_h = @as(i32, @intCast(ctx.drag_orig_h)) + dy;
        con.rect.w = @intCast(@max(new_w, 50));
        con.rect.h = @intCast(@max(new_h, 50));
        con.window_rect = con.rect;
    } else if (ctx.drag_button == 3 and !con.is_floating) {
        // Tiling resize via percent adjustment (throttled to avoid excessive relayout)
        const threshold: i32 = 10; // minimum pixel delta to trigger resize
        if (dx > threshold or dx < -threshold or dy > threshold or dy < -threshold) {
            if (@abs(dx) > @abs(dy)) {
                // Horizontal resize
                if (dx > 0) {
                    executeResizeInternal(ctx, con, "grow", "width", @intCast(@abs(dx)));
                } else {
                    executeResizeInternal(ctx, con, "shrink", "width", @intCast(@abs(dx)));
                }
            } else {
                // Vertical resize
                if (dy > 0) {
                    executeResizeInternal(ctx, con, "grow", "height", @intCast(@abs(dy)));
                } else {
                    executeResizeInternal(ctx, con, "shrink", "height", @intCast(@abs(dy)));
                }
            }
            ctx.drag_start_x = ev.root_x;
            ctx.drag_start_y = ev.root_y;
        }
        return;
    }

    // Apply immediately for smooth floating dragging
    if (con.window) |wd| {
        if (wd.frame_id != 0) {
            // Configure frame with position/size
            const frame_values = [_]u32{
                @bitCast(con.rect.x),
                @bitCast(con.rect.y),
                con.rect.w,
                con.rect.h,
            };
            const frame_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
                xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
            _ = xcb.configureWindow(ctx.conn, wd.frame_id, frame_mask, &frame_values);

            // Configure client at (0,0) inside frame
            const client_values = [_]u32{ 0, 0, con.rect.w, con.rect.h };
            const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
                xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
            _ = xcb.configureWindow(ctx.conn, wd.id, client_mask, &client_values);
        } else {
            const values = [_]u32{
                @bitCast(con.rect.x),
                @bitCast(con.rect.y),
                con.rect.w,
                con.rect.h,
            };
            const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
                xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
            _ = xcb.configureWindow(ctx.conn, wd.id, mask, &values);
        }
    }
}

fn handleButtonRelease(ctx: *EventContext) void {
    if (ctx.drag_window != null) {
        ctx.drag_window = null;
        ctx.drag_button = 0;
        _ = xcb.c.xcb_ungrab_pointer(ctx.conn, xcb.c.XCB_CURRENT_TIME);
    }
}

fn handleConfigureRequest(ctx: *EventContext, ev: *xcb.ConfigureRequestEvent) void {
    const con = findContainerByWindow(ctx, ev.window);

    const should_forward = if (con) |c| c.is_floating else true;
    if (con) |c| {
        if (!c.is_floating) {
            // Tiled: send ConfigureNotify with current geometry
            sendConfigureNotify(ctx, c);
        }
    }
    if (should_forward) {
        // Check if this is a managed window with a frame
        const has_frame = if (con) |c| (if (c.window) |wd| wd.frame_id != 0 else false) else false;

        if (has_frame) {
            // Managed floating window: configure frame with requested geometry,
            // then configure client at (0,0) inside it.
            const c = con.?;
            const wd = c.window.?;

            // Build frame configure values from request
            var frame_values: [7]u32 = undefined;
            var fi: usize = 0;
            var frame_mask: u16 = 0;

            // Track requested w/h for client configure
            var req_w: u32 = c.rect.w;
            var req_h: u32 = c.rect.h;

            if (ev.value_mask & xcb.CONFIG_WINDOW_X != 0) {
                frame_values[fi] = @bitCast(@as(i32, ev.x));
                frame_mask |= xcb.CONFIG_WINDOW_X;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_Y != 0) {
                frame_values[fi] = @bitCast(@as(i32, ev.y));
                frame_mask |= xcb.CONFIG_WINDOW_Y;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_WIDTH != 0) {
                req_w = @intCast(ev.width);
                frame_values[fi] = req_w;
                frame_mask |= xcb.CONFIG_WINDOW_WIDTH;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_HEIGHT != 0) {
                req_h = @intCast(ev.height);
                frame_values[fi] = req_h;
                frame_mask |= xcb.CONFIG_WINDOW_HEIGHT;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_BORDER_WIDTH != 0) {
                frame_values[fi] = @intCast(ev.border_width);
                frame_mask |= xcb.CONFIG_WINDOW_BORDER_WIDTH;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_SIBLING != 0) {
                frame_values[fi] = ev.sibling;
                frame_mask |= xcb.CONFIG_WINDOW_SIBLING;
                fi += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_STACK_MODE != 0) {
                frame_values[fi] = @intCast(ev.stack_mode);
                frame_mask |= xcb.CONFIG_WINDOW_STACK_MODE;
                fi += 1;
            }

            if (frame_mask != 0) {
                _ = xcb.configureWindow(ctx.conn, wd.frame_id, frame_mask, &frame_values);
            }

            // Configure client at (0,0) inside frame with requested size
            if (ev.value_mask & (xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT) != 0) {
                const client_values = [_]u32{ 0, 0, req_w, req_h };
                const client_mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
                    xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT;
                _ = xcb.configureWindow(ctx.conn, wd.id, client_mask, &client_values);
            }
        } else {
            // Unmanaged window: forward directly as before
            var values: [7]u32 = undefined;
            var i: usize = 0;
            var mask: u16 = 0;

            if (ev.value_mask & xcb.CONFIG_WINDOW_X != 0) {
                values[i] = @bitCast(@as(i32, ev.x));
                mask |= xcb.CONFIG_WINDOW_X;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_Y != 0) {
                values[i] = @bitCast(@as(i32, ev.y));
                mask |= xcb.CONFIG_WINDOW_Y;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_WIDTH != 0) {
                values[i] = @intCast(ev.width);
                mask |= xcb.CONFIG_WINDOW_WIDTH;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_HEIGHT != 0) {
                values[i] = @intCast(ev.height);
                mask |= xcb.CONFIG_WINDOW_HEIGHT;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_BORDER_WIDTH != 0) {
                values[i] = @intCast(ev.border_width);
                mask |= xcb.CONFIG_WINDOW_BORDER_WIDTH;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_SIBLING != 0) {
                values[i] = ev.sibling;
                mask |= xcb.CONFIG_WINDOW_SIBLING;
                i += 1;
            }
            if (ev.value_mask & xcb.CONFIG_WINDOW_STACK_MODE != 0) {
                values[i] = @intCast(ev.stack_mode);
                mask |= xcb.CONFIG_WINDOW_STACK_MODE;
                i += 1;
            }

            if (mask != 0) {
                _ = xcb.configureWindow(ctx.conn, ev.window, mask, &values);
            }
        }
    }
}

/// Send a synthetic ConfigureNotify to tell a client window its current geometry.
/// Uses screen-absolute coordinates accounting for frame border offset.
fn sendConfigureNotify(ctx: *EventContext, con: *tree.Container) void {
    const wd = con.window orelse return;
    const r = con.window_rect;

    // Compute effective border for screen-absolute position
    const eb: i32 = blk: {
        if (con.border_style == .none) break :blk 0;
        if (con.border_width_override >= 0) break :blk @intCast(con.border_width_override);
        if (ctx.config) |c| break :blk @intCast(c.border_px);
        break :blk 1;
    };

    // Client's screen position = frame position + border + client offset within frame
    // For tiled: x = rect.x + border, y = rect.y + border (no title offset here,
    // the rect already accounts for layout positioning)
    const screen_x: i16 = @intCast(r.x + eb);
    const screen_y: i16 = @intCast(r.y + eb);

    // Client size = frame content size - title offset
    // applyWindow sets these, but we compute from layout rect for the synthetic event
    const b2: u32 = @as(u32, @intCast(eb)) * 2;
    const client_w: u16 = @intCast(if (r.w > b2) r.w - b2 else 1);
    const client_h: u16 = @intCast(if (r.h > b2) r.h - b2 else 1);

    var event_data: xcb.c.xcb_configure_notify_event_t = std.mem.zeroes(xcb.c.xcb_configure_notify_event_t);
    event_data.response_type = xcb.CONFIGURE_NOTIFY;
    event_data.event = wd.id;
    event_data.window = wd.id;
    event_data.x = screen_x;
    event_data.y = screen_y;
    event_data.width = client_w;
    event_data.height = client_h;
    event_data.border_width = 0;
    event_data.above_sibling = xcb.WINDOW_NONE;
    event_data.override_redirect = 0;

    _ = xcb.sendEvent(ctx.conn, 0, wd.id, xcb.EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&event_data));
}

/// Send ConfigureNotify to all managed windows after relayout.
fn sendConfigureNotifyAll(ctx: *EventContext) void {
    var it = ctx.window_map.iterator();
    while (it.next()) |entry| {
        const con = entry.value_ptr.*;
        if (con.window) |wd| {
            // Only process client window entries (skip frame_id entries)
            if (entry.key_ptr.* == wd.id) {
                sendConfigureNotify(ctx, con);
            }
        }
    }
}

fn handlePropertyNotify(ctx: *EventContext, ev: *xcb.PropertyNotifyEvent) void {
    const con = findContainerByWindow(ctx,ev.window) orelse return;

    // Update title
    if (ev.atom == ctx.atoms.net_wm_name or ev.atom == xcb.ATOM_WM_NAME) {
        const title = readTitle(ctx.allocator, ctx.conn, ev.window, ctx.atoms);
        if (con.window) |*wd| {
            // Free old title
            if (wd.title.len > 0) ctx.allocator.free(wd.title);
            wd.title = title;
        } else {
            // No window data to store into; free the new allocation
            if (title.len > 0) ctx.allocator.free(title);
        }
        // Redraw title bars if window is inside a tabbed/stacked container
        if (con.parent) |parent| {
            if (parent.layout == .tabbed or parent.layout == .stacked) {
                render.redrawTitleBarsForContainer(ctx.conn, parent);
            }
        }
        // Redraw border normal title bar
        if (con.border_style == .normal and con.type == .window) {
            const suppress = if (con.parent) |parent|
                (parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1
            else
                false;
            if (!suppress) {
                render.drawNormalTitleBar(ctx.conn, con);
                _ = xcb.flush(ctx.conn);
            }
        }
    }

    // Update urgency from WM_HINTS
    if (ev.atom == xcb.ATOM_WM_HINTS) {
        const cookie = xcb.getProperty(ctx.conn, 0, ev.window, xcb.ATOM_WM_HINTS, xcb.ATOM_WM_HINTS, 0, 9);
        if (xcb.getPropertyReply(ctx.conn, cookie, null)) |reply| {
            defer std.c.free(reply);
            const len = xcb.getPropertyValueLength(reply);
            if (len >= 4) {
                const ptr = xcb.getPropertyValue(reply) orelse return;
                const flags: *const u32 = @ptrCast(@alignCast(ptr));
                const urgency_flag: u32 = 256; // XUrgencyHint
                if (con.window) |*wd| {
                    wd.urgency = (flags.* & urgency_flag) != 0;
                    // Propagate urgency to workspace
                    if (wd.urgency) {
                        var ws_con = con.parent;
                        while (ws_con) |p| : (ws_con = p.parent) {
                            if (p.type == .workspace) {
                                if (p.workspace) |*wsd| {
                                    // Only set urgent if workspace is not focused
                                    if (!p.is_focused) {
                                        wsd.urgent = true;
                                        broadcastIpcEvent(ctx, .workspace, "{\"change\":\"urgent\"}");
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

fn handleClientMessage(ctx: *EventContext, ev: *xcb.ClientMessageEvent) void {
    // _NET_ACTIVE_WINDOW: focus request
    if (ev.type == ctx.atoms.net_active_window) {
        const con = findContainerByWindow(ctx,ev.window) orelse return;
        setFocus(ctx, con);
        relayoutAndRender(ctx);
        return;
    }

    // _NET_CLOSE_WINDOW: close request
    if (ev.type == ctx.atoms.net_close_window) {
        const con = findContainerByWindow(ctx,ev.window) orelse return;
        killWindow(ctx, con, false);
        return;
    }

    // _NET_WM_STATE: fullscreen toggle etc.
    if (ev.type == ctx.atoms.net_wm_state) {
        const con = findContainerByWindow(ctx,ev.window) orelse return;
        const action = ev.data.data32[0];
        const prop = ev.data.data32[1];

        if (prop == ctx.atoms.net_wm_state_fullscreen) {
            const is_fs = con.is_fullscreen != .none;
            switch (action) {
                0 => con.is_fullscreen = .none, // _NET_WM_STATE_REMOVE
                1 => con.is_fullscreen = .window, // _NET_WM_STATE_ADD
                2 => con.is_fullscreen = if (is_fs) .none else .window, // _NET_WM_STATE_TOGGLE
                else => {},
            }
            relayoutAndRender(ctx);
        }
    }
}

fn handleFocusIn(ctx: *EventContext, ev: *xcb.FocusInEvent) void {
    // If an unmanaged window stole focus, re-set focus to our tracked focused window.
    // Only handle NotifyNormal and NotifyWhileGrabbed to avoid loops.
    if (ev.mode != 0 and ev.mode != 1) return; // NotifyNormal=0, NotifyWhileGrabbed=1

    const window = ev.event;

    // If this window is managed by us, nothing to do
    if (findContainerByWindow(ctx,window) != null) return;

    // An unmanaged window got focus — re-set focus to our focused container
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    if (focused.window) |wd| {
        _ = xcb.setInputFocus(ctx.conn, xcb.INPUT_FOCUS_POINTER_ROOT, wd.id, xcb.CURRENT_TIME);
    }
}

fn handleMappingNotify(ctx: *EventContext, _: *xcb.GenericEvent) void {
    // Refresh key mappings
    if (ctx.key_symbols) |syms| {
        xcb.keySymbolsFree(syms);
    }
    ctx.key_symbols = xcb.keySymbolsAlloc(ctx.conn);

    // Re-grab keys
    if (ctx.config) |cfg| {
        grabKeys(ctx, cfg);
    }
}

fn handleExpose(ctx: *EventContext, ev: *xcb.c.xcb_expose_event_t) void {
    if (ev.count != 0) return;
    const con = findContainerByWindow(ctx, ev.window) orelse return;
    // Redraw tabbed/stacked parent headers
    if (con.parent) |parent| {
        if (parent.layout == .tabbed or parent.layout == .stacked) {
            render.redrawTitleBarsForContainer(ctx.conn, parent);
        }
    }
    // Redraw border normal title bar on this window
    if (con.border_style == .normal and con.type == .window) {
        // Skip if inside tabbed/stacked with >1 children (parent headers take precedence)
        const suppress = if (con.parent) |parent|
            (parent.layout == .tabbed or parent.layout == .stacked) and parent.children.len() > 1
        else
            false;
        if (!suppress) {
            render.drawNormalTitleBar(ctx.conn, con);
            _ = xcb.flush(ctx.conn);
        }
    }
}

// --- Command execution ---

pub fn executeCommand(ctx: *EventContext, cmd: command_mod.Command) void {
    switch (cmd.type) {
        .split => executeSplit(ctx, cmd),
        .focus => executeFocus(ctx, cmd),
        .move => executeMove(ctx, cmd),
        .layout_cmd => executeLayout(ctx, cmd),
        .workspace => executeWorkspace(ctx, cmd),
        .move_workspace => executeMoveWorkspace(ctx, cmd),
        .kill => executeKill(ctx, cmd),
        .exec => executeExec(cmd),
        .floating => executeFloating(ctx),
        .border => executeBorder(ctx, cmd),
        .fullscreen => executeFullscreen(ctx),
        .mark => executeMark(ctx, cmd),
        .unmark => executeUnmark(ctx, cmd),
        .scratchpad => executeScratchpad(ctx, cmd),
        .mode => executeMode(ctx, cmd),
        .reload => executeReload(ctx),
        .restart => executeRestart(ctx),
        .exit => {
            ctx.running.* = false;
        },
        .resize => executeResize(ctx, cmd),
        .focus_output => executeFocusOutput(ctx, cmd),
        .move_workspace_to_output => executeMoveWorkspaceToOutput(ctx, cmd),
        .nop => {},
        .sticky => executeSticky(ctx, cmd),
    }
}

fn executeSplit(ctx: *EventContext, cmd: command_mod.Command) void {
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    const parent = focused.parent orelse return;
    const arg = cmd.args[0] orelse return;

    const new_layout: tree.Layout = if (std.mem.eql(u8, arg, "h") or std.mem.eql(u8, arg, "horizontal"))
        .hsplit
    else if (std.mem.eql(u8, arg, "v") or std.mem.eql(u8, arg, "vertical"))
        .vsplit
    else if (std.mem.eql(u8, arg, "toggle"))
        (if (parent.layout == .hsplit) tree.Layout.vsplit else tree.Layout.hsplit)
    else
        return;

    // If focused is a window, wrap it in a new split_con with the requested layout.
    // This is how i3 works: split creates an intermediate container around the focused window.
    if (focused.type == .window) {
        const split_con = tree.Container.create(ctx.allocator, .split_con) catch return;
        split_con.layout = new_layout;
        split_con.percent = focused.percent;

        // Replace focused in parent with split_con (same position)
        parent.insertBefore(split_con, focused);
        focused.unlink();

        // Move focused under the new split_con
        split_con.appendChild(focused);
        focused.percent = 0.0; // single child, no percent needed

        setFocus(ctx, focused);
    } else {
        // If focused is already a container (split_con/workspace), just change its layout
        focused.layout = new_layout;
    }
    relayoutAndRender(ctx);
}

fn executeFocus(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;

    if (std.mem.eql(u8, arg, "parent")) {
        const focused = getFocusedContainer(ctx.tree_root) orelse return;
        if (focused.parent) |parent| {
            if (parent.type != .root) {
                setFocus(ctx, parent);
            }
        }
        return;
    }

    if (std.mem.eql(u8, arg, "child")) {
        const focused = getFocusedContainer(ctx.tree_root) orelse return;
        if (focused.children.first) |child| {
            setFocus(ctx, child);
        }
        return;
    }

    // Directional focus: left/right/up/down
    // The direction must match the parent's split orientation to navigate siblings.
    // If it doesn't match, walk up the tree to find a container with matching orientation.
    const focused = getFocusedContainer(ctx.tree_root) orelse return;

    if (std.mem.eql(u8, arg, "left") or std.mem.eql(u8, arg, "prev")) {
        focusInDirection(ctx, focused, .hsplit, .prev);
    } else if (std.mem.eql(u8, arg, "right") or std.mem.eql(u8, arg, "next")) {
        focusInDirection(ctx, focused, .hsplit, .next);
    } else if (std.mem.eql(u8, arg, "up")) {
        focusInDirection(ctx, focused, .vsplit, .prev);
    } else if (std.mem.eql(u8, arg, "down")) {
        focusInDirection(ctx, focused, .vsplit, .next);
    }

}

fn getDeepestChild(con: *tree.Container) *tree.Container {
    var c = con;
    while (c.focusedChild()) |child| {
        c = child;
    }
    // If no focused child, try first child
    if (c == con and c.children.first != null) {
        c = c.children.first.?;
        while (c.children.first) |child| {
            c = child;
        }
    }
    return c;
}

const Direction = enum { prev, next };

/// Navigate focus in a spatial direction. `orientation` is the layout that matches
/// the direction (hsplit for left/right, vsplit for up/down). `dir` is prev/next
/// within that orientation.
fn focusInDirection(ctx: *EventContext, focused: *tree.Container, orientation: tree.Layout, dir: Direction) void {
    // Walk up from focused to find a parent with matching orientation
    var con: *tree.Container = focused;
    while (con.parent) |parent| {
        if (parent.type == .root or parent.type == .output) break;
        if (parent.layout == orientation) {
            // Found matching orientation — navigate sibling
            const sibling = switch (dir) {
                .prev => con.prev,
                .next => con.next,
            };
            if (sibling) |sib| {
                setFocus(ctx, getDeepestChild(sib));
                return;
            }
            // No sibling in that direction at this level — keep walking up
        }
        con = parent;
    }
}

fn executeMove(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;

    if (std.mem.eql(u8, arg, "left")) {
        moveInDirection(ctx, focused, .hsplit, .prev);
    } else if (std.mem.eql(u8, arg, "right")) {
        moveInDirection(ctx, focused, .hsplit, .next);
    } else if (std.mem.eql(u8, arg, "up")) {
        moveInDirection(ctx, focused, .vsplit, .prev);
    } else if (std.mem.eql(u8, arg, "down")) {
        moveInDirection(ctx, focused, .vsplit, .next);
    }
    relayoutAndRender(ctx);
}

/// Move a container in a spatial direction. If the parent's orientation matches,
/// swap with sibling. If not, walk up to find a matching-orientation ancestor
/// and reparent into the adjacent sibling there.
fn moveInDirection(ctx: *EventContext, focused: *tree.Container, orientation: tree.Layout, dir: Direction) void {
    var con: *tree.Container = focused;
    while (con.parent) |parent| {
        if (parent.type == .root or parent.type == .output) break;
        if (parent.layout == orientation) {
            const sibling = switch (dir) {
                .prev => con.prev,
                .next => con.next,
            };
            if (sibling) |sib| {
                if (con == focused) {
                    // Simple case: focused is a direct child of the matching parent
                    // Just swap positions within the same parent
                    focused.unlink();
                    switch (dir) {
                        .prev => {
                            parent.insertBefore(focused, sib);
                        },
                        .next => {
                            if (sib.next) |after| {
                                parent.insertBefore(focused, after);
                            } else {
                                parent.appendChild(focused);
                            }
                        },
                    }
                } else {
                    // Complex case: focused is nested deeper. Remove from current
                    // parent and reparent into the ancestor's child list.
                    const old_parent = focused.parent;
                    focused.unlink();
                    switch (dir) {
                        .prev => {
                            parent.insertBefore(focused, sib);
                        },
                        .next => {
                            if (sib.next) |after| {
                                parent.insertBefore(focused, after);
                            } else {
                                parent.appendChild(focused);
                            }
                        },
                    }
                    // Clean up empty split containers left behind
                    cleanupEmptySplitCon(old_parent, ctx.allocator);
                }
                return;
            }
            // No sibling at this level — keep walking up
        }
        con = parent;
    }
}

/// Remove empty split_con containers from the tree.
/// If a split_con has 0 children, destroy it. If it has 1 child, unwrap it
/// (promote the child to the split_con's position).
fn cleanupEmptySplitCon(maybe_con: ?*tree.Container, allocator: std.mem.Allocator) void {
    var con = maybe_con orelse return;
    while (con.type == .split_con) {
        const par = con.parent orelse break;
        const count = con.children.len();
        if (count == 0) {
            con.unlink();
            con.destroy(allocator);
            break;
        } else if (count == 1) {
            // Single child: unwrap (promote child to this position)
            const child = con.children.first orelse break;
            child.unlink();
            child.percent = con.percent;
            par.insertBefore(child, con);
            con.unlink();
            con.destroy(allocator);
            // Continue checking the parent in case it's also now single-child
            con = par;
        } else {
            break;
        }
    }
}

fn executeLayout(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    // Change the layout of the parent (the container holding windows)
    const target = if (focused.type == .window) focused.parent orelse return else focused;

    if (std.mem.eql(u8, arg, "tabbed")) {
        target.layout = .tabbed;
    } else if (std.mem.eql(u8, arg, "stacking") or std.mem.eql(u8, arg, "stacked")) {
        target.layout = .stacked;
    } else if (std.mem.eql(u8, arg, "splith")) {
        target.layout = .hsplit;
    } else if (std.mem.eql(u8, arg, "splitv")) {
        target.layout = .vsplit;
    } else if (std.mem.eql(u8, arg, "toggle split") or std.mem.eql(u8, arg, "toggle")) {
        target.layout = switch (target.layout) {
            .hsplit => .vsplit,
            .vsplit => .hsplit,
            .tabbed => .hsplit,
            .stacked => .hsplit,
        };
    }
    relayoutAndRender(ctx);
}

fn executeWorkspace(ctx: *EventContext, cmd: command_mod.Command) void {
    const name = cmd.args[0] orelse return;

    // Find or create workspace
    // Try by name first, then by number (for "workspace number N" commands)
    var ws = workspace.findByName(ctx.tree_root, name);
    if (ws == null) {
        const num = std.fmt.parseInt(i32, name, 10) catch 0;
        if (num != 0) {
            ws = workspace.findByNum(ctx.tree_root, num);
        }
        if (ws == null) {
            ws = workspace.create(ctx.allocator, name, num) catch return;
            // Check config for workspace-output assignment
            var target_out = getFocusedOutput(ctx.tree_root);
            if (ctx.config) |cfg| {
                for (cfg.workspace_outputs.items) |wo| {
                    if (std.mem.eql(u8, wo.workspace, name)) {
                        if (output.findByName(ctx.tree_root, wo.output)) |assigned_out| {
                            target_out = assigned_out;
                        }
                        break;
                    }
                }
            }
            if (target_out) |out| {
                out.appendChild(ws.?);
                ws.?.rect = out.rect;
            }
        }
    }

    if (ws) |target_ws| {
        // Unfocus current workspace
        if (getFocusedWorkspace(ctx.tree_root)) |current_ws| {
            if (current_ws == target_ws) {
                // Already on this workspace — check back_and_forth
                if (ctx.config) |cfg| {
                    if (cfg.workspace_auto_back_and_forth and ctx.prev_workspace_len > 0) {
                        const prev_name = ctx.prev_workspace[0..ctx.prev_workspace_len];
                        if (workspace.findByName(ctx.tree_root, prev_name)) |prev_ws| {
                            migrateStickyWindows(current_ws, prev_ws);
                            clearFocusedPath(current_ws);
                            setFocus(ctx, prev_ws);
                            // Clear urgency on focused workspace
                            if (prev_ws.workspace) |*wsd| {
                                if (wsd.urgent) {
                                    wsd.urgent = false;
                                    var baf_child_cur = prev_ws.children.first;
                                    while (baf_child_cur) |baf_child| : (baf_child_cur = baf_child.next) {
                                        if (baf_child.window) |*wd| {
                                            wd.urgency = false;
                                        }
                                    }
                                }
                            }
                            if (prev_ws.children.first) |child| {
                                setFocus(ctx, getDeepestChild(child));
                            }
                            updateCurrentDesktop(ctx);
                            relayoutAndRender(ctx);
                            {
                                var baf_ev_buf: [256]u8 = undefined;
                                var baf_ev_fbs = std.io.fixedBufferStream(&baf_ev_buf);
                                const baf_ev_w = baf_ev_fbs.writer();
                                baf_ev_w.writeAll("{\"change\":\"focus\",\"current\":{\"name\":\"") catch {};
                                const baf_ws_name = if (prev_ws.workspace) |wsd| wsd.name else "?";
                                jsonEscapeWrite(baf_ev_w, baf_ws_name) catch {};
                                baf_ev_w.writeAll("\",\"output\":\"") catch {};
                                jsonEscapeWrite(baf_ev_w, getWorkspaceOutputName(prev_ws)) catch {};
                                baf_ev_w.writeAll("\"}}") catch {};
                                const baf_ev_json = baf_ev_fbs.getWritten();
                                if (baf_ev_json.len > 0) broadcastIpcEvent(ctx, .workspace, baf_ev_json);
                            }
                        }
                    }
                }
                return;
            }
            // Save current workspace name for back_and_forth
            if (current_ws.workspace) |wsd| {
                const copy_len = @min(wsd.name.len, 32);
                @memcpy(ctx.prev_workspace[0..copy_len], wsd.name[0..copy_len]);
                ctx.prev_workspace_len = @intCast(copy_len);
            }
            migrateStickyWindows(current_ws, target_ws);
            clearFocusedPath(current_ws);
        }

        // Focus new workspace
        setFocus(ctx, target_ws);
        // Clear urgency on focused workspace
        if (target_ws.workspace) |*wsd| {
            if (wsd.urgent) {
                wsd.urgent = false;
                // Clear urgency on all windows in this workspace
                var child_cur = target_ws.children.first;
                while (child_cur) |child| : (child_cur = child.next) {
                    if (child.window) |*wd| {
                        wd.urgency = false;
                    }
                }
            }
        }
        // Also focus first child if exists
        if (target_ws.children.first) |child| {
            setFocus(ctx, getDeepestChild(child));
        }

        updateCurrentDesktop(ctx);
        updateDesktopNames(ctx);
        updateNumberOfDesktops(ctx);
        relayoutAndRender(ctx);

        // Broadcast workspace event (with JSON-escaped name)
        const ws_name = if (target_ws.workspace) |wsd| wsd.name else "?";
        var ev_buf: [256]u8 = undefined;
        var ev_fbs = std.io.fixedBufferStream(&ev_buf);
        const ev_w = ev_fbs.writer();
        ev_w.writeAll("{\"change\":\"focus\",\"current\":{\"name\":\"") catch {};
        jsonEscapeWrite(ev_w, ws_name) catch {};
        ev_w.writeAll("\",\"output\":\"") catch {};
        jsonEscapeWrite(ev_w, getWorkspaceOutputName(target_ws)) catch {};
        ev_w.writeAll("\"}}") catch {};
        const ev_json = ev_fbs.getWritten();
        if (ev_json.len > 0) broadcastIpcEvent(ctx, .workspace, ev_json);
    }
}

fn executeMoveWorkspace(ctx: *EventContext, cmd: command_mod.Command) void {
    const name = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    // Allow moving windows and split containers (not workspaces/outputs/root)
    if (focused.type != .window and focused.type != .split_con) return;

    // Find or create target workspace
    // Try by name first, then by number (for "workspace number N" commands)
    var ws = workspace.findByName(ctx.tree_root, name);
    if (ws == null) {
        const num = std.fmt.parseInt(i32, name, 10) catch 0;
        if (num != 0) {
            ws = workspace.findByNum(ctx.tree_root, num);
        }
        if (ws == null) {
            ws = workspace.create(ctx.allocator, name, num) catch return;
            if (getFirstOutput(ctx.tree_root)) |out| {
                out.appendChild(ws.?);
                ws.?.rect = out.rect;
            }
        }
    }

    if (ws) |target_ws| {
        // Move focus to sibling before unlinking
        const new_focus = focused.next orelse focused.prev orelse focused.parent;

        focused.unlink();
        target_ws.appendChild(focused);

        // Re-focus
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }

        relayoutAndRender(ctx);
    }
}

fn executeKill(ctx: *EventContext, cmd: command_mod.Command) void {
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    const force = if (cmd.args[0]) |arg| std.mem.eql(u8, arg, "kill") else false;
    killWindow(ctx, focused, force);
}

fn killWindow(ctx: *EventContext, con: *tree.Container, force: bool) void {
    const wd = con.window orelse return;

    if (!force) {
        // Try WM_DELETE_WINDOW first (graceful close)
        if (sendDeleteWindow(ctx, wd.id)) return;
    }

    // Force kill
    _ = xcb.killClient(ctx.conn, wd.id);

}

/// Send WM_DELETE_WINDOW client message. Returns true if the protocol is supported.
fn sendDeleteWindow(ctx: *EventContext, window: xcb.Window) bool {
    // Check if window supports WM_DELETE_WINDOW
    const cookie = xcb.getProperty(ctx.conn, 0, window, ctx.atoms.wm_protocols, xcb.ATOM_ATOM, 0, 32);
    const reply = xcb.getPropertyReply(ctx.conn, cookie, null) orelse return false;
    defer std.c.free(reply);

    const len = xcb.getPropertyValueLength(reply);
    if (len <= 0) return false;
    const ptr = xcb.getPropertyValue(reply) orelse return false;
    const atoms: [*]const xcb.Atom = @ptrCast(@alignCast(ptr));
    const count: usize = @intCast(@divTrunc(len, 4));

    var supports_delete = false;
    for (atoms[0..count]) |atom| {
        if (atom == ctx.atoms.wm_delete_window) {
            supports_delete = true;
            break;
        }
    }

    if (!supports_delete) return false;

    // Send WM_DELETE_WINDOW client message
    var event_data: xcb.c.xcb_client_message_event_t = std.mem.zeroes(xcb.c.xcb_client_message_event_t);
    event_data.response_type = xcb.CLIENT_MESSAGE;
    event_data.window = window;
    event_data.type = ctx.atoms.wm_protocols;
    event_data.format = 32;
    event_data.data.data32[0] = ctx.atoms.wm_delete_window;
    event_data.data.data32[1] = xcb.CURRENT_TIME;

    _ = xcb.sendEvent(ctx.conn, 0, window, xcb.EVENT_MASK_NO_EVENT, @ptrCast(&event_data));

    return true;
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() std.c.pid_t;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn executeExec(cmd: command_mod.Command) void {
    const actual_cmd = cmd.args[0] orelse return;
    // --no-startup-id is stripped at parse time in command.zig

    // We need a null-terminated copy of the command
    var cmd_buf: [4096]u8 = undefined;
    if (actual_cmd.len >= cmd_buf.len) return;
    @memcpy(cmd_buf[0..actual_cmd.len], actual_cmd);
    cmd_buf[actual_cmd.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..actual_cmd.len :0]);

    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        // Child process
        _ = setsid();

        // Close inherited fds (stdin/stdout/stderr are kept)
        // Close all fds > 2 up to a reasonable limit
        var fd: c_int = 3;
        while (fd < 256) : (fd += 1) {
            _ = std.c.close(fd);
        }

        // exec /bin/sh -c CMD
        const argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd_z,
        };
        _ = execvp("/bin/sh", &argv);
        std.c._exit(1);
    }
    // Parent: nothing to do, child is detached via setsid
}

fn executeFloating(ctx: *EventContext) void {
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    focused.is_floating = !focused.is_floating;
    relayoutAndRender(ctx);
}

fn executeSticky(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    if (!focused.is_floating) return;
    if (std.mem.eql(u8, arg, "enable")) {
        focused.is_sticky = true;
    } else if (std.mem.eql(u8, arg, "disable")) {
        focused.is_sticky = false;
    } else if (std.mem.eql(u8, arg, "toggle")) {
        focused.is_sticky = !focused.is_sticky;
    }
}

fn migrateStickyWindows(src_ws: *tree.Container, dst_ws: *tree.Container) void {
    const src_out_rect: tree.Rect = if (src_ws.parent) |p| p.rect else src_ws.rect;
    const dst_out_rect: tree.Rect = if (dst_ws.parent) |p| p.rect else dst_ws.rect;

    var cur = src_ws.children.first;
    while (cur) |child| {
        const nxt = child.next;
        if (child.is_floating and child.is_sticky) {
            const rel_x: i32 = child.rect.x - src_out_rect.x;
            const rel_y: i32 = child.rect.y - src_out_rect.y;
            child.unlink();
            child.parent = dst_ws;
            dst_ws.children.append(child);
            child.rect.x = dst_out_rect.x + rel_x;
            child.rect.y = dst_out_rect.y + rel_y;
            const max_x = dst_out_rect.x + @as(i32, @intCast(dst_out_rect.w)) - @as(i32, @intCast(child.rect.w));
            const max_y = dst_out_rect.y + @as(i32, @intCast(dst_out_rect.h)) - @as(i32, @intCast(child.rect.h));
            if (child.rect.x < dst_out_rect.x) child.rect.x = dst_out_rect.x;
            if (child.rect.y < dst_out_rect.y) child.rect.y = dst_out_rect.y;
            if (child.rect.x > max_x) child.rect.x = max_x;
            if (child.rect.y > max_y) child.rect.y = max_y;
            child.window_rect = child.rect;
        }
        cur = nxt;
    }
}

fn executeBorder(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    if (focused.type != .window) return;

    if (std.mem.eql(u8, arg, "none")) {
        focused.border_style = .none;
    } else if (std.mem.eql(u8, arg, "pixel")) {
        focused.border_style = .pixel;
        if (cmd.args[1]) |width_str| {
            if (std.fmt.parseInt(i16, width_str, 10)) |w| {
                focused.border_width_override = w;
            } else |_| {}
        }
    } else if (std.mem.eql(u8, arg, "normal")) {
        focused.border_style = .normal;
        if (cmd.args[1]) |width_str| {
            if (std.fmt.parseInt(i16, width_str, 10)) |w| {
                focused.border_width_override = w;
            } else |_| {}
        }
    } else if (std.mem.eql(u8, arg, "toggle")) {
        focused.border_style = switch (focused.border_style) {
            .none => .pixel,
            .pixel => .normal,
            .normal => .none,
        };
    }

    relayoutAndRender(ctx);
}

fn executeFullscreen(ctx: *EventContext) void {
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    focused.is_fullscreen = if (focused.is_fullscreen != .none) .none else .window;

    // Update _NET_WM_STATE
    if (focused.window) |wd| {
        if (focused.is_fullscreen != .none) {
            const fs_atom = [_]u32{ctx.atoms.net_wm_state_fullscreen};
            _ = xcb.changeProperty(ctx.conn, xcb.PROP_MODE_REPLACE, wd.id, ctx.atoms.net_wm_state, xcb.ATOM_ATOM, 32, 1, @ptrCast(&fs_atom));
        } else {
            _ = xcb.changeProperty(ctx.conn, xcb.PROP_MODE_REPLACE, wd.id, ctx.atoms.net_wm_state, xcb.ATOM_ATOM, 32, 0, null);
        }
    }

    // If fullscreen, set rect to output rect
    if (focused.is_fullscreen != .none) {
        if (getWorkspaceFor(focused)) |ws| {
            if (ws.parent) |out| {
                focused.rect = out.rect;
                focused.window_rect = out.rect;
            }
        }
    }

    relayoutAndRender(ctx);
}

fn executeMark(ctx: *EventContext, cmd: command_mod.Command) void {
    const mark_name = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    // Dupe the mark string so it outlives the command buffer
    const owned_mark = ctx.allocator.dupe(u8, mark_name) catch return;
    focused.addMark(owned_mark) catch {
        ctx.allocator.free(owned_mark);
    };
}

fn executeUnmark(ctx: *EventContext, cmd: command_mod.Command) void {
    const mark_name = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    focused.removeMark(ctx.allocator, mark_name);
}

fn executeScratchpad(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;

    if (std.mem.eql(u8, arg, "move")) {
        const focused = getFocusedContainer(ctx.tree_root) orelse return;
        scratchpad.moveToScratchpad(focused, ctx.tree_root, ctx.allocator) catch return;
        relayoutAndRender(ctx);
    } else if (std.mem.eql(u8, arg, "show")) {
        // Find a scratchpad window and show it on current workspace
        const scratch_ws = scratchpad.getScratchWorkspace(ctx.tree_root, ctx.allocator) catch return;
        const child = scratch_ws.children.first orelse return;
        const current_ws = getFocusedWorkspace(ctx.tree_root) orelse return;

        // Move from scratchpad to current workspace
        child.unlink();
        child.is_scratchpad = false;
        child.is_floating = true; // scratchpad windows are floating when shown
        current_ws.appendChild(child);
        setFocus(ctx, child);
        relayoutAndRender(ctx);
    }
}

fn executeResize(ctx: *EventContext, cmd: command_mod.Command) void {
    // resize grow/shrink width/height N [px|ppt]
    const direction = cmd.args[0] orelse return; // "grow" or "shrink"
    const dimension = cmd.args[1] orelse return; // "width" or "height"
    const amount_str = cmd.args[2] orelse return; // "10" etc.

    const amount = std.fmt.parseInt(i32, amount_str, 10) catch return;
    if (amount <= 0) return;

    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    const parent = focused.parent orelse return;

    // Determine if resizing is valid for the parent's layout
    const is_grow = std.mem.eql(u8, direction, "grow");
    const is_width = std.mem.eql(u8, dimension, "width") or std.mem.eql(u8, dimension, "w");

    // Width resize only makes sense in hsplit, height in vsplit
    const target_layout: tree.Layout = if (is_width) .hsplit else .vsplit;

    // Walk up to find a parent with the matching layout
    var target_parent: ?*tree.Container = null;
    var resize_child: *tree.Container = focused;
    var cur_parent: ?*tree.Container = parent;
    while (cur_parent) |p| {
        if (p.type == .root or p.type == .output) break;
        if (p.layout == target_layout and p.tilingChildCount() > 1) {
            target_parent = p;
            break;
        }
        resize_child = p;
        cur_parent = p.parent;
    }

    const tp = target_parent orelse return;

    // Calculate the total size of the parent in the relevant dimension
    const total: u32 = if (is_width) tp.rect.w else tp.rect.h;
    if (total == 0) return;

    // Calculate percent delta
    const delta: f32 = @as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(total));
    const sign: f32 = if (is_grow) delta else -delta;

    // Adjust percent of the resize_child
    if (resize_child.percent <= 0.0) {
        // Initialize percent based on equal distribution
        const n = tp.tilingChildCount();
        if (n == 0) return;
        resize_child.percent = 1.0 / @as(f32, @floatFromInt(n));
    }
    resize_child.percent += sign;

    // Clamp to reasonable range
    if (resize_child.percent < 0.05) resize_child.percent = 0.05;
    if (resize_child.percent > 0.95) resize_child.percent = 0.95;

    // Find a sibling to absorb the change (next sibling, or prev)
    const sibling = resize_child.next orelse resize_child.prev orelse return;
    if (sibling.percent <= 0.0) {
        const n = tp.tilingChildCount();
        if (n == 0) return;
        sibling.percent = 1.0 / @as(f32, @floatFromInt(n));
    }
    sibling.percent -= sign;
    if (sibling.percent < 0.05) sibling.percent = 0.05;
    if (sibling.percent > 0.95) sibling.percent = 0.95;

    relayoutAndRender(ctx);
}

/// Internal resize for mouse drag — takes direction/dimension as strings and amount as i32.
fn executeResizeInternal(ctx: *EventContext, con: *tree.Container, direction: []const u8, dimension: []const u8, amount: i32) void {
    if (amount <= 0) return;
    const parent = con.parent orelse return;
    const is_grow = std.mem.eql(u8, direction, "grow");
    const is_width = std.mem.eql(u8, dimension, "width");
    const target_layout: tree.Layout = if (is_width) .hsplit else .vsplit;

    var target_parent: ?*tree.Container = null;
    var resize_child: *tree.Container = con;
    var cur_parent: ?*tree.Container = parent;
    while (cur_parent) |p| {
        if (p.type == .root or p.type == .output) break;
        if (p.layout == target_layout and p.tilingChildCount() > 1) {
            target_parent = p;
            break;
        }
        resize_child = p;
        cur_parent = p.parent;
    }
    const tp = target_parent orelse return;
    const total: u32 = if (is_width) tp.rect.w else tp.rect.h;
    if (total == 0) return;
    const delta: f32 = @as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(total));
    const sign: f32 = if (is_grow) delta else -delta;
    if (resize_child.percent <= 0.0) {
        const n = tp.tilingChildCount();
        if (n == 0) return;
        resize_child.percent = 1.0 / @as(f32, @floatFromInt(n));
    }
    resize_child.percent = @max(0.05, @min(0.95, resize_child.percent + sign));
    const sibling = resize_child.next orelse resize_child.prev orelse return;
    if (sibling.percent <= 0.0) {
        const n = tp.tilingChildCount();
        if (n == 0) return;
        sibling.percent = 1.0 / @as(f32, @floatFromInt(n));
    }
    sibling.percent = @max(0.05, @min(0.95, sibling.percent - sign));
    relayoutAndRender(ctx);
}

fn executeFocusOutput(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;

    // Find current output
    const focused_ws = getFocusedWorkspace(ctx.tree_root) orelse return;
    const current_output = focused_ws.parent orelse return;
    if (current_output.type != .output) return;

    // Directional or named output
    const target = if (std.mem.eql(u8, arg, "left"))
        output.findAdjacent(ctx.tree_root, current_output, .left)
    else if (std.mem.eql(u8, arg, "right"))
        output.findAdjacent(ctx.tree_root, current_output, .right)
    else if (std.mem.eql(u8, arg, "up"))
        output.findAdjacent(ctx.tree_root, current_output, .up)
    else if (std.mem.eql(u8, arg, "down"))
        output.findAdjacent(ctx.tree_root, current_output, .down)
    else
        output.findByName(ctx.tree_root, arg);

    const target_output = target orelse return;

    // Focus the first (or focused) workspace on the target output
    var ws_cur = target_output.children.first;
    var target_ws: ?*tree.Container = null;
    while (ws_cur) |ws| : (ws_cur = ws.next) {
        if (ws.type == .workspace) {
            if (target_ws == null) target_ws = ws;
            if (ws.is_focused) {
                target_ws = ws;
                break;
            }
        }
    }

    if (target_ws) |ws| {
        setFocus(ctx, ws);
        // Try to focus a window in this workspace
        if (findFocusedLeaf(ws)) |leaf| {
            if (leaf != ws) setFocus(ctx, leaf);
        }
        relayoutAndRender(ctx);
    }
}

fn executeMoveWorkspaceToOutput(ctx: *EventContext, cmd: command_mod.Command) void {
    const direction = cmd.args[0] orelse return;
    const current_ws = getFocusedWorkspace(ctx.tree_root) orelse return;
    const current_out = current_ws.parent orelse return;
    if (current_out.type != .output) return;

    // Find target output
    const target_out = blk: {
        if (std.mem.eql(u8, direction, "left")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .left);
        } else if (std.mem.eql(u8, direction, "right")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .right);
        } else if (std.mem.eql(u8, direction, "up")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .up);
        } else if (std.mem.eql(u8, direction, "down")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .down);
        } else {
            // Named output
            break :blk output.findByName(ctx.tree_root, direction);
        }
    } orelse return;

    if (target_out == current_out) return;

    // Move workspace to target output
    current_ws.unlink();
    target_out.appendChild(current_ws);
    current_ws.rect = target_out.rect;

    // Update workspace output_name to match target output
    if (current_ws.workspace) |*wsd| {
        if (target_out.workspace) |tout_wsd| {
            wsd.output_name = tout_wsd.output_name;
        }
    }

    // Ensure source output still has at least one workspace
    if (current_out.children.first == null) {
        if (workspace.create(ctx.allocator, "1", 1)) |new_ws| {
            current_out.appendChild(new_ws);
            new_ws.rect = current_out.rect;
        } else |_| {}
    }

    relayoutAndRender(ctx);
    broadcastIpcEvent(ctx, .workspace, "{\"change\":\"move\"}");
}

/// Static sentinel for the default mode — used for pointer comparison to detect ownership.
pub const DEFAULT_MODE: []const u8 = "default";

fn executeReload(_: *EventContext) void {
    // Send SIGUSR1 to self to trigger config reload via the signalfd handler in main.zig
    const linux = std.os.linux;
    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
}

/// Reparent all client windows back to root (ICCCM compliance for WM exit/restart).
pub fn unreparentAll(ctx: *EventContext) void {
    var it = ctx.window_map.iterator();
    while (it.next()) |entry| {
        const con = entry.value_ptr.*;
        if (con.window) |wd| {
            // Only process client window entries (not frame entries) to avoid double-processing
            if (wd.frame_id != 0 and wd.id == entry.key_ptr.*) {
                _ = xcb.c.xcb_change_save_set(ctx.conn, xcb.c.XCB_SET_MODE_DELETE, wd.id);
                _ = xcb.c.xcb_reparent_window(ctx.conn, wd.id, ctx.root_window,
                    @intCast(con.rect.x), @intCast(con.rect.y));
                _ = xcb.mapWindow(ctx.conn, wd.id);
                _ = xcb.c.xcb_destroy_window(ctx.conn, wd.frame_id);
            }
        }
    }
    _ = xcb.flush(ctx.conn);
}

pub fn executeRestart(ctx: *EventContext) void {
    // Re-exec ourselves. This preserves the X connection and managed windows
    // because the new process inherits file descriptors.
    std.debug.print("zephwm: restarting via execvp\n", .{});

    // Set restart flag so exec commands are skipped on re-exec
    _ = setenv("ZEPHWM_RESTART", "1", 1);

    // Read /proc/self/exe to get our binary path.
    // Must succeed before we unreparent anything — if it fails, abort cleanly
    // so the WM continues running in a valid state.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.readLinkAbsolute("/proc/self/exe", &exe_buf) catch {
        std.debug.print("zephwm: restart failed: cannot read /proc/self/exe\n", .{});
        return;
    };
    // Null-terminate for execvp
    if (exe_path.len >= exe_buf.len) return;
    exe_buf[exe_path.len] = 0;
    const exe_z: [*:0]const u8 = @ptrCast(exe_buf[0..exe_path.len :0]);

    // Unreparent all client windows back to root right before exec.
    // We do this only after the exe path is confirmed valid so the WM
    // is not left in a broken state if path resolution failed above.
    unreparentAll(ctx);

    const argv = [_:null]?[*:0]const u8{exe_z};
    _ = execvp(exe_z, &argv);
    // If execvp returns, it failed — the WM state is now broken (windows
    // already unreparented), so exit immediately rather than returning to
    // a corrupted event loop.
    std.debug.print("zephwm: restart execvp failed\n", .{});
    std.c._exit(1);
}

fn executeMode(ctx: *EventContext, cmd: command_mod.Command) void {
    const mode_name = cmd.args[0] orelse return;
    // Dupe the mode string so it outlives the command's backing memory.
    const duped = ctx.allocator.dupe(u8, mode_name) catch return;
    // Free previous mode if allocator-owned (pointer != static sentinel)
    if (ctx.current_mode.ptr != DEFAULT_MODE.ptr) {
        ctx.allocator.free(ctx.current_mode);
    }
    ctx.current_mode = duped;
    std.debug.print("zephwm: switched to mode \"{s}\"\n", .{duped});

    // Broadcast mode event (with JSON-escaped name)
    var ev_buf: [128]u8 = undefined;
    var ev_fbs = std.io.fixedBufferStream(&ev_buf);
    const ev_w = ev_fbs.writer();
    ev_w.writeAll("{\"change\":\"") catch {};
    jsonEscapeWrite(ev_w, duped) catch {};
    ev_w.writeAll("\"}") catch {};
    const ev_json = ev_fbs.getWritten();
    if (ev_json.len > 0) broadcastIpcEvent(ctx, .mode, ev_json);
}

// --- Key grabbing ---

pub fn grabKeys(ctx: *EventContext, cfg: *const config_mod.Config) void {
    const syms = ctx.key_symbols orelse return;

    // Ungrab all first
    _ = xcb.ungrabKey(ctx.conn, xcb.GRAB_ANY, ctx.root_window, xcb.MOD_MASK_ANY);

    for (cfg.keybinds.items) |kb| {
        // Convert key name to keycode
        const keysym = nameToKeysym(kb.key);
        if (keysym == 0) continue;

        const keycode_ptr = xcb.keySymbolsGetKeycode(syms, keysym) orelse continue;
        defer std.c.free(keycode_ptr);
        const keycode = keycode_ptr.*;
        if (keycode == 0) continue;

        // Convert modifier bitmask to X11 modifiers
        var xmods: u16 = 0;
        if (kb.modifiers & config_mod.MOD_SUPER != 0) xmods |= xcb.MOD_MASK_4;
        if (kb.modifiers & config_mod.MOD_SHIFT != 0) xmods |= xcb.MOD_MASK_SHIFT;
        if (kb.modifiers & config_mod.MOD_CTRL != 0) xmods |= xcb.MOD_MASK_CONTROL;
        if (kb.modifiers & config_mod.MOD_ALT != 0) xmods |= xcb.MOD_MASK_1;

        // Grab with and without Lock/NumLock
        _ = xcb.grabKey(ctx.conn, 1, ctx.root_window, xmods, keycode, xcb.GRAB_MODE_ASYNC, xcb.GRAB_MODE_ASYNC);
        _ = xcb.grabKey(ctx.conn, 1, ctx.root_window, xmods | xcb.MOD_MASK_LOCK, keycode, xcb.GRAB_MODE_ASYNC, xcb.GRAB_MODE_ASYNC);
        _ = xcb.grabKey(ctx.conn, 1, ctx.root_window, xmods | xcb.MOD_MASK_2, keycode, xcb.GRAB_MODE_ASYNC, xcb.GRAB_MODE_ASYNC);
        _ = xcb.grabKey(ctx.conn, 1, ctx.root_window, xmods | xcb.MOD_MASK_LOCK | xcb.MOD_MASK_2, keycode, xcb.GRAB_MODE_ASYNC, xcb.GRAB_MODE_ASYNC);
    }


}

/// Convert a key name string to an X11 keysym using xkb_keysym_from_name.
/// Returns 0 (XKB_KEY_NoSymbol) if not found.
fn nameToKeysym(name: []const u8) xcb.Keysym {
    // xkb_keysym_from_name requires a null-terminated string.
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return 0;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ks = xcb.xkb_keysym_from_name(@ptrCast(&buf), xcb.XKB_KEYSYM_NO_FLAGS);
    // XKB_KEY_NoSymbol == 0xFFFFFFFF in some headers; also 0 means not found.
    if (ks == xcb.c.XKB_KEY_NoSymbol) return 0;
    return @intCast(ks);
}
