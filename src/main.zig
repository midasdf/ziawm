// zephwm — i3-compatible tiling window manager
const std = @import("std");
const xcb = @import("xcb.zig");
const atoms_mod = @import("atoms.zig");
const tree = @import("tree.zig");
const output = @import("output.zig");
const event = @import("event.zig");
const render = @import("render.zig");
const ipc = @import("ipc.zig");
const config_mod = @import("config.zig");
const command_mod = @import("command.zig");
const bar = @import("bar.zig");
const linux = std.os.linux;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const VERSION = "0.1.0";

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

// Default border colors (can be overridden by config)
const DEFAULT_BORDER_FOCUS_COLOR: u32 = 0x4c7899;
const DEFAULT_BORDER_UNFOCUS_COLOR: u32 = 0x333333;

// IPC constants
const IPC_LISTEN_FD_TAG: i32 = -100; // sentinel for epoll data.fd
const SIGNAL_FD_TAG: i32 = -200; // sentinel for signalfd in epoll
const MAX_IPC_CLIENTS: usize = 16;

fn registerSubscription(
    client_fd: std.posix.fd_t,
    payload: []const u8,
    sub_fds: *[event.MAX_IPC_SUBS]std.posix.fd_t,
    sub_masks: *[event.MAX_IPC_SUBS]u8,
) void {
    // Parse JSON array of event names: ["workspace","mode","window"]
    var mask: u8 = 0;
    if (std.mem.indexOf(u8, payload, "\"workspace\"") != null) mask |= event.IPC_EVENT_WORKSPACE;
    if (std.mem.indexOf(u8, payload, "\"output\"") != null) mask |= event.IPC_EVENT_OUTPUT;
    if (std.mem.indexOf(u8, payload, "\"mode\"") != null) mask |= event.IPC_EVENT_MODE;
    if (std.mem.indexOf(u8, payload, "\"window\"") != null) mask |= event.IPC_EVENT_WINDOW;
    if (std.mem.indexOf(u8, payload, "\"binding\"") != null) mask |= event.IPC_EVENT_BINDING;

    if (mask == 0) return;

    // Find existing slot or empty slot
    for (0..event.MAX_IPC_SUBS) |i| {
        if (sub_fds[i] == client_fd) {
            sub_masks[i] |= mask; // Add to existing subscription
            return;
        }
    }
    for (0..event.MAX_IPC_SUBS) |i| {
        if (sub_fds[i] == -1) {
            sub_fds[i] = client_fd;
            sub_masks[i] = mask;
            return;
        }
    }
}

fn handleIpcMessage(ctx: *event.EventContext, client_fd: std.posix.fd_t, msg_type: u32, payload: []const u8) void {
    // For dynamic responses, use stack buffer
    var dyn_buf: [8192]u8 = undefined;

    const response: []const u8 = switch (msg_type) {
        @intFromEnum(ipc.MessageType.get_version) =>
            "{\"human_readable\":\"zephwm " ++ VERSION ++ "\",\"loaded_config_file_name\":\"\",\"minor\":1,\"major\":0,\"patch\":0}",
        @intFromEnum(ipc.MessageType.run_command) => blk: {
            // Execute the command
            if (payload.len > 0) {
                if (command_mod.parse(payload)) |cmd| {
                    event.executeCommand(ctx, cmd);
                    break :blk "[{\"success\":true}]";
                }
            }
            break :blk "[{\"success\":false,\"error\":\"invalid command\"}]";
        },
        @intFromEnum(ipc.MessageType.get_workspaces) => buildWorkspacesJson(ctx, &dyn_buf),
        @intFromEnum(ipc.MessageType.get_outputs) => buildOutputsJson(ctx, &dyn_buf),
        @intFromEnum(ipc.MessageType.get_tree) => buildTreeJson(ctx, &dyn_buf),
        @intFromEnum(ipc.MessageType.get_marks) => buildMarksJson(ctx, &dyn_buf),
        @intFromEnum(ipc.MessageType.get_bar_config) => buildBarConfigJson(ctx, &dyn_buf),
        @intFromEnum(ipc.MessageType.get_config) => "{}",
        @intFromEnum(ipc.MessageType.get_binding_modes) => "[\"default\"]",
        @intFromEnum(ipc.MessageType.subscribe) => blk: {
            // Parse subscription payload and register client
            registerSubscription(client_fd, payload, ctx.ipc_sub_fds, ctx.ipc_sub_masks);
            break :blk "{\"success\":true}";
        },
        @intFromEnum(ipc.MessageType.send_tick) => "{\"success\":true}",
        else => "{}",
    };

    ipc.writeResponse(client_fd, msg_type, response) catch {};
}

/// Build JSON for GET_WORKSPACES response.
/// Check if a workspace is the visible (focused) workspace on its output.
fn isVisibleWorkspace(ws: *tree.Container, output_con: *tree.Container) bool {
    // The visible workspace is the one with is_focused set, or the first workspace if none is focused
    var first_ws: ?*tree.Container = null;
    var cur = output_con.children.first;
    while (cur) |child| : (cur = child.next) {
        if (child.type != .workspace) continue;
        if (first_ws == null) first_ws = child;
        if (child.is_focused) return child == ws;
    }
    // No focused workspace — first workspace is visible
    return if (first_ws) |fw| fw == ws else false;
}

fn buildWorkspacesJson(ctx: *event.EventContext, buf: *[8192]u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeByte('[') catch return "[]";

    var first = true;
    var out_cur = ctx.tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type != .output) continue;
        var ws_cur = out_con.children.first;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type != .workspace) continue;
            if (!first) w.writeByte(',') catch return "[]";
            first = false;

            const name = if (ws.workspace) |wsd| wsd.name else "?";
            const num: i32 = if (ws.workspace) |wsd| (wsd.num orelse 0) else 0;
            // A workspace is "visible" if it's the focused workspace on its output
            const visible = isVisibleWorkspace(ws, out_con);
            const focused = ws.is_focused;
            // Check urgency on any child window
            var urgent = false;
            var child_cur = ws.children.first;
            while (child_cur) |child| : (child_cur = child.next) {
                if (child.window) |wd| {
                    if (wd.urgency) {
                        urgent = true;
                        break;
                    }
                }
            }

            std.fmt.format(w, "{{\"num\":{d},\"name\":\"", .{num}) catch return "[]";
            jsonEscapeWrite(w, name) catch return "[]";
            // Get output name from parent output container
            const ws_output_name = blk: {
                if (ws.parent) |parent| {
                    if (parent.type == .output) {
                        if (parent.workspace) |parent_wsd| {
                            if (parent_wsd.output_name.len > 0) break :blk parent_wsd.output_name;
                        }
                    }
                }
                break :blk "default";
            };
            w.writeAll("\",\"visible\":") catch return "[]";
            std.fmt.format(w, "{},\"focused\":{},\"output\":\"", .{ visible, focused }) catch return "[]";
            jsonEscapeWrite(w, ws_output_name) catch return "[]";
            std.fmt.format(w, "\",\"urgent\":{},\"rect\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}}}", .{
                urgent,
                ws.rect.x,
                ws.rect.y,
                ws.rect.w,
                ws.rect.h,
            }) catch return "[]";
        }
    }

    w.writeByte(']') catch return "[]";
    return fbs.getWritten();
}

/// Build JSON for GET_OUTPUTS response.
fn buildOutputsJson(ctx: *event.EventContext, buf: *[8192]u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeByte('[') catch return "[]";

    var first = true;
    var is_primary = true;
    var out_cur = ctx.tree_root.children.first;
    while (out_cur) |out_con| : (out_cur = out_con.next) {
        if (out_con.type != .output) continue;
        if (!first) w.writeByte(',') catch return "[]";
        first = false;

        // Determine the currently focused workspace name on this output
        var ws_name: []const u8 = "";
        var ws_cur = out_con.children.first;
        // Find focused workspace, fall back to first workspace
        var fallback_ws: ?[]const u8 = null;
        while (ws_cur) |ws| : (ws_cur = ws.next) {
            if (ws.type != .workspace) continue;
            const name = if (ws.workspace) |wsd| wsd.name else "?";
            if (fallback_ws == null) fallback_ws = name;
            if (ws.is_focused) {
                ws_name = name;
                break;
            }
        }
        if (ws_name.len == 0) {
            ws_name = fallback_ws orelse "";
        }

        // Output name: use stored name if available, else "default"
        const out_name = if (out_con.workspace) |wsd| wsd.output_name else "default";
        const display_name = if (out_name.len > 0) out_name else "default";

        std.fmt.format(w,
            "{{\"name\":\"{s}\",\"active\":true,\"primary\":{},\"rect\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"current_workspace\":\"",
            .{
                display_name,
                is_primary,
                out_con.rect.x,
                out_con.rect.y,
                out_con.rect.w,
                out_con.rect.h,
            },
        ) catch return "[]";
        jsonEscapeWrite(w, ws_name) catch return "[]";
        w.writeAll("\"}}") catch return "[]";
        is_primary = false;
    }

    // If no outputs in tree, return a single default entry
    if (first) {
        return "[{\"name\":\"default\",\"active\":true,\"primary\":true,\"rect\":{\"x\":0,\"y\":0,\"width\":720,\"height\":720},\"current_workspace\":\"1\"}]";
    }

    w.writeByte(']') catch return "[]";
    return fbs.getWritten();
}

/// Build JSON for GET_MARKS response.
/// Walks the entire tree collecting all marks from all containers.
fn buildBarConfigJson(ctx: *event.EventContext, buf: *[8192]u8) []const u8 {
    const cfg = ctx.config orelse return "{}";
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"id\":\"bar-0\",\"mode\":\"dock\",\"position\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.bar.position) catch return "{}";
    w.writeAll("\",\"status_command\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.bar.status_command) catch return "{}";
    w.writeAll("\",\"bar_height\":20,\"colors\":{\"background\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.bar.bg_color) catch return "{}";
    w.writeAll("\",\"statusline\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.bar.statusline_color) catch return "{}";
    w.writeAll("\",\"focused_workspace_bg\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.focused_bg) catch return "{}";
    w.writeAll("\",\"focused_workspace_text\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.focused_text) catch return "{}";
    w.writeAll("\"}}") catch return "{}";
    return fbs.getWritten();
}

fn buildMarksJson(ctx: *event.EventContext, buf: *[8192]u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeByte('[') catch return "[]";

    var first = true;
    collectMarksRecursive(ctx.tree_root, w, &first) catch return "[]";

    w.writeByte(']') catch return "[]";
    return fbs.getWritten();
}

fn collectMarksRecursive(con: *tree.Container, w: anytype, first: *bool) !void {
    // Collect marks from this container
    for (con.marks[0..con.mark_count]) |mark_opt| {
        if (mark_opt) |mark| {
            if (!first.*) try w.writeByte(',');
            first.* = false;
            try w.writeByte('"');
            try jsonEscapeWrite(w, mark);
            try w.writeByte('"');
        }
    }
    // Recurse into children
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        try collectMarksRecursive(child, w, first);
    }
}

/// Build JSON for GET_TREE response.
/// Uses a dynamic ArrayList(u8) since tree JSON can exceed 8KB for large trees.
/// Note: returns a slice backed by a static buffer that is reused on each call.
/// The caller must consume the result before the next call to buildTreeJson.
/// Module-level buffer for GET_TREE JSON responses. Retained across calls.
var tree_json_buf: std.ArrayListUnmanaged(u8) = .empty;

fn buildTreeJson(ctx: *event.EventContext, _: *[8192]u8) []const u8 {
    tree_json_buf.clearRetainingCapacity();
    writeContainerJson(tree_json_buf.writer(ctx.allocator), ctx.tree_root) catch return "{}";
    return tree_json_buf.items;
}


fn writeContainerJson(w: anytype, con: *tree.Container) !void {
    try w.writeAll("{");

    // id
    const id: u32 = if (con.window) |wd| wd.id else 0;
    try std.fmt.format(w, "\"id\":{d}", .{id});

    // type
    const type_str = switch (con.type) {
        .root => "root",
        .output => "output",
        .workspace => "workspace",
        .split_con => "con",
        .window => "con",
    };
    try std.fmt.format(w, ",\"type\":\"{s}\"", .{type_str});

    // name
    if (con.workspace) |wsd| {
        try std.fmt.format(w, ",\"name\":\"{s}\"", .{wsd.name});
    } else if (con.window) |wd| {
        try w.writeAll(",\"name\":\"");
        try jsonEscapeWrite(w, wd.title);
        try w.writeAll("\"");
    }

    // layout
    const layout_str = switch (con.layout) {
        .hsplit => "splith",
        .vsplit => "splitv",
        .tabbed => "tabbed",
        .stacked => "stacked",
    };
    try std.fmt.format(w, ",\"layout\":\"{s}\"", .{layout_str});

    // focused
    try std.fmt.format(w, ",\"focused\":{}", .{con.is_focused});

    // rect
    try std.fmt.format(w, ",\"rect\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
        con.rect.x, con.rect.y, con.rect.w, con.rect.h,
    });

    // floating
    if (con.is_floating) {
        try w.writeAll(",\"floating\":\"user_on\"");
    }

    // fullscreen
    try std.fmt.format(w, ",\"fullscreen_mode\":{d}", .{@intFromEnum(con.is_fullscreen)});

    // window (X11 window ID)
    if (con.window) |wd| {
        try std.fmt.format(w, ",\"window\":{d}", .{wd.id});
        if (wd.class.len > 0) {
            try std.fmt.format(w, ",\"window_properties\":{{\"class\":\"{s}\",\"instance\":\"{s}\"}}", .{ wd.class, wd.instance });
        }
    }

    // nodes (children)
    try w.writeAll(",\"nodes\":[");
    var first = true;
    var cur = con.children.first;
    while (cur) |child| : (cur = child.next) {
        if (!first) try w.writeByte(',');
        first = false;
        try writeContainerJson(w, child);
    }
    try w.writeAll("]");

    try w.writeAll("}");
}

/// Try to load config from standard paths. Returns null if no config found.
fn loadConfig(allocator: std.mem.Allocator) ?config_mod.Config {
    // Search paths in order
    const home = std.posix.getenv("HOME") orelse "";
    const xdg_config = std.posix.getenv("XDG_CONFIG_HOME");

    var path_buf: [512]u8 = undefined;

    // 1. XDG_CONFIG_HOME/zephwm/config
    if (xdg_config) |xdg| {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/zephwm/config", .{xdg}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 2. ~/.config/zephwm/config
    {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/.config/zephwm/config", .{home}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 3. ~/.zephwm/config
    {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/.zephwm/config", .{home}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 4. /etc/zephwm/config
    if (readConfigFile(allocator, "/etc/zephwm/config")) |cfg| return cfg;

    return null;
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ?config_mod.Config {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);
    return config_mod.Config.parse(allocator, content) catch null;
}

/// Parse a hex color string like "#4c7899" to a u32.
fn parseColor(color_str: []const u8) u32 {
    if (color_str.len == 0) return 0;
    const s = if (color_str[0] == '#') color_str[1..] else color_str;
    return std.fmt.parseInt(u32, s, 16) catch 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args: --version, --help
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zephwm v{s}\n", .{VERSION});
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: zephwm [--version] [--help]\n", .{});
            return;
        }
    }

    // 1. Connect to X server
    var screen_num: c_int = 0;
    const conn = xcb.connect(null, &screen_num) orelse {
        std.debug.print("ERROR: cannot connect to X server\n", .{});
        return error.XcbConnectFailed;
    };
    defer xcb.disconnect(conn);

    if (xcb.connectionHasError(conn) != 0) {
        std.debug.print("ERROR: X connection has error\n", .{});
        return error.XcbConnectionError;
    }

    // 2. Get root screen
    const screen = xcb.getScreen(conn) orelse {
        std.debug.print("ERROR: cannot get X screen\n", .{});
        return error.NoScreen;
    };
    const root_window = screen.root;

    // 3. Check for another WM (SubstructureRedirect)
    {
        const event_mask = [_]u32{
            xcb.EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                xcb.EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                xcb.EVENT_MASK_STRUCTURE_NOTIFY |
                xcb.EVENT_MASK_PROPERTY_CHANGE |
                xcb.EVENT_MASK_FOCUS_CHANGE |
                xcb.EVENT_MASK_ENTER_WINDOW,
        };
        const cookie = xcb.changeWindowAttributesChecked(
            conn,
            root_window,
            xcb.CW_EVENT_MASK,
            &event_mask,
        );
        if (xcb.requestCheck(conn, cookie)) |err| {
            std.c.free(err);
            std.debug.print("ERROR: another window manager is running\n", .{});
            return error.AnotherWmRunning;
        }
    }

    // 4. Init atoms
    const atoms = atoms_mod.Atoms.init(conn);

    // 5. Set _NET_SUPPORTED on root window
    {
        var supported = atoms.supportedList();
        _ = xcb.changeProperty(
            conn,
            xcb.PROP_MODE_REPLACE,
            root_window,
            atoms.net_supported,
            xcb.ATOM_ATOM,
            32,
            supported.len,
            @ptrCast(&supported),
        );
    }

    // 6. Create supporting WM check window
    const wm_check_window = xcb.generateId(conn);
    _ = xcb.createWindow(
        conn,
        xcb.COPY_FROM_PARENT,
        wm_check_window,
        root_window,
        -1,
        -1,
        1,
        1,
        0,
        0, // XCB_WINDOW_CLASS_COPY_FROM_PARENT
        screen.root_visual,
        0,
        null,
    );
    {
        const check_val = [_]u32{wm_check_window};
        _ = xcb.changeProperty(conn, xcb.PROP_MODE_REPLACE, root_window, atoms.net_supporting_wm_check, xcb.ATOM_WINDOW, 32, 1, @ptrCast(&check_val));
        _ = xcb.changeProperty(conn, xcb.PROP_MODE_REPLACE, wm_check_window, atoms.net_supporting_wm_check, xcb.ATOM_WINDOW, 32, 1, @ptrCast(&check_val));
        _ = xcb.changeProperty(conn, xcb.PROP_MODE_REPLACE, wm_check_window, atoms.net_wm_name, atoms.utf8_string, 8, 6, "zephwm");
    }

    // 7. Create tree root and detect outputs
    const tree_root = try tree.Container.create(allocator, .root);
    defer tree_root.destroy(allocator);

    try output.detectOutputs(conn, tree_root, allocator);

    // 7b. Subscribe to RandR screen change events
    const randr_base_event = xcb.randrQueryExtension(conn);
    if (randr_base_event > 0) {
        _ = xcb.randrSelectInput(conn, root_window,
            xcb.RANDR_NOTIFY_MASK_SCREEN_CHANGE |
            xcb.RANDR_NOTIFY_MASK_OUTPUT_CHANGE |
            xcb.RANDR_NOTIFY_MASK_CRTC_CHANGE);
    }

    _ = xcb.flush(conn);

    // 7c. Load config
    var config = loadConfig(allocator);
    defer if (config) |*cfg| cfg.deinit();

    // Determine colors from config
    var border_focus_color: u32 = DEFAULT_BORDER_FOCUS_COLOR;
    var border_unfocus_color: u32 = DEFAULT_BORDER_UNFOCUS_COLOR;
    if (config) |cfg| {
        border_focus_color = parseColor(cfg.focused_border);
        border_unfocus_color = parseColor(cfg.unfocused_border);
    }

    // 7b. Allocate key symbols
    const key_symbols = xcb.keySymbolsAlloc(conn);
    defer if (key_symbols) |syms| xcb.keySymbolsFree(syms);

    // 7c. Setup IPC socket
    var sock_path_buf: [256]u8 = undefined;
    const sock_path = ipc.getDefaultSocketPath(&sock_path_buf);

    const ipc_listen_fd = ipc.createServer(sock_path) catch |err| {
        std.debug.print("ERROR: cannot create IPC socket: {}\n", .{err});
        return err;
    };
    defer std.posix.close(ipc_listen_fd);

    // Set I3SOCK env var
    {
        var env_buf: [256]u8 = undefined;
        @memcpy(env_buf[0..sock_path.len], sock_path);
        env_buf[sock_path.len] = 0;
        const env_z: [*:0]const u8 = @ptrCast(env_buf[0..sock_path.len :0]);
        _ = setenv("I3SOCK", env_z, 1);
    }

    // Set _I3_SOCKET_PATH root window property
    _ = xcb.changeProperty(
        conn,
        xcb.PROP_MODE_REPLACE,
        root_window,
        atoms.i3_socket_path,
        atoms.utf8_string,
        8,
        @intCast(sock_path.len),
        sock_path.ptr,
    );
    _ = xcb.flush(conn);

    // IPC client fd tracking
    var ipc_client_fds: [MAX_IPC_CLIENTS]std.posix.fd_t = .{-1} ** MAX_IPC_CLIENTS;

    // IPC subscription tracking
    var ipc_sub_fds: [event.MAX_IPC_SUBS]std.posix.fd_t = .{-1} ** event.MAX_IPC_SUBS;
    var ipc_sub_masks: [event.MAX_IPC_SUBS]u8 = .{0} ** event.MAX_IPC_SUBS;

    std.debug.print("zephwm v{s} started (screen {}x{}, ipc: {s})\n", .{
        VERSION,
        screen.width_in_pixels,
        screen.height_in_pixels,
        sock_path,
    });

    // 8. Setup epoll
    const epoll_fd = linux.epoll_create1(0);
    if (@as(isize, @bitCast(epoll_fd)) < 0) {
        std.debug.print("ERROR: epoll_create1 failed\n", .{});
        return error.EpollCreateFailed;
    }
    defer std.posix.close(@intCast(epoll_fd));

    // Add xcb fd to epoll
    const xcb_fd: i32 = xcb.getFd(conn);
    var xcb_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = xcb_fd },
    };
    const ctl_result = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(xcb_fd), &xcb_event);
    if (@as(isize, @bitCast(ctl_result)) < 0) {
        std.debug.print("ERROR: epoll_ctl failed\n", .{});
        return error.EpollCtlFailed;
    }

    // Add IPC listen fd to epoll
    var ipc_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = IPC_LISTEN_FD_TAG },
    };
    {
        const ipc_ctl = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(ipc_listen_fd), &ipc_event);
        if (@as(isize, @bitCast(ipc_ctl)) < 0) {
            std.debug.print("ERROR: epoll_ctl for IPC fd failed\n", .{});
            return error.EpollCtlFailed;
        }
    }

    // 8a. Setup signalfd for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGUSR1
    var sig_mask = std.mem.zeroes(linux.sigset_t);
    linux.sigaddset(&sig_mask, linux.SIG.CHLD);
    linux.sigaddset(&sig_mask, linux.SIG.TERM);
    linux.sigaddset(&sig_mask, linux.SIG.INT);
    linux.sigaddset(&sig_mask, linux.SIG.HUP);
    linux.sigaddset(&sig_mask, linux.SIG.USR1);
    // Block these signals so they are delivered via signalfd instead
    _ = linux.sigprocmask(linux.SIG.BLOCK, &sig_mask, null);

    const sig_fd = linux.signalfd(-1, &sig_mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    const sig_fd_signed: isize = @bitCast(sig_fd);
    if (sig_fd_signed < 0) {
        std.debug.print("ERROR: signalfd failed\n", .{});
        return error.SignalfdFailed;
    }
    defer std.posix.close(@intCast(sig_fd));

    var sig_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = SIGNAL_FD_TAG },
    };
    {
        const sig_ctl = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(sig_fd), &sig_event);
        if (@as(isize, @bitCast(sig_ctl)) < 0) {
            std.debug.print("ERROR: epoll_ctl for signalfd failed\n", .{});
            return error.EpollCtlFailed;
        }
    }

    // 9. Event context
    var running: bool = true;
    var ctx = event.EventContext{
        .conn = conn,
        .root_window = root_window,
        .atoms = atoms,
        .tree_root = tree_root,
        .allocator = allocator,
        .running = &running,
        .current_mode = event.DEFAULT_MODE,
        .focus_follows_mouse = if (config) |cfg| cfg.focus_follows_mouse else true,
        .config = if (config) |*cfg| cfg else null,
        .key_symbols = key_symbols,
        .border_focus_color = border_focus_color,
        .border_unfocus_color = border_unfocus_color,
        .randr_base_event = randr_base_event,
        .ipc_sub_fds = &ipc_sub_fds,
        .ipc_sub_masks = &ipc_sub_masks,
    };

    // 10. Grab keys from config
    if (config) |*cfg| {
        event.grabKeys(&ctx, cfg);
    }

    // 11. Run exec/exec_always commands from config
    // exec: only on fresh start (not restart). exec_always: always.
    const is_restart = std.posix.getenv("ZEPHWM_RESTART") != null;
    if (config) |cfg| {
        if (!is_restart) {
            for (cfg.exec_cmds.items) |exec_cmd| {
                const cmd_str = std.fmt.allocPrint(allocator, "exec {s}", .{exec_cmd}) catch continue;
                defer allocator.free(cmd_str);
                if (command_mod.parse(cmd_str)) |cmd| {
                    event.executeCommand(&ctx, cmd);
                }
            }
        }
        for (cfg.exec_always_cmds.items) |exec_cmd| {
            const cmd_str = std.fmt.allocPrint(allocator, "exec {s}", .{exec_cmd}) catch continue;
            defer allocator.free(cmd_str);
            if (command_mod.parse(cmd_str)) |cmd| {
                event.executeCommand(&ctx, cmd);
            }
        }
    }

    // 11a. Spawn bar if configured
    if (config) |cfg| {
        if (cfg.bar.status_command.len > 0) {
            bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
        }
    }

    // 11b. Set initial EWMH properties
    event.updateClientList(&ctx);
    event.updateNumberOfDesktops(&ctx);
    event.updateCurrentDesktop(&ctx);
    event.updateDesktopNames(&ctx);
    event.updateActiveWindow(&ctx, xcb.WINDOW_NONE);
    _ = xcb.flush(conn);

    // 12. Event loop
    var events: [16]linux.epoll_event = undefined;

    while (running) {
        const nfds = linux.epoll_wait(@intCast(epoll_fd), &events, events.len, 100);
        const nfds_signed: isize = @bitCast(nfds);

        if (nfds_signed < 0) {
            const err = linux.E.init(nfds);
            if (err == .INTR) continue;
            std.debug.print("ERROR: epoll_wait failed: {}\n", .{err});
            break;
        }

        for (events[0..@intCast(nfds_signed)]) |ev| {
            if (ev.data.fd == xcb_fd) {
                // Drain all pending X events
                while (xcb.pollForEvent(conn)) |xevent| {
                    event.handleEvent(&ctx, xevent);
                    std.c.free(xevent);
                }
                // Batch flush after processing all X events
                _ = xcb.flush(conn);

                // Check for connection errors
                if (xcb.connectionHasError(conn) != 0) {
                    std.debug.print("X connection lost\n", .{});
                    running = false;
                    break;
                }
            }
            if (ev.data.fd == IPC_LISTEN_FD_TAG) {
                // Accept new IPC client
                const client_fd = ipc.acceptClient(ipc_listen_fd) catch continue;
                // Find a slot
                var added = false;
                for (&ipc_client_fds) |*slot| {
                    if (slot.* == -1) {
                        slot.* = client_fd;
                        var client_ev = linux.epoll_event{
                            .events = linux.EPOLL.IN,
                            .data = .{ .fd = client_fd },
                        };
                        const ctl_res = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(client_fd), &client_ev);
                        if (@as(isize, @bitCast(ctl_res)) < 0) {
                            std.posix.close(client_fd);
                            break;
                        }
                        added = true;
                        break;
                    }
                }
                if (!added) {
                    std.posix.close(client_fd); // too many clients
                }
            } else blk: {
                // Check if this is an IPC client fd
                for (&ipc_client_fds) |*slot| {
                    if (slot.* == ev.data.fd) {
                        // Process all available messages (handles back-to-back sends)
                        while (true) {
                            var msg_buf: [4096]u8 = undefined;
                            const msg_result = ipc.readMessage(ev.data.fd, &msg_buf) catch {
                                // WouldBlock: no more data available
                                break;
                            };
                            if (msg_result) |msg| {
                                handleIpcMessage(&ctx, ev.data.fd, msg.msg_type, msg.payload);
                            } else {
                                // Client disconnected (EOF)
                                _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_DEL, @intCast(ev.data.fd), null);
                                // Clean up any IPC subscriptions for this fd
                                for (0..event.MAX_IPC_SUBS) |si| {
                                    if (ipc_sub_fds[si] == ev.data.fd) {
                                        ipc_sub_fds[si] = -1;
                                        ipc_sub_masks[si] = 0;
                                    }
                                }
                                std.posix.close(ev.data.fd);
                                slot.* = -1;
                                break;
                            }
                        }
                        // Flush after IPC commands (may have issued X11 requests)
                        _ = xcb.flush(conn);
                        break :blk;
                    }
                }
            }
            if (ev.data.fd == SIGNAL_FD_TAG) {
                // Read signalfd_siginfo structs
                var sigbuf: [@sizeOf(linux.signalfd_siginfo)]u8 align(@alignOf(linux.signalfd_siginfo)) = undefined;
                while (true) {
                    const n = linux.read(@intCast(sig_fd), &sigbuf, sigbuf.len);
                    const n_signed: isize = @bitCast(n);
                    if (n_signed <= 0) break;
                    const info: *const linux.signalfd_siginfo = @ptrCast(&sigbuf);
                    switch (info.signo) {
                        linux.SIG.CHLD => {
                            // Reap all zombie children using wait4(-1, ..., WNOHANG)
                            var wstatus: u32 = 0;
                            while (true) {
                                const res = linux.wait4(-1, &wstatus, linux.W.NOHANG, null);
                                const res_signed: isize = @bitCast(res);
                                if (res_signed <= 0) break; // no more zombies or error
                            }
                        },
                        linux.SIG.TERM, linux.SIG.INT => {
                            running = false;
                        },
                        linux.SIG.HUP => {
                            // Restart via re-exec (same as "restart" command)
                            event.executeRestart(&ctx);
                            // If re-exec failed, just exit
                            running = false;
                        },
                        linux.SIG.USR1 => {
                            // Reload config
                            std.debug.print("zephwm: SIGUSR1 received, reloading config\n", .{});
                            if (config) |*cfg| cfg.deinit();
                            config = loadConfig(allocator);
                            if (config) |*cfg| {
                                border_focus_color = parseColor(cfg.focused_border);
                                border_unfocus_color = parseColor(cfg.unfocused_border);
                                ctx.border_focus_color = border_focus_color;
                                ctx.border_unfocus_color = border_unfocus_color;
                                ctx.focus_follows_mouse = cfg.focus_follows_mouse;
                                ctx.config = cfg;
                                event.grabKeys(&ctx, cfg);
                            } else {
                                ctx.config = null;
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    // Unreparent all client windows back to root (ICCCM)
    event.unreparentAll(&ctx);

    // Cleanup IPC clients
    for (&ipc_client_fds) |*slot| {
        if (slot.* != -1) {
            std.posix.close(slot.*);
            slot.* = -1;
        }
    }

    // Remove socket file
    std.posix.unlinkat(std.posix.AT.FDCWD, sock_path, 0) catch {};

    // Free allocator-owned mode string (if not the static DEFAULT_MODE sentinel)
    if (ctx.current_mode.ptr != event.DEFAULT_MODE.ptr) {
        allocator.free(ctx.current_mode);
    }

    // Free static buffers
    ctx.window_map.deinit(allocator);
    tree_json_buf.deinit(allocator);

    std.debug.print("zephwm shutting down\n", .{});
}
