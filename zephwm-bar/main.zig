// zephwm-bar — status bar for zephwm
// Renders workspace buttons + status text using XCB + Xft
// Supports per-output bars: one bar window per monitor output.
const std = @import("std");
const ipc = @import("ipc");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("X11/Xft/Xft.h");
});

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

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

const MAX_OUTPUTS = 8;
const MaxWorkspaces = 16;

const BarWindow = struct {
    output_name: [64]u8 = undefined,
    output_name_len: u8 = 0,
    window_id: u32 = 0,
    draw: ?*c.XftDraw = null,
    x: i16 = 0,
    width: u16 = 0,
    output_y: i16 = 0,
    output_height: u16 = 0,
    // Per-bar render geometry for status blocks (avoids shared state across bars)
    block_render_x: [MAX_STATUS_BLOCKS]u16 = .{0} ** MAX_STATUS_BLOCKS,
    block_render_w: [MAX_STATUS_BLOCKS]u16 = .{0} ** MAX_STATUS_BLOCKS,

    fn getOutputName(self: *const BarWindow) []const u8 {
        return self.output_name[0..self.output_name_len];
    }
};

const StatusBlock = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    instance: [64]u8 = undefined,
    instance_len: u8 = 0,
    full_text: [256]u8 = undefined,
    full_text_len: u16 = 0,
};

const MAX_STATUS_BLOCKS = 32;

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
    const visual_id: u32 = @intCast(visual.*.visualid);

    // Get XCB connection from Xlib
    const conn = c.XGetXCBConnection(dpy) orelse {
        std.debug.print("zephwm-bar: cannot get XCB connection\n", .{});
        return;
    };

    // 2. Discover IPC socket (needed before output discovery)
    var default_path_buf: [256]u8 = undefined;
    const default_path = ipc.getDefaultSocketPath(&default_path_buf);
    const sock_path = socket_override orelse
        (std.posix.getenv("I3SOCK") orelse default_path);

    // 3. Discover outputs via IPC and create per-output bar windows
    var bars: [MAX_OUTPUTS]BarWindow = undefined;
    for (&bars) |*b| b.* = .{};
    var bar_count: usize = 0;

    // Try to discover outputs from the WM
    discoverOutputs(allocator, sock_path, &bars, &bar_count);

    // Fallback: single screen-wide bar if no outputs discovered
    if (bar_count == 0) {
        bars[0] = .{
            .output_name_len = 0, // empty = match all outputs
            .x = 0,
            .width = screen_width,
            .output_y = 0,
            .output_height = screen_height,
        };
        bar_count = 1;
    }

    // Create X windows for each bar
    const type_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE");
    const dock_atom = internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
    const strut_atom = internAtom(conn, "_NET_WM_STRUT_PARTIAL");

    for (bars[0..bar_count]) |*bar| {
        const bar_y: i16 = if (position_top) bar.output_y else bar.output_y + @as(i16, @intCast(bar.output_height)) - @as(i16, BAR_HEIGHT);
        const win_id = c.xcb_generate_id(conn);
        bar.window_id = win_id;

        const values = [_]u32{
            BG_COLOR, // back pixel
            1, // override_redirect
            c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS,
        };
        _ = c.xcb_create_window(
            conn,
            c.XCB_COPY_FROM_PARENT,
            win_id,
            @intCast(root),
            bar.x,
            bar_y,
            bar.width,
            BAR_HEIGHT,
            0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            visual_id,
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_OVERRIDE_REDIRECT | c.XCB_CW_EVENT_MASK,
            &values,
        );

        // Set _NET_WM_WINDOW_TYPE to DOCK
        if (type_atom != 0 and dock_atom != 0) {
            const val = [_]u32{dock_atom};
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, win_id, type_atom, c.XCB_ATOM_ATOM, 32, 1, @ptrCast(&val));
        }

        // Set _NET_WM_STRUT_PARTIAL scoped to this output's x-range
        if (strut_atom != 0) {
            // _NET_WM_STRUT_PARTIAL: left, right, top, bottom,
            //   left_start_y, left_end_y, right_start_y, right_end_y,
            //   top_start_x, top_end_x, bottom_start_x, bottom_end_x
            var strut = [_]u32{0} ** 12;
            const x_start: u32 = @intCast(@as(u32, @bitCast(@as(i32, bar.x))));
            const x_end: u32 = x_start + bar.width -| 1;
            if (position_top) {
                strut[2] = BAR_HEIGHT; // top
                strut[8] = x_start; // top_start_x
                strut[9] = x_end; // top_end_x
            } else {
                strut[3] = BAR_HEIGHT; // bottom
                strut[10] = x_start; // bottom_start_x
                strut[11] = x_end; // bottom_end_x
            }
            _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, win_id, strut_atom, c.XCB_ATOM_CARDINAL, 32, 12, @ptrCast(&strut));
        }

        _ = c.xcb_map_window(conn, win_id);
    }

    _ = c.xcb_flush(conn);
    _ = c.XSync(dpy, 0);

    // 4. Init Xft
    const font = c.XftFontOpenName(dpy, screen_num, FONT_NAME) orelse {
        std.debug.print("zephwm-bar: cannot open font '{s}'\n", .{FONT_NAME});
        return;
    };
    defer c.XftFontClose(dpy, font);

    // Create XftDraw per bar window
    for (bars[0..bar_count]) |*bar| {
        bar.draw = c.XftDrawCreate(dpy, bar.window_id, visual, colormap);
        if (bar.draw == null) {
            std.debug.print("zephwm-bar: cannot create XftDraw for output {s}\n", .{bar.getOutputName()});
        }
    }
    defer {
        for (bars[0..bar_count]) |*bar| {
            if (bar.draw) |d| c.XftDrawDestroy(d);
        }
    }

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

    // 5. Create GC for filling rectangles (shared across all bar windows, using first bar)
    const gc = c.xcb_generate_id(conn);
    {
        const gc_values = [_]u32{ BG_COLOR, 0 };
        _ = c.xcb_create_gc(conn, gc, bars[0].window_id, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &gc_values);
    }
    defer _ = c.xcb_free_gc(conn, gc);

    // Status block state (i3bar protocol support)
    var status_blocks: [MAX_STATUS_BLOCKS]StatusBlock = undefined;
    for (&status_blocks) |*b| b.* = .{};
    var status_block_count: usize = 0;
    var click_events_enabled: bool = false;
    var status_stdin_fd: std.posix.fd_t = -1;
    var json_mode: bool = false;
    var status_read_buf: [8192]u8 = undefined;
    var status_read_len: usize = 0;

    // Spawn status_command and read from its stdout via pipe
    var status_pipe_fd: std.posix.fd_t = -1;
    {
        // Get status_command from bar config via IPC
        const bar_cfg = ipc.sendRequest(allocator, sock_path, .get_bar_config, "") orelse null;
        var status_cmd: ?[]const u8 = null;
        if (bar_cfg) |cfg_json| {
            defer allocator.free(cfg_json);
            // Simple parse: find "status_command":"..."
            if (std.mem.indexOf(u8, cfg_json, "\"status_command\":\"")) |pos| {
                const start = pos + 18;
                if (std.mem.indexOfScalar(u8, cfg_json[start..], '"')) |end| {
                    status_cmd = cfg_json[start .. start + end];
                }
            }
        }
        if (status_cmd) |cmd| {
            if (cmd.len > 0) {
                const spawn_result = spawnStatusCommand(cmd);
                status_pipe_fd = spawn_result.stdout_fd;
                status_stdin_fd = spawn_result.stdin_fd;
            }
        }
    }

    // Workspace info cache
    var ws_names: [MaxWorkspaces][32]u8 = undefined;
    var ws_name_lens: [MaxWorkspaces]u8 = .{0} ** MaxWorkspaces;
    var ws_focused: [MaxWorkspaces]bool = .{false} ** MaxWorkspaces;
    var ws_urgent: [MaxWorkspaces]bool = .{false} ** MaxWorkspaces;
    var ws_outputs: [MaxWorkspaces][64]u8 = undefined;
    var ws_output_lens: [MaxWorkspaces]u8 = .{0} ** MaxWorkspaces;
    var ws_count: usize = 0;

    std.debug.print("zephwm-bar v{s} started (ipc: {s}, outputs: {d})\n", .{ VERSION, sock_path, bar_count });

    // 6. Main loop: epoll on XCB fd with 500ms timeout for workspace refresh
    const linux = std.os.linux;
    const xcb_fd: i32 = c.xcb_get_file_descriptor(conn);
    const epoll_fd = linux.epoll_create1(0);
    if (@as(isize, @bitCast(epoll_fd)) < 0) {
        std.debug.print("zephwm-bar: epoll_create1 failed\n", .{});
        return;
    }
    defer std.posix.close(@intCast(epoll_fd));

    // Add status pipe fd to epoll if available
    if (status_pipe_fd >= 0) {
        var pipe_event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = status_pipe_fd },
        };
        _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(status_pipe_fd), &pipe_event);
    }

    var xcb_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = xcb_fd },
    };
    _ = linux.epoll_ctl(@intCast(epoll_fd), linux.EPOLL.CTL_ADD, @intCast(xcb_fd), &xcb_event);

    var running = true;
    // Initial refresh + draw
    refreshWorkspaces(allocator, sock_path, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_outputs, &ws_output_lens, &ws_count);
    for (bars[0..bar_count]) |*bar| {
        drawBar(conn, dpy, bar, font, gc, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_outputs, &ws_output_lens, ws_count, &status_blocks, status_block_count, &focused_fg, &unfocused_fg, &fg_color);
    }

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
                    const expose_ev: *c.xcb_expose_event_t = @ptrCast(ev);
                    // Find which bar window was exposed and redraw it
                    for (bars[0..bar_count]) |*bar| {
                        if (bar.window_id == expose_ev.window) {
                            drawBar(conn, dpy, bar, font, gc, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_outputs, &ws_output_lens, ws_count, &status_blocks, status_block_count, &focused_fg, &unfocused_fg, &fg_color);
                            break;
                        }
                    }
                },
                c.XCB_BUTTON_PRESS => {
                    const bev: *c.xcb_button_press_event_t = @ptrCast(ev);
                    // Find which bar window was clicked
                    for (bars[0..bar_count]) |*bar| {
                        if (bar.window_id == bev.event) {
                            handleClick(allocator, sock_path, bev.event_x, bev.detail, bev.event_y, bar, &ws_names, &ws_name_lens, &ws_outputs, &ws_output_lens, ws_count, font, dpy, &status_blocks, status_block_count, click_events_enabled, status_stdin_fd);
                            break;
                        }
                    }
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

        // Read status command output (non-blocking)
        if (status_pipe_fd >= 0) {
            const prev_click_enabled = click_events_enabled;
            parseStatusUpdate(status_pipe_fd, &status_blocks, &status_block_count, &click_events_enabled, &json_mode, &status_read_buf, &status_read_len);
            // When click_events first enabled, send the opening bracket
            if (click_events_enabled and !prev_click_enabled and status_stdin_fd >= 0) {
                _ = std.posix.write(status_stdin_fd, "[\n") catch {};
            }
        }

        // Refresh workspace state on timeout or after processing events
        refreshWorkspaces(allocator, sock_path, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_outputs, &ws_output_lens, &ws_count);
        for (bars[0..bar_count]) |*bar| {
            drawBar(conn, dpy, bar, font, gc, &ws_names, &ws_name_lens, &ws_focused, &ws_urgent, &ws_outputs, &ws_output_lens, ws_count, &status_blocks, status_block_count, &focused_fg, &unfocused_fg, &fg_color);
        }
    }

    std.debug.print("zephwm-bar shutting down\n", .{});
}

/// Discover outputs via IPC GET_OUTPUTS and populate bar array.
fn discoverOutputs(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    bars: *[MAX_OUTPUTS]BarWindow,
    bar_count: *usize,
) void {
    const response = ipc.sendRequest(allocator, sock_path, .get_outputs, "") orelse return;
    defer allocator.free(response);

    bar_count.* = 0;
    var pos: usize = 0;
    while (pos < response.len and bar_count.* < MAX_OUTPUTS) {
        // Find next "name":"
        const name_key = std.mem.indexOf(u8, response[pos..], "\"name\":\"") orelse break;
        const name_start = pos + name_key + 8;
        const name_end = std.mem.indexOfScalar(u8, response[name_start..], '"') orelse break;
        const name = response[name_start .. name_start + name_end];

        // Find "active":true/false
        const active_key = std.mem.indexOf(u8, response[name_start..], "\"active\":") orelse break;
        const active_val = response[name_start + active_key + 9 ..];
        const is_active = std.mem.startsWith(u8, active_val, "true");

        // Find rect: "rect":{"x":...,"y":...,"width":...,"height":...}
        var out_x: i16 = 0;
        var out_y: i16 = 0;
        var out_width: u16 = 0;
        var out_height: u16 = 0;
        if (std.mem.indexOf(u8, response[name_start..], "\"rect\":{")) |rect_key| {
            const rect_start = name_start + rect_key;
            // Parse x
            if (std.mem.indexOf(u8, response[rect_start..], "\"x\":")) |x_key| {
                const x_val_start = rect_start + x_key + 4;
                const x_val_end = findNumEnd(response, x_val_start);
                out_x = std.fmt.parseInt(i16, response[x_val_start..x_val_end], 10) catch 0;
            }
            // Parse y
            if (std.mem.indexOf(u8, response[rect_start..], "\"y\":")) |y_key| {
                const y_val_start = rect_start + y_key + 4;
                const y_val_end = findNumEnd(response, y_val_start);
                out_y = std.fmt.parseInt(i16, response[y_val_start..y_val_end], 10) catch 0;
            }
            // Parse width
            if (std.mem.indexOf(u8, response[rect_start..], "\"width\":")) |w_key| {
                const w_val_start = rect_start + w_key + 8;
                const w_val_end = findNumEnd(response, w_val_start);
                out_width = std.fmt.parseInt(u16, response[w_val_start..w_val_end], 10) catch 0;
            }
            // Parse height
            if (std.mem.indexOf(u8, response[rect_start..], "\"height\":")) |h_key| {
                const h_val_start = rect_start + h_key + 9;
                const h_val_end = findNumEnd(response, h_val_start);
                out_height = std.fmt.parseInt(u16, response[h_val_start..h_val_end], 10) catch 0;
            }
        }

        pos = name_start + name_end + 1;

        // Only add active outputs with non-zero width
        if (!is_active or out_width == 0) continue;

        const idx = bar_count.*;
        const copy_len = @min(name.len, @as(usize, 64));
        @memcpy(bars[idx].output_name[0..copy_len], name[0..copy_len]);
        bars[idx].output_name_len = @intCast(copy_len);
        bars[idx].x = out_x;
        bars[idx].width = out_width;
        bars[idx].output_y = out_y;
        bars[idx].output_height = out_height;
        bar_count.* += 1;
    }
}

/// Find end of a number in JSON (digits, minus sign).
fn findNumEnd(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        switch (data[i]) {
            '0'...'9', '-' => {},
            else => return i,
        }
    }
    return i;
}

fn drawBar(
    conn: *c.xcb_connection_t,
    dpy: *c.Display,
    bar: *BarWindow,
    font: *c.XftFont,
    gc: u32,
    ws_names: *[MaxWorkspaces][32]u8,
    ws_name_lens: *[MaxWorkspaces]u8,
    ws_focused: *[MaxWorkspaces]bool,
    ws_urgent: *[MaxWorkspaces]bool,
    ws_outputs: *[MaxWorkspaces][64]u8,
    ws_output_lens: *[MaxWorkspaces]u8,
    ws_count: usize,
    status_blocks: *[MAX_STATUS_BLOCKS]StatusBlock,
    status_block_count: usize,
    focused_fg: *c.XftColor,
    unfocused_fg: *c.XftColor,
    fg_color: *c.XftColor,
) void {
    const draw = bar.draw orelse return;
    const bar_win = bar.window_id;
    const bar_width = bar.width;
    const bar_output = bar.getOutputName();

    // Clear background
    const bg_values = [_]u32{BG_COLOR};
    _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &bg_values);
    const rect = [_]c.xcb_rectangle_t{.{ .x = 0, .y = 0, .width = bar_width, .height = BAR_HEIGHT }};
    _ = c.xcb_poly_fill_rectangle(conn, bar_win, gc, 1, &rect);

    const text_y: c_int = @intCast(font.*.ascent + 2);
    var x: u16 = 0;

    // Draw workspace buttons — only workspaces belonging to this output
    for (0..ws_count) |i| {
        const name_len = ws_name_lens[i];
        if (name_len == 0) continue;

        // Filter by output: show workspace only if it belongs to this bar's output
        // Empty bar_output (len=0) matches all outputs (fallback single-screen mode)
        if (bar_output.len > 0) {
            const ws_out_len = ws_output_lens[i];
            if (ws_out_len > 0) {
                const ws_out = ws_outputs[i][0..ws_out_len];
                if (!std.mem.eql(u8, ws_out, bar_output)) continue;
            }
        }

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

    // Draw status blocks (right-to-left)
    if (status_block_count > 0) {
        var status_x: u16 = bar_width;
        // Iterate blocks in reverse (rightmost first)
        var bi: usize = status_block_count;
        while (bi > 0) {
            bi -= 1;
            const blk = &status_blocks[bi];
            if (blk.full_text_len == 0) continue;

            const ft = blk.full_text[0..blk.full_text_len];
            var extents: c.XGlyphInfo = undefined;
            c.XftTextExtentsUtf8(dpy, font, ft.ptr, @intCast(ft.len), &extents);
            const text_w: u16 = @intCast(extents.xOff);
            const block_w: u16 = text_w + STATUS_PAD * 2;

            if (status_x < block_w) break; // no room
            status_x -= block_w;

            // Record render position for click detection (per-bar)
            bar.block_render_x[bi] = status_x;
            bar.block_render_w[bi] = block_w;

            // Draw text
            c.XftDrawStringUtf8(draw, fg_color, font, @intCast(status_x + STATUS_PAD), text_y, ft.ptr, @intCast(ft.len));
        }
    }

    _ = c.XSync(dpy, 0);
    _ = c.xcb_flush(conn);
}

fn handleClick(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    click_x: i16,
    button: u8,
    click_y: i16,
    bar: *const BarWindow,
    ws_names: *[MaxWorkspaces][32]u8,
    ws_name_lens: *[MaxWorkspaces]u8,
    ws_outputs: *[MaxWorkspaces][64]u8,
    ws_output_lens: *[MaxWorkspaces]u8,
    ws_count: usize,
    font: *c.XftFont,
    dpy: *c.Display,
    status_blocks: *[MAX_STATUS_BLOCKS]StatusBlock,
    status_block_count: usize,
    click_events_enabled: bool,
    status_stdin_fd: std.posix.fd_t,
) void {
    const bar_output = bar.getOutputName();
    // Determine which workspace button was clicked (only for this output's workspaces)
    var x: u16 = 0;
    for (0..ws_count) |i| {
        const name_len = ws_name_lens[i];
        if (name_len == 0) continue;

        // Filter by output (empty bar_output matches all)
        if (bar_output.len > 0) {
            const ws_out_len = ws_output_lens[i];
            if (ws_out_len > 0) {
                const ws_out = ws_outputs[i][0..ws_out_len];
                if (!std.mem.eql(u8, ws_out, bar_output)) continue;
            }
        }

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

    // Check status blocks for clicks (if click protocol enabled)
    if (click_events_enabled and status_stdin_fd >= 0) {
        for (0..status_block_count) |i| {
            const blk = &status_blocks[i];
            const bw_val = bar.block_render_w[i];
            if (bw_val == 0) continue;
            const bx = @as(i16, @intCast(bar.block_render_x[i]));
            const bw = @as(i16, @intCast(bw_val));
            if (click_x >= bx and click_x < bx + bw) {
                // Send click event to status_command stdin
                var click_buf: [512]u8 = undefined;
                var click_fbs = std.io.fixedBufferStream(&click_buf);
                const cw = click_fbs.writer();
                cw.writeAll(",{\"name\":\"") catch {};
                jsonEscapeWrite(cw, blk.name[0..blk.name_len]) catch {};
                cw.writeAll("\",\"instance\":\"") catch {};
                jsonEscapeWrite(cw, blk.instance[0..blk.instance_len]) catch {};
                cw.print("\",\"button\":{d}", .{button}) catch {};
                cw.print(",\"x\":{d},\"y\":{d}", .{ click_x, click_y }) catch {};
                cw.print(",\"relative_x\":{d},\"relative_y\":{d}", .{
                    click_x - bx, click_y,
                }) catch {};
                cw.print(",\"width\":{d},\"height\":{d}", .{ bw_val, BAR_HEIGHT }) catch {};
                cw.writeAll("}\n") catch {};
                _ = std.posix.write(status_stdin_fd, click_fbs.getWritten()) catch {};
                break;
            }
        }
    }
}

fn refreshWorkspaces(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    ws_names: *[MaxWorkspaces][32]u8,
    ws_name_lens: *[MaxWorkspaces]u8,
    ws_focused: *[MaxWorkspaces]bool,
    ws_urgent: *[MaxWorkspaces]bool,
    ws_outputs: *[MaxWorkspaces][64]u8,
    ws_output_lens: *[MaxWorkspaces]u8,
    ws_count: *usize,
) void {
    // Connect to IPC and send GET_WORKSPACES
    const response = ipc.sendRequest(allocator, sock_path, .get_workspaces, "") orelse return;
    defer allocator.free(response);

    // Parse JSON response (simple manual parsing)
    ws_count.* = 0;
    var pos: usize = 0;
    while (pos < response.len and ws_count.* < MaxWorkspaces) {
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

        // Find output
        var out_name: []const u8 = "";
        if (std.mem.indexOf(u8, response[name_start..], "\"output\":\"")) |out_key| {
            const out_start = name_start + out_key + 10;
            if (std.mem.indexOfScalar(u8, response[out_start..], '"')) |out_end| {
                out_name = response[out_start .. out_start + out_end];
            }
        }

        const idx = ws_count.*;
        const copy_len = @min(name.len, @as(usize, 32));
        @memcpy(ws_names[idx][0..copy_len], name[0..copy_len]);
        ws_name_lens[idx] = @intCast(copy_len);
        ws_focused[idx] = is_focused;
        ws_urgent[idx] = is_urgent;

        const out_copy_len = @min(out_name.len, @as(usize, 64));
        if (out_copy_len > 0) {
            @memcpy(ws_outputs[idx][0..out_copy_len], out_name[0..out_copy_len]);
        }
        ws_output_lens[idx] = @intCast(out_copy_len);

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

/// Spawn status_command via fork+pipe, returning both stdout (read) and stdin (write) fds.
fn spawnStatusCommand(cmd: []const u8) struct { stdout_fd: std.posix.fd_t, stdin_fd: std.posix.fd_t } {
    // stdout pipe (bar reads)
    const stdout_pipe = std.posix.pipe() catch return .{ .stdout_fd = -1, .stdin_fd = -1 };
    // stdin pipe (bar writes)
    const stdin_pipe = std.posix.pipe() catch {
        std.posix.close(stdout_pipe[0]);
        std.posix.close(stdout_pipe[1]);
        return .{ .stdout_fd = -1, .stdin_fd = -1 };
    };

    var cmd_buf: [512]u8 = undefined;
    const cmd_len = @min(cmd.len, cmd_buf.len - 1);
    @memcpy(cmd_buf[0..cmd_len], cmd[0..cmd_len]);
    cmd_buf[cmd_len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_len :0]);

    const pid = std.posix.fork() catch {
        std.posix.close(stdout_pipe[0]);
        std.posix.close(stdout_pipe[1]);
        std.posix.close(stdin_pipe[0]);
        std.posix.close(stdin_pipe[1]);
        return .{ .stdout_fd = -1, .stdin_fd = -1 };
    };

    if (pid == 0) {
        // Child
        std.posix.close(stdout_pipe[0]); // close read end of stdout
        std.posix.close(stdin_pipe[1]); // close write end of stdin
        _ = std.c.dup2(stdout_pipe[1], 1); // stdout = pipe
        _ = std.c.dup2(stdin_pipe[0], 0); // stdin = pipe
        std.posix.close(stdout_pipe[1]);
        std.posix.close(stdin_pipe[0]);

        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z };
        _ = execvp("/bin/sh", &argv);
        std.c._exit(1);
    }

    // Parent
    std.posix.close(stdout_pipe[1]); // close write end of stdout
    std.posix.close(stdin_pipe[0]); // close read end of stdin

    // Set stdout read to non-blocking
    const flags = std.posix.fcntl(stdout_pipe[0], std.posix.F.GETFL, 0) catch return .{ .stdout_fd = stdout_pipe[0], .stdin_fd = stdin_pipe[1] };
    _ = std.posix.fcntl(stdout_pipe[0], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))) catch {};

    std.debug.print("zephwm-bar: spawned status_command (pid {d})\n", .{pid});
    return .{ .stdout_fd = stdout_pipe[0], .stdin_fd = stdin_pipe[1] };
}

/// Parse status command output into StatusBlock array.
/// Supports both plain text and i3bar JSON protocol.
/// Uses a persistent buffer to handle lines that span multiple reads.
fn parseStatusUpdate(
    fd: std.posix.fd_t,
    blocks: *[MAX_STATUS_BLOCKS]StatusBlock,
    block_count: *usize,
    click_enabled: *bool,
    json_mode: *bool,
    persist_buf: *[8192]u8,
    persist_len: *usize,
) void {
    // Append new data to persistent buffer
    const remaining = persist_buf.len - persist_len.*;
    if (remaining == 0) {
        // Buffer full with no newline found — discard and reset
        persist_len.* = 0;
        return;
    }
    const n = std.posix.read(fd, persist_buf[persist_len.*..]) catch return;
    if (n == 0) return;
    persist_len.* += n;

    // Process all complete lines (terminated by \n) in the buffer
    var last_line: []const u8 = "";
    var last_line_end: usize = 0;
    {
        var line_start: usize = 0;
        for (persist_buf[0..persist_len.*], 0..) |ch, i| {
            if (ch == '\n') {
                if (i > line_start) {
                    last_line = persist_buf[line_start..i];
                }
                last_line_end = i + 1;
                line_start = i + 1;
            }
        }
    }

    // Shift remaining partial data to the front
    if (last_line_end > 0) {
        const leftover = persist_len.* - last_line_end;
        if (leftover > 0) {
            std.mem.copyForwards(u8, persist_buf[0..leftover], persist_buf[last_line_end..persist_len.*]);
        }
        persist_len.* = leftover;
    }

    if (last_line.len == 0) return;

    // Trim leading whitespace/protocol markers
    var line = last_line;
    while (line.len > 0 and (line[0] == ',' or line[0] == ' ' or line[0] == '\t')) {
        line = line[1..];
    }

    // Detect protocol header
    if (!json_mode.* and std.mem.indexOf(u8, line, "{\"version\":") != null) {
        json_mode.* = true;
        if (std.mem.indexOf(u8, line, "\"click_events\":true") != null) {
            click_enabled.* = true;
        }
        return; // Header line, no blocks to display yet
    }

    // JSON mode: parse block array
    if (json_mode.* and line.len > 0 and (line[0] == '[' or line[0] == '{')) {
        // Strip outer brackets
        var inner = line;
        if (inner[0] == '[') inner = inner[1..];
        if (inner.len > 0 and inner[inner.len - 1] == ']') inner = inner[0 .. inner.len - 1];

        block_count.* = 0;
        var pos: usize = 0;
        while (pos < inner.len and block_count.* < MAX_STATUS_BLOCKS) {
            // Find next block object
            const obj_start = std.mem.indexOfScalar(u8, inner[pos..], '{') orelse break;
            const obj_end = std.mem.indexOfScalar(u8, inner[pos + obj_start..], '}') orelse break;
            const obj = inner[pos + obj_start .. pos + obj_start + obj_end + 1];

            const idx = block_count.*;
            blocks[idx] = .{};

            // Extract full_text
            if (extractJsonString(obj, "\"full_text\":\"")) |ft| {
                const copy_len = @min(ft.len, @as(usize, 256));
                @memcpy(blocks[idx].full_text[0..copy_len], ft[0..copy_len]);
                blocks[idx].full_text_len = @intCast(copy_len);
            }
            // Extract name
            if (extractJsonString(obj, "\"name\":\"")) |nm| {
                const copy_len = @min(nm.len, @as(usize, 64));
                @memcpy(blocks[idx].name[0..copy_len], nm[0..copy_len]);
                blocks[idx].name_len = @intCast(copy_len);
            }
            // Extract instance
            if (extractJsonString(obj, "\"instance\":\"")) |inst| {
                const copy_len = @min(inst.len, @as(usize, 64));
                @memcpy(blocks[idx].instance[0..copy_len], inst[0..copy_len]);
                blocks[idx].instance_len = @intCast(copy_len);
            }

            block_count.* += 1;
            pos = pos + obj_start + obj_end + 1;
        }
    } else {
        // Plain text mode: single block
        block_count.* = 0;
        blocks[0] = .{};
        const copy_len = @min(line.len, @as(usize, 256));
        @memcpy(blocks[0].full_text[0..copy_len], line[0..copy_len]);
        blocks[0].full_text_len = @intCast(copy_len);
        block_count.* = 1;
    }
}

/// Escape a string for JSON output: replace \ with \\ and " with \".
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

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const val_start = key_pos + key.len;
    const val_end = std.mem.indexOfScalar(u8, json[val_start..], '"') orelse return null;
    return json[val_start .. val_start + val_end];
}
