// ziawm-msg — IPC client for ziawm
const std = @import("std");
const ipc = @import("ipc");

const VERSION = "0.1.0";

fn usage() void {
    std.debug.print(
        \\Usage: ziawm-msg [-t type] [-s socket_path] [message]
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
        \\  ziawm-msg exec st
        \\  ziawm-msg -t get_version
        \\  ziawm-msg -t get_workspaces
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
            std.debug.print("ziawm-msg v{s}\n", .{VERSION});
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

    // Connect
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    addr.family = std.posix.AF.UNIX;
    @memset(&addr.path, 0);
    if (sock_path.len > addr.path.len) {
        std.debug.print("ERROR: socket path too long\n", .{});
        return;
    }
    @memcpy(addr.path[0..sock_path.len], sock_path);

    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch {
        std.debug.print("ERROR: cannot create socket\n", .{});
        return;
    };
    defer std.posix.close(fd);

    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        std.debug.print("ERROR: cannot connect to {s}\n", .{sock_path});
        return;
    };

    // Send message
    var send_buf: [4096 + ipc.HEADER_SIZE]u8 = undefined;
    const msg = ipc.encode(msg_type, payload, &send_buf);
    _ = std.posix.write(fd, msg) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return;
    };

    // Read response
    var recv_buf: [65536]u8 = undefined;
    var total_read: usize = 0;

    // Read header first
    while (total_read < ipc.HEADER_SIZE) {
        const n = std.posix.read(fd, recv_buf[total_read..]) catch {
            std.debug.print("ERROR: read failed\n", .{});
            return;
        };
        if (n == 0) {
            std.debug.print("ERROR: connection closed\n", .{});
            return;
        }
        total_read += n;
    }

    const hdr = ipc.decodeHeader(recv_buf[0..ipc.HEADER_SIZE]) orelse {
        std.debug.print("ERROR: invalid response header\n", .{});
        return;
    };

    const total_needed = ipc.HEADER_SIZE + @as(usize, hdr.payload_len);
    if (total_needed > recv_buf.len) {
        std.debug.print("ERROR: response too large\n", .{});
        return;
    }

    while (total_read < total_needed) {
        const n = std.posix.read(fd, recv_buf[total_read..total_needed]) catch {
            std.debug.print("ERROR: read failed\n", .{});
            return;
        };
        if (n == 0) break;
        total_read += n;
    }

    // Print response payload to stdout
    const response_payload = recv_buf[ipc.HEADER_SIZE..total_needed];
    _ = std.posix.write(std.posix.STDOUT_FILENO, response_payload) catch {};
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
}
