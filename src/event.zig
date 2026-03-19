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
};

/// Dispatch an X11 event to the appropriate handler.
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
        xcb.FOCUS_IN => handleFocusIn(ctx, @ptrCast(event)),
        xcb.MAPPING_NOTIFY => handleMappingNotify(ctx, event),
        else => {}, // Ignore unhandled events
    }
}

// --- Tree helpers ---

/// Find a container by X11 window ID, walking the entire tree.
fn findContainerByWindow(root: *tree.Container, window: xcb.Window) ?*tree.Container {
    if (root.window) |wd| {
        if (wd.id == window) return root;
    }
    var cur = root.children.first;
    while (cur) |child| : (cur = child.next) {
        if (findContainerByWindow(child, window)) |found| return found;
    }
    return null;
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
    // Clear old focus along the path
    clearFocusRecursive(ctx.tree_root);

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

fn clearFocusRecursive(con: *tree.Container) void {
    con.is_focused = false;
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        clearFocusRecursive(child);
    }
}

/// Apply layout and render for a workspace.
fn relayoutAndRender(ctx: *EventContext) void {
    // Apply layout to all workspaces
    const cfg = ctx.config;
    const gap: u32 = if (cfg) |c| c.gap_inner else 0;
    const border: u32 = if (cfg) |c| c.border_px else 1;

    var cur = ctx.tree_root.children.first;
    while (cur) |output_con| : (cur = output_con.next) {
        if (output_con.type != .output) continue;
        var ws_cur = output_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type == .workspace) {
                layout.apply(ws, gap, border);
            }
        }
    }

    render.applyTree(ctx.conn, ctx.tree_root, ctx.border_focus_color, ctx.border_unfocus_color);
}

// --- EWMH property update helpers ---

/// Collect all managed window IDs and set _NET_CLIENT_LIST on the root window.
pub fn updateClientList(ctx: *EventContext) void {
    var ids: [256]u32 = undefined;
    var count: usize = 0;
    collectWindowIds(ctx.tree_root, &ids, &count);

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

fn collectWindowIds(con: *tree.Container, ids: *[256]u32, count: *usize) void {
    if (con.window) |wd| {
        if (count.* < 256) {
            ids[count.*] = wd.id;
            count.* += 1;
        } else {
            std.log.warn("_NET_CLIENT_LIST: exceeded 256 window limit, some windows omitted", .{});
            return;
        }
    }
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        collectWindowIds(child, ids, count);
    }
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
        wd.class = "";
        wd.instance = "";
        wd.title = "";
    }
}

// --- Event handlers ---

fn handleMapRequest(ctx: *EventContext, ev: *xcb.MapRequestEvent) void {
    const window = ev.window;

    // Check if already managed
    if (findContainerByWindow(ctx.tree_root, window) != null) {
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
    var should_float = transient != null;
    if (!should_float) {
        should_float = shouldFloatByType(ctx.conn, window, ctx.atoms);
    }

    con.window = tree.WindowData{
        .id = window,
        .class = wm_class.class,
        .instance = wm_class.instance,
        .title = title,
        .transient_for = transient,
    };
    con.is_floating = should_float;

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

    // Attach to workspace
    if (target_ws) |ws| {
        ws.appendChild(con);
    } else {
        // Fallback: attach to root (shouldn't happen with proper setup)
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

    // Map the window
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
}

fn handleUnmapNotify(ctx: *EventContext, ev: *xcb.UnmapNotifyEvent) void {
    const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;

    // If this was focused, move focus to sibling or parent
    if (con.is_focused) {
        // Try next sibling, then prev sibling, then parent
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    // destroy() handles freeing WindowData strings — do not call freeWindowStrings separately
    con.unlink();
    con.destroy(ctx.allocator);

    updateAllEwmh(ctx);
    relayoutAndRender(ctx);
}

fn handleDestroyNotify(ctx: *EventContext, ev: *xcb.DestroyNotifyEvent) void {
    const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;

    if (con.is_focused) {
        const new_focus = con.next orelse con.prev orelse con.parent;
        if (new_focus) |nf| {
            if (nf != ctx.tree_root) {
                setFocus(ctx, nf);
            }
        }
    }

    // destroy() handles freeing WindowData strings — do not call freeWindowStrings separately
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
            // Parse and execute command
            if (command_mod.parse(kb.command)) |cmd| {
                executeCommand(ctx, cmd);
            }
            return;
        }
    }
}

/// Convert a keysym value to its name string (e.g., 0xff0d -> "Return").
fn keysymToName(keysym: xcb.Keysym, buf: *[64]u8) ?[]const u8 {
    // Common keysyms
    const mapping = .{
        .{ 0xff0d, "Return" },
        .{ 0xff1b, "Escape" },
        .{ 0xff09, "Tab" },
        .{ 0xffbe, "F1" },
        .{ 0xffbf, "F2" },
        .{ 0xffc0, "F3" },
        .{ 0xffc1, "F4" },
        .{ 0xffc2, "F5" },
        .{ 0xffc3, "F6" },
        .{ 0xffc4, "F7" },
        .{ 0xffc5, "F8" },
        .{ 0xffc6, "F9" },
        .{ 0xffc7, "F10" },
        .{ 0xffc8, "F11" },
        .{ 0xffc9, "F12" },
        .{ 0xff08, "BackSpace" },
        .{ 0xffff, "Delete" },
        .{ 0xff50, "Home" },
        .{ 0xff57, "End" },
        .{ 0xff55, "Prior" }, // Page Up
        .{ 0xff56, "Next" }, // Page Down
        .{ 0xff51, "Left" },
        .{ 0xff52, "Up" },
        .{ 0xff53, "Right" },
        .{ 0xff54, "Down" },
        .{ 0xff63, "Insert" },
        .{ 0xff13, "Pause" },
        .{ 0xff14, "Scroll_Lock" },
        .{ 0xff61, "Print" },
        .{ 0x0020, "space" },
        .{ 0xff8d, "KP_Enter" },
    };

    inline for (mapping) |entry| {
        if (keysym == entry[0]) return entry[1];
    }

    // Printable ASCII
    if (keysym >= 0x20 and keysym <= 0x7e) {
        buf[0] = @intCast(keysym);
        return buf[0..1];
    }

    // Number keys 0-9
    if (keysym >= 0x30 and keysym <= 0x39) {
        buf[0] = @intCast(keysym);
        return buf[0..1];
    }

    return null;
}

fn handleEnterNotify(ctx: *EventContext, ev: *xcb.EnterNotifyEvent) void {
    if (!ctx.focus_follows_mouse) return;

    const con = findContainerByWindow(ctx.tree_root, ev.event) orelse return;
    setFocus(ctx, con);
    _ = xcb.flush(ctx.conn);
}

fn handleButtonPress(ctx: *EventContext, ev: *xcb.ButtonPressEvent) void {
    const con = findContainerByWindow(ctx.tree_root, ev.event) orelse return;
    setFocus(ctx, con);

    // Allow the click to pass through to the application
    _ = xcb.c.xcb_allow_events(ctx.conn, xcb.c.XCB_ALLOW_REPLAY_POINTER, xcb.CURRENT_TIME);
    _ = xcb.flush(ctx.conn);
}

fn handleConfigureRequest(ctx: *EventContext, ev: *xcb.ConfigureRequestEvent) void {
    const con = findContainerByWindow(ctx.tree_root, ev.window);

    const should_forward = if (con) |c| c.is_floating else true;
    if (con) |c| {
        if (!c.is_floating) {
            // Tiled: send ConfigureNotify with current geometry
            sendConfigureNotify(ctx, c);
        }
    }
    if (should_forward) {
        // Forward the configure request (floating or unmanaged)
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
    _ = xcb.flush(ctx.conn);
}

/// Send a synthetic ConfigureNotify to tell a tiled window its current geometry.
fn sendConfigureNotify(ctx: *EventContext, con: *tree.Container) void {
    const wd = con.window orelse return;
    const r = con.window_rect;

    var event_data: xcb.c.xcb_configure_notify_event_t = std.mem.zeroes(xcb.c.xcb_configure_notify_event_t);
    event_data.response_type = xcb.CONFIGURE_NOTIFY;
    event_data.event = wd.id;
    event_data.window = wd.id;
    event_data.x = @intCast(r.x);
    event_data.y = @intCast(r.y);
    event_data.width = @intCast(r.w);
    event_data.height = @intCast(r.h);
    event_data.border_width = 0;
    event_data.above_sibling = xcb.WINDOW_NONE;
    event_data.override_redirect = 0;

    _ = xcb.sendEvent(ctx.conn, 0, wd.id, xcb.EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&event_data));
}

fn handlePropertyNotify(ctx: *EventContext, ev: *xcb.PropertyNotifyEvent) void {
    const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;

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
                }
            }
        }
    }
}

fn handleClientMessage(ctx: *EventContext, ev: *xcb.ClientMessageEvent) void {
    // _NET_ACTIVE_WINDOW: focus request
    if (ev.type == ctx.atoms.net_active_window) {
        const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;
        setFocus(ctx, con);
        relayoutAndRender(ctx);
        return;
    }

    // _NET_CLOSE_WINDOW: close request
    if (ev.type == ctx.atoms.net_close_window) {
        const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;
        killWindow(ctx, con, false);
        return;
    }

    // _NET_WM_STATE: fullscreen toggle etc.
    if (ev.type == ctx.atoms.net_wm_state) {
        const con = findContainerByWindow(ctx.tree_root, ev.window) orelse return;
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
    // Validate that the focused window matches our tree state
    _ = ctx;
    _ = ev;
    // TODO: re-set focus if it was stolen by an unmanaged window
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

// --- Command execution ---

pub fn executeCommand(ctx: *EventContext, cmd: command_mod.Command) void {
    switch (cmd.type) {
        .split => executeSplit(ctx, cmd),
        .focus => executeFocus(ctx, cmd),
        .move => executeMove(ctx, cmd),
        .layout_cmd => executeLayout(ctx, cmd),
        .workspace => executeWorkspace(ctx, cmd),
        .move_workspace => executeMoveWorkspace(ctx, cmd),
        .kill => executeKill(ctx),
        .exec => executeExec(cmd),
        .floating => executeFloating(ctx),
        .fullscreen => executeFullscreen(ctx),
        .mark => executeMark(ctx, cmd),
        .unmark => executeUnmark(ctx, cmd),
        .scratchpad => executeScratchpad(ctx, cmd),
        .mode => executeMode(ctx, cmd),
        .reload => executeReload(ctx),
        .restart => {
            std.debug.print("ziawm: restart not yet implemented\n", .{});
        },
        .exit => {
            ctx.running.* = false;
        },
        .resize => {}, // TODO
        .focus_output => {}, // TODO
        .nop => {},
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
    _ = xcb.flush(ctx.conn);
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
    _ = ctx;
    var con: *tree.Container = focused;
    while (con.parent) |parent| {
        if (parent.type == .root or parent.type == .output) break;
        if (parent.layout == orientation) {
            const sibling = switch (dir) {
                .prev => con.prev,
                .next => con.next,
            };
            if (sibling) |sib| {
                // Swap positions: remove focused and insert at sibling's position
                parent.children.remove(focused);
                switch (dir) {
                    .prev => {
                        parent.children.insertBefore(focused, sib);
                        focused.parent = parent;
                    },
                    .next => {
                        if (sib.next) |after| {
                            parent.children.insertBefore(focused, after);
                            focused.parent = parent;
                        } else {
                            parent.children.append(focused);
                            focused.parent = parent;
                        }
                    },
                }
                return;
            }
            // No sibling at this level — keep walking up
        }
        con = parent;
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
    var ws = workspace.findByName(ctx.tree_root, name);
    if (ws == null) {
        const num = std.fmt.parseInt(i32, name, 10) catch 0;
        ws = workspace.create(ctx.allocator, name, num) catch return;
        // Attach to first output
        if (getFirstOutput(ctx.tree_root)) |out| {
            out.appendChild(ws.?);
            ws.?.rect = out.rect;
        }
    }

    if (ws) |target_ws| {
        // Unfocus current workspace
        if (getFocusedWorkspace(ctx.tree_root)) |current_ws| {
            if (current_ws == target_ws) return; // already on this workspace
            clearFocusRecursive(current_ws);
        }

        // Focus new workspace
        setFocus(ctx, target_ws);
        // Also focus first child if exists
        if (target_ws.children.first) |child| {
            setFocus(ctx, getDeepestChild(child));
        }

        updateCurrentDesktop(ctx);
        updateDesktopNames(ctx);
        updateNumberOfDesktops(ctx);
        relayoutAndRender(ctx);
    }
}

fn executeMoveWorkspace(ctx: *EventContext, cmd: command_mod.Command) void {
    const name = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    if (focused.type != .window) return;

    // Find or create target workspace
    var ws = workspace.findByName(ctx.tree_root, name);
    if (ws == null) {
        const num = std.fmt.parseInt(i32, name, 10) catch 0;
        ws = workspace.create(ctx.allocator, name, num) catch return;
        if (getFirstOutput(ctx.tree_root)) |out| {
            out.appendChild(ws.?);
            ws.?.rect = out.rect;
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

fn executeKill(ctx: *EventContext) void {
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    killWindow(ctx, focused, false);
}

fn killWindow(ctx: *EventContext, con: *tree.Container, force: bool) void {
    const wd = con.window orelse return;

    if (!force) {
        // Try WM_DELETE_WINDOW first (graceful close)
        if (sendDeleteWindow(ctx, wd.id)) return;
    }

    // Force kill
    _ = xcb.killClient(ctx.conn, wd.id);
    _ = xcb.flush(ctx.conn);
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
    _ = xcb.flush(ctx.conn);
    return true;
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() std.c.pid_t;

fn executeExec(cmd: command_mod.Command) void {
    const shell_cmd = cmd.args[0] orelse return;
    // Strip --no-startup-id prefix if present
    var actual_cmd = shell_cmd;
    if (std.mem.startsWith(u8, actual_cmd, "--no-startup-id ")) {
        actual_cmd = actual_cmd["--no-startup-id ".len..];
    }

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
    focused.addMark(mark_name) catch {};
}

fn executeUnmark(ctx: *EventContext, cmd: command_mod.Command) void {
    const mark_name = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    focused.removeMark(mark_name);
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

/// Static sentinel for the default mode — used for pointer comparison to detect ownership.
pub const DEFAULT_MODE: []const u8 = "default";

fn executeReload(_: *EventContext) void {
    // Send SIGUSR1 to self to trigger config reload via the signalfd handler in main.zig
    const linux = std.os.linux;
    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
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
    std.debug.print("ziawm: switched to mode \"{s}\"\n", .{duped});
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

    _ = xcb.flush(ctx.conn);
}

/// Convert a key name string to an X11 keysym.
fn nameToKeysym(name: []const u8) xcb.Keysym {
    // Common key names
    const mapping = .{
        .{ "Return", 0xff0d },
        .{ "Escape", 0xff1b },
        .{ "Tab", 0xff09 },
        .{ "F1", 0xffbe },
        .{ "F2", 0xffbf },
        .{ "F3", 0xffc0 },
        .{ "F4", 0xffc1 },
        .{ "F5", 0xffc2 },
        .{ "F6", 0xffc3 },
        .{ "F7", 0xffc4 },
        .{ "F8", 0xffc5 },
        .{ "F9", 0xffc6 },
        .{ "F10", 0xffc7 },
        .{ "F11", 0xffc8 },
        .{ "F12", 0xffc9 },
        .{ "BackSpace", 0xff08 },
        .{ "Delete", 0xffff },
        .{ "Home", 0xff50 },
        .{ "End", 0xff57 },
        .{ "Prior", 0xff55 },
        .{ "Next", 0xff56 },
        .{ "Left", 0xff51 },
        .{ "Up", 0xff52 },
        .{ "Right", 0xff53 },
        .{ "Down", 0xff54 },
        .{ "Insert", 0xff63 },
        .{ "Pause", 0xff13 },
        .{ "Scroll_Lock", 0xff14 },
        .{ "Print", 0xff61 },
        .{ "space", 0x0020 },
        .{ "KP_Enter", 0xff8d },
        .{ "minus", 0x002d },
        .{ "plus", 0x002b },
        .{ "equal", 0x003d },
        .{ "bracketleft", 0x005b },
        .{ "bracketright", 0x005d },
        .{ "semicolon", 0x003b },
        .{ "apostrophe", 0x0027 },
        .{ "grave", 0x0060 },
        .{ "backslash", 0x005c },
        .{ "comma", 0x002c },
        .{ "period", 0x002e },
        .{ "slash", 0x002f },
    };

    inline for (mapping) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }

    // Single ASCII character
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 0x20 and ch <= 0x7e) return @intCast(ch);
    }

    return 0;
}
