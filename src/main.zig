// ziawm — i3-compatible tiling window manager
const std = @import("std");
const xcb = @import("xcb.zig");
const atoms_mod = @import("atoms.zig");
const tree = @import("tree.zig");
const output = @import("output.zig");
const event = @import("event.zig");
const render = @import("render.zig");
const linux = std.os.linux;

const VERSION = "0.1.0";

// Default border colors (can be overridden by config later)
const BORDER_FOCUS_COLOR: u32 = 0x4c7899;
const BORDER_UNFOCUS_COLOR: u32 = 0x333333;

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

    std.debug.print("ziawm v{s} started (screen {}x{})\n", .{
        VERSION,
        screen.width_in_pixels,
        screen.height_in_pixels,
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

    // TODO: Add IPC fd to epoll (Task 13)
    // TODO: Add signalfd to epoll (Task 19)

    // 9. Event loop
    var running: bool = true;
    var ctx = event.EventContext{
        .conn = conn,
        .root_window = root_window,
        .atoms = atoms,
        .tree_root = tree_root,
        .allocator = allocator,
        .running = &running,
        .current_mode = "default",
        .focus_follows_mouse = true,
    };

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
            // TODO: handle IPC fd (Task 13)
            // TODO: handle signalfd (Task 19)
        }

        // Re-render after processing events
        render.applyTree(conn, tree_root, BORDER_FOCUS_COLOR, BORDER_UNFOCUS_COLOR);
    }

    std.debug.print("ziawm shutting down\n", .{});
}
