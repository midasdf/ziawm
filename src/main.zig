// ziawm — i3-compatible tiling window manager
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
const linux = std.os.linux;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const VERSION = "0.1.0";

// Default border colors (can be overridden by config)
const DEFAULT_BORDER_FOCUS_COLOR: u32 = 0x4c7899;
const DEFAULT_BORDER_UNFOCUS_COLOR: u32 = 0x333333;

// IPC constants
const IPC_LISTEN_FD_TAG: i32 = -100; // sentinel for epoll data.fd
const MAX_IPC_CLIENTS: usize = 16;

fn handleIpcMessage(ctx: *event.EventContext, client_fd: std.posix.fd_t, msg_type: u32, payload: []const u8) void {
    const response: []const u8 = switch (msg_type) {
        @intFromEnum(ipc.MessageType.get_version) =>
            "{\"human_readable\":\"ziawm " ++ VERSION ++ "\",\"loaded_config_file_name\":\"\",\"minor\":1,\"major\":0,\"patch\":0}",
        @intFromEnum(ipc.MessageType.run_command) => blk: {
            // Execute the command
            if (payload.len > 0) {
                if (command_mod.parse(payload)) |cmd| {
                    event.executeCommand(ctx, cmd);
                }
            }
            break :blk "[{\"success\":true}]";
        },
        @intFromEnum(ipc.MessageType.get_workspaces) => "[]",
        @intFromEnum(ipc.MessageType.get_outputs) => "[]",
        @intFromEnum(ipc.MessageType.get_tree) => "{}",
        @intFromEnum(ipc.MessageType.get_marks) => "[]",
        @intFromEnum(ipc.MessageType.get_bar_config) => "{}",
        @intFromEnum(ipc.MessageType.get_config) => "{}",
        @intFromEnum(ipc.MessageType.get_binding_modes) => "[\"default\"]",
        @intFromEnum(ipc.MessageType.subscribe) => "{\"success\":true}",
        @intFromEnum(ipc.MessageType.send_tick) => "{\"success\":true}",
        else => "{}",
    };

    ipc.writeResponse(client_fd, msg_type, response) catch {};
}

/// Try to load config from standard paths. Returns null if no config found.
fn loadConfig(allocator: std.mem.Allocator) ?config_mod.Config {
    // Search paths in order
    const home = std.posix.getenv("HOME") orelse "";
    const xdg_config = std.posix.getenv("XDG_CONFIG_HOME");

    var path_buf: [512]u8 = undefined;

    // 1. XDG_CONFIG_HOME/ziawm/config
    if (xdg_config) |xdg| {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/ziawm/config", .{xdg}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 2. ~/.config/ziawm/config
    {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/.config/ziawm/config", .{home}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 3. ~/.ziawm/config
    {
        const len = (std.fmt.bufPrint(&path_buf, "{s}/.ziawm/config", .{home}) catch "").len;
        if (len > 0) {
            if (readConfigFile(allocator, path_buf[0..len])) |cfg| return cfg;
        }
    }

    // 4. /etc/ziawm/config
    if (readConfigFile(allocator, "/etc/ziawm/config")) |cfg| return cfg;

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
            std.debug.print("ziawm v{s}\n", .{VERSION});
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: ziawm [--version] [--help]\n", .{});
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
        _ = xcb.changeProperty(conn, xcb.PROP_MODE_REPLACE, wm_check_window, atoms.net_wm_name, atoms.utf8_string, 8, 5, "ziawm");
    }

    // 7. Create tree root and detect outputs
    const tree_root = try tree.Container.create(allocator, .root);
    defer tree_root.destroy(allocator);

    try output.detectOutputs(conn, tree_root, allocator);

    _ = xcb.flush(conn);

    // 7a. Load config
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

    std.debug.print("ziawm v{s} started (screen {}x{}, ipc: {s})\n", .{
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

    // TODO: Add signalfd to epoll (Task 19)

    // 9. Event context
    var running: bool = true;
    var ctx = event.EventContext{
        .conn = conn,
        .root_window = root_window,
        .atoms = atoms,
        .tree_root = tree_root,
        .allocator = allocator,
        .running = &running,
        .current_mode = "default",
        .focus_follows_mouse = if (config) |cfg| cfg.focus_follows_mouse else true,
        .config = if (config) |*cfg| cfg else null,
        .key_symbols = key_symbols,
        .border_focus_color = border_focus_color,
        .border_unfocus_color = border_unfocus_color,
    };

    // 10. Grab keys from config
    if (config) |*cfg| {
        event.grabKeys(&ctx, cfg);
    }

    // 11. Run exec commands from config
    if (config) |cfg| {
        for (cfg.exec_cmds.items) |exec_cmd| {
            if (command_mod.parse(std.fmt.allocPrint(allocator, "exec {s}", .{exec_cmd}) catch continue)) |cmd| {
                event.executeCommand(&ctx, cmd);
            }
        }
    }

    // 12. Event loop
    var events: [16]linux.epoll_event = undefined;

    while (running) {
        const nfds = linux.epoll_wait(@intCast(epoll_fd), &events, events.len, -1);
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
                        _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(client_fd), &client_ev);
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
                        var msg_buf: [4096]u8 = undefined;
                        if (ipc.readMessage(ev.data.fd, &msg_buf)) |msg| {
                            handleIpcMessage(&ctx, ev.data.fd, msg.msg_type, msg.payload);
                        } else {
                            // Client disconnected or error
                            _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_DEL, @intCast(ev.data.fd), null);
                            std.posix.close(ev.data.fd);
                            slot.* = -1;
                        }
                        break :blk;
                    }
                }
            }
            // TODO: handle signalfd (Task 19)
        }
    }

    // Cleanup IPC clients
    for (&ipc_client_fds) |*slot| {
        if (slot.* != -1) {
            std.posix.close(slot.*);
            slot.* = -1;
        }
    }

    // Remove socket file
    std.posix.unlinkat(std.posix.AT.FDCWD, sock_path, 0) catch {};

    std.debug.print("ziawm shutting down\n", .{});
}
