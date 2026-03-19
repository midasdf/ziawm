// zephwm-bar — status bar for zephwm
// Renders workspace buttons + status text using XCB + Xft
const std = @import("std");
const ipc = @import("ipc");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("X11/Xft/Xft.h");
});

const VERSION = "0.1.0";
const BAR_HEIGHT: u16 = 20;
const WS_BUTTON_PAD: u16 = 10; // horizontal padding per workspace button
const STATUS_PAD: u16 = 8;

// Colors
const BG_COLOR: u32 = 0x222222;
const FG_COLOR_STR = "#dddddd";
const FOCUSED_BG: u32 = 0x285577;
const FOCUSED_FG_STR = "#ffffff";
const URGENT_BG: u32 = 0x900000;
const UNFOCUSED_FG_STR = "#888888";
const FONT_NAME = "monospace:size=10";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    var socket_override: ?[]const u8 = null;
    var position_top = true;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zephwm-bar v{s}\n", .{VERSION});
            return;
        }
        if (std.mem.eql(u8, arg, "--bottom") or std.mem.eql(u8, arg, "-b")) {
            position_top = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            socket_override = args.next();
            continue;
        }
    }

    // 1. Open Xlib display (needed for Xft)
    const dpy = c.XOpenDisplay(null) orelse {
        std.debug.print("zephwm-bar: cannot open display\n", .{});
        return;
    };
    defer _ = c.XCloseDisplay(dpy);

    const screen_num = c.XDefaultScreen(dpy);
    const root = c.XRootWindow(dpy, screen_num);
    const visual = c.XDefaultVisual(dpy, screen_num);
    const colormap = c.XDefaultColormap(dpy, screen_num);
    const screen_width: u16 = @intCast(c.XDisplayWidth(dpy, screen_num));
    const screen_height: u16 = @intCast(c.XDisplayHeight(dpy, screen_num));

    // Get XCB connection from Xlib
    const conn = c.XGetXCBConnection(dpy) orelse {
        std.debug.print("zephwm-bar: cannot get XCB connection\n", .{});
        return;
    };

    // 2. Create bar window
    const bar_y: i16 = if (position_top) 0 else @intCast(screen_height - BAR_HEIGHT);
    const bar_win = c.xcb_generate_id(conn);
    {
        const values = [_]u32{
            BG_COLOR, // back pixel
            1,        // override_redirect
            c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS,
        };
        _ = c.xcb_create_window(
            conn,
            c.XCB_COPY_FROM_PARENT,
            bar_win,
            @intCast(root),
            0,
            bar_y,
            screen_width,
            BAR_HEIGHT,
            0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            @intCast(c.XDefaultVisual(dpy, screen_num).*.visualid),
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK,
            &values,
        );
    }

    // Set _NET_WM_WINDOW_TYPE to DOCK
    {
        const type_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE");
        const dock_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
        if (type_atom != 0 and dock_atom != 0) {
            const val = [_]u32{dock_atom};
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, bar_win, type_atom, c.XCB_ATOM_ATOM, 32, 1, @ptrCast(&val));
        }
    }

    // Set _NET_WM_STRUT to reserve space
    {
        const strut_atom = internAtom(conn, "_NET_WM_STRUT");
        if (strut_atom != 0) {
            var strut = [_]u32{ 0, 0, 0, 0 }; // left, right, top, bottom
            if (position_top) {
                strut[2] = BAR_HEIGHT;
            } else {
                strut[3] = BAR_HEIGHT;
            }
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, bar_win, strut_atom, c.XCB_ATOM_CARDINAL, 32, 4, @ptrCast(&strut));
        }
    }

    _ = c.xcb_map_window(conn, bar_win);
    _ = c.xcb_flush(conn);

    // Need to sync Xlib with XCB state
    _ = c.XSync(dpy, 0);

    // 3. Init Xft
    const font = c.XftFontOpenName(dpy, screen_num, FONT_NAME) orelse {
        std.debug.print("zephwm-bar: cannot open font '{s}'\n", .{FONT_NAME});
        return;
    };
    defer c.XftFontClose(dpy, font);

    const draw = c.XftDrawCreate(dpy, bar_win, visual, colormap) orelse {
        std.debug.print("zephwm-bar: cannot create XftDraw\n", .{});
        return;
    };
    defer c.XftDrawDestroy(draw);

    // Pre-allocate colors
    var fg_color: c.XftColor = undefined;
    var focused_fg: c.XftColor = undefined;
    var unfocused_fg: c.XftColor = undefined;
    _ = c.XftColorAllocName(dpy, visual, colormap, FG_COLOR_STR, &fg_color);
    _ = c.XftColorAllocName(dpy, visual, colormap, FOCUSED_FG_STR, &focused_fg);
    _ = c.XftColorAllocName(dpy, visual, colormap, UNFOCUSED_FG_STR, &unfocused_fg);
    defer c.XftColorFree(dpy, visual, colormap, &fg_color);
    defer c.XftColorFree(dpy, visual, colormap, &focused_fg);
    defer c.XftColorFree(dpy, visual, colormap, &unfocused_fg);

    // 4. Create GC for filling rectangles
    const gc = c.xcb_generate_id(conn);
    {
        const gc_values = [_]u32{ BG_COLOR, 0 };
        _ = c.xcb_create_gc(conn, gc, bar_win, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &gc_values);
    }
    defer _ = c.xcb_free_gc(conn, gc);

    // 5. Discover IPC socket
    var default_path_buf: [256]u8 = undefined;
    const default_path = ipc.getDefaultSocketPath(&default_path_buf);
    const sock_path = socket_override orelse
        (std.posix.getenv("I3SOCK") orelse default_path);

    // Status text buffer
    var status_text: [512]u8 = undefined;
    const status_len: usize = 0;

    // Workspace info cache
    const MaxWorkspaces = 16;
    var ws_names: [MaxWorkspaces][32]u8 = undefined;
    var ws_name_lens: [MaxWorkspaces]u8 = .{0} ** MaxWorkspaces;
    var ws_focused: [MaxWorkspaces]bool = .{false} ** MaxWorkspaces;
    var ws_urgent: [MaxWorkspaces]bool = .{false} ** MaxWorkspaces;
    var ws_count: usize = 0;

    std.debug.print("zephwm-bar v{s} started (ipc: {s})\n", .{ VERSION, sock_path });

    // 6. Main loop: epoll on XCB fd with 500ms timeout for workspace refresh
    const linux = std.os.linux;
    const xcb_fd: i32 = c.xcb_get_file_descriptor(conn);
    const epoll_fd = linux.epoll_create1(0);
    if (@as(isize, @bitCast(epoll_fd)) < 0) {
        std.debug.print("zephwm-bar: epoll_create1 failed\n", .{});
        return;
    }
    defer std.posix.close(@intCast(epoll_fd));

    var xcb_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = xcb_fd },
    };
    _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(xcb_fd), &xcb_event);

    var running = true;
    // Initial refresh + draw
    refreshWorkspaces(allocator, sock_path, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_count);
    drawBar(conn, dpy, draw, font, gc, bar_win, screen_width, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, ws_count, status_text[0..status_len], &focused_fg, &unfocused_fg, &fg_color);

    while (running) {
        // Wait for X events or 500ms timeout (for workspace refresh)
        var events: [4]linux.epoll_event = undefined;
        const nfds = linux.epoll_wait(@intCast(epoll_fd), &events, events.len, 500);
        const nfds_signed: isize = @bitCast(nfds);

        if (nfds_signed < 0) {
            const err = linux.E.init(nfds);
            if (err == .INTR) continue;
            break;
        }

        // Process X events
        _ = c.XSync(dpy, 0);
        while (c.xcb_poll_for_event(conn)) |ev| {
            const response_type = ev.*.response_type & 0x7f;
            switch (response_type) {
                c.XCB_EXPOSE => {
                    drawBar(conn, dpy, draw, font, gc, bar_win, screen_width, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, ws_count, status_text[0..status_len], &focused_fg, &unfocused_fg, &fg_color);
                },
                c.XCB_BUTTON_PRESS => {
                    const bev: *c.xcb_button_press_event_t = @ptrCast(ev);
                    handleClick(allocator, sock_path, bev.event_x, &ws_names, &ws_name_lens, ws_count, font, dpy);
                },
                else => {},
            }
            std.c.free(ev);

            if (c.xcb_connection_has_error(conn) != 0) {
                running = false;
                break;
            }
        }

        if (c.xcb_connection_has_error(conn) != 0) break;

        // Refresh workspace state on timeout or after processing events
        refreshWorkspaces(allocator, sock_path, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_count);
        drawBar(conn, dpy, draw, font, gc, bar_win, screen_width, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, ws_count, status_text[0..status_len], &focused_fg, &unfocused_fg, &fg_color);
    }

    std.debug.print("zephwm-bar shutting down\n", .{});
}

fn drawBar(
    conn: *c.xcb_connection_t,
    dpy: *c.Display,
    draw: *c.XftDraw,
    font: *c.XftFont,
    gc: u32,
    bar_win: u32,
    screen_width: u16,
    ws_names: *[16][32]u8,
    ws_name_lens: *[16]u8,
    ws_focused: *[16]bool,
    ws_urgent: *[16]bool,
    ws_count: usize,
    status: []const u8,
    focused_fg: *c.XftColor,
    unfocused_fg: *c.XftColor,
    fg_color: *c.XftColor,
) void {
    // Clear background
    const bg_values = [_]u32{BG_COLOR};
    _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &bg_values);
    const rect = [_]c.xcb_rectangle_t{.{ .x = 0, .y = 0, .width = screen_width, .height = BAR_HEIGHT }};
    _ = c.xcb_poly_fill_rectangle(conn, bar_win, gc, 1, &rect);

    const text_y: c_int = @intCast(font.*.ascent + 2);
    var x: u16 = 0;

    // Draw workspace buttons
    for (0..ws_count) |i| {
        const name_len = ws_name_lens[i];
        if (name_len == 0) continue;
        const name = ws_names[i][0..name_len];

        // Calculate button width from text
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(dpy, font, name.ptr, @intCast(name.len), &extents);
        const btn_w: u16 = @intCast(@as(u32, @intCast(extents.xOff)) + WS_BUTTON_PAD * 2);

        // Draw background for focused/urgent workspaces
        if (ws_focused[i] or ws_urgent[i]) {
            const bg = if (ws_urgent[i]) URGENT_BG else FOCUSED_BG;
            const bg_val = [_]u32{bg};
            _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &bg_val);
            const btn_rect = [_]c.xcb_rectangle_t{.{ .x = @intCast(x), .y = 0, .width = btn_w, .height = BAR_HEIGHT }};
            _ = c.xcb_poly_fill_rectangle(conn, bar_win, gc, 1, &btn_rect);
        }

        // Draw text
        _ = c.XSync(dpy, 0);
        const color = if (ws_focused[i]) focused_fg else if (ws_urgent[i]) focused_fg else unfocused_fg;
        c.XftDrawStringUtf8(draw, color, font, @intCast(x + WS_BUTTON_PAD), text_y, name.ptr, @intCast(name.len));

        x += btn_w;
    }

    // Draw status text (right-aligned)
    if (status.len > 0) {
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(dpy, font, status.ptr, @intCast(status.len), &extents);
        const status_x: c_int = @intCast(screen_width - @as(u16, @intCast(extents.xOff)) - STATUS_PAD);
        c.XftDrawStringUtf8(draw, fg_color, font, status_x, text_y, status.ptr, @intCast(status.len));
    }

    _ = c.XSync(dpy, 0);
    _ = c.xcb_flush(conn);
}

fn handleClick(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    click_x: i16,
    ws_names: *[16][32]u8,
    ws_name_lens: *[16]u8,
    ws_count: usize,
    font: *c.XftFont,
    dpy: *c.Display,
) void {
    // Determine which workspace button was clicked
    var x: u16 = 0;
    for (0..ws_count) |i| {
        const name_len = ws_name_lens[i];
        if (name_len == 0) continue;
        const name = ws_names[i][0..name_len];

        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(dpy, font, name.ptr, @intCast(name.len), &extents);
        const btn_w: u16 = @intCast(@as(u32, @intCast(extents.xOff)) + WS_BUTTON_PAD * 2);

        if (click_x >= @as(i16, @intCast(x)) and click_x < @as(i16, @intCast(x + btn_w))) {
            // Send workspace switch command via IPC
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "workspace {s}", .{name}) catch return;
            sendIpcCommand(allocator, sock_path, cmd);
            return;
        }
        x += btn_w;
    }
}

fn refreshWorkspaces(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    ws_names: *[16][32]u8,
    ws_name_lens: *[16]u8,
    ws_focused: *[16]bool,
    ws_urgent: *[16]bool,
    ws_count: *usize,
) void {
    // Connect to IPC and send GET_WORKSPACES
    const response = ipc.sendRequest(allocator, sock_path, .get_workspaces, "") orelse return;
    defer allocator.free(response);

    // Parse JSON response (simple manual parsing)
    ws_count.* = 0;
    var pos: usize = 0;
    while (pos < response.len and ws_count.* < 16) {
        // Find next "name":"
        const name_key = std.mem.indexOf(u8, response[pos..], "\"name\":\"") orelse break;
        const name_start = pos + name_key + 8;
        const name_end = std.mem.indexOfScalar(u8, response[name_start..], '"') orelse break;
        const name = response[name_start .. name_start + name_end];

        // Find focused
        const focused_key = std.mem.indexOf(u8, response[name_start..], "\"focused\":") orelse break;
        const focused_val = response[name_start + focused_key + 10 ..];
        const is_focused = std.mem.startsWith(u8, focused_val, "true");

        // Find urgent
        var is_urgent = false;
        if (std.mem.indexOf(u8, response[name_start..], "\"urgent\":")) |urgent_key| {
            const urgent_val = response[name_start + urgent_key + 9 ..];
            is_urgent = std.mem.startsWith(u8, urgent_val, "true");
        }

        const idx = ws_count.*;
        const copy_len = @min(name.len, 32);
        @memcpy(ws_names[idx][0..copy_len], name[0..copy_len]);
        ws_name_lens[idx] = @intCast(copy_len);
        ws_focused[idx] = is_focused;
        ws_urgent[idx] = is_urgent;
        ws_count.* += 1;

        pos = name_start + name_end + 1;
    }
}

fn sendIpcCommand(allocator: std.mem.Allocator, sock_path: []const u8, command: []const u8) void {
    const resp = ipc.sendRequest(allocator, sock_path, .run_command, command) orelse return;
    allocator.free(resp);
}

fn internAtom(conn: *c.xcb_connection_t, name: [*:0]const u8) u32 {
    const len: u16 = @intCast(std.mem.len(name));
    const cookie = c.xcb_intern_atom(conn, 0, len, name);
    const reply = c.xcb_intern_atom_reply(conn, cookie, null) orelse return 0;
    defer std.c.free(reply);
    return reply.*.atom;
}
