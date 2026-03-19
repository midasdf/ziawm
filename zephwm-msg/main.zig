// zephwm-msg — IPC client for zephwm
const std = @import("std");
const ipc = @import("ipc");

const VERSION = "0.1.0";

fn usage() void {
    std.debug.print(
        \\Usage: zephwm-msg [-t type] [-s socket_path] [message]
        \\
        \\  -t TYPE    Message type: run_command (default), get_workspaces,
        \\             get_outputs, get_tree, get_marks, get_bar_config,
        \\             get_version, get_config, get_binding_modes,
        \\             subscribe, send_tick
        \\  -s PATH    Override IPC socket path
        \\  -h         Show this help
        \\  -v         Show version
        \\
        \\Examples:
        \\  zephwm-msg exec st
        \\  zephwm-msg -t get_version
        \\  zephwm-msg -t get_workspaces
        \\
    , .{});
}

fn parseMessageType(name: []const u8) ?ipc.MessageType {
    const map = .{
        .{ "run_command", ipc.MessageType.run_command },
        .{ "command", ipc.MessageType.run_command },
        .{ "get_workspaces", ipc.MessageType.get_workspaces },
        .{ "get_outputs", ipc.MessageType.get_outputs },
        .{ "get_tree", ipc.MessageType.get_tree },
        .{ "get_marks", ipc.MessageType.get_marks },
        .{ "get_bar_config", ipc.MessageType.get_bar_config },
        .{ "get_version", ipc.MessageType.get_version },
        .{ "get_config", ipc.MessageType.get_config },
        .{ "get_binding_modes", ipc.MessageType.get_binding_modes },
        .{ "subscribe", ipc.MessageType.subscribe },
        .{ "send_tick", ipc.MessageType.send_tick },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn discoverSocket(override: ?[]const u8) ?[]const u8 {
    if (override) |path| return path;

    // Check I3SOCK env var
    const env = std.posix.getenv("I3SOCK");
    if (env) |path| return path;

    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    var msg_type: ipc.MessageType = .run_command;
    var socket_override: ?[]const u8 = null;
    var payload_parts = std.ArrayListUnmanaged([]const u8){};
    defer payload_parts.deinit(allocator);

    // Parse args
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zephwm-msg v{s}\n", .{VERSION});
            return;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            const type_name = args.next() orelse {
                std.debug.print("ERROR: -t requires an argument\n", .{});
                return;
            };
            msg_type = parseMessageType(type_name) orelse {
                std.debug.print("ERROR: unknown message type: {s}\n", .{type_name});
                return;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            socket_override = args.next() orelse {
                std.debug.print("ERROR: -s requires an argument\n", .{});
                return;
            };
            continue;
        }
        try payload_parts.append(allocator, arg);
    }

    // Build payload (join remaining args with space)
    var payload_buf: [4096]u8 = undefined;
    var payload_len: usize = 0;
    for (payload_parts.items, 0..) |part, i| {
        if (i > 0) {
            payload_buf[payload_len] = ' ';
            payload_len += 1;
        }
        if (payload_len + part.len > payload_buf.len) {
            std.debug.print("ERROR: payload too long\n", .{});
            return;
        }
        @memcpy(payload_buf[payload_len..][0..part.len], part);
        payload_len += part.len;
    }
    const payload = payload_buf[0..payload_len];

    // Discover socket path
    var default_path_buf: [256]u8 = undefined;
    const default_path = ipc.getDefaultSocketPath(&default_path_buf);
    const sock_path = discoverSocket(socket_override) orelse default_path;

    // Send request and get response using shared IPC helper
    const response = ipc.sendRequest(allocator, sock_path, msg_type, payload) orelse {
        std.debug.print("ERROR: IPC request failed (cannot connect to {s})\n", .{sock_path});
        return;
    };
    defer allocator.free(response);

    // Print response payload to stdout
    _ = std.posix.write(std.posix.STDOUT_FILENO, response) catch {};
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
}
