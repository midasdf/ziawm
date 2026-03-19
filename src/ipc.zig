// IPC module — shared between zephwm, zephwm-msg, and zephwm-bar
// i3-compatible binary IPC protocol
const std = @import("std");

pub const MAGIC = "i3-ipc";
pub const HEADER_SIZE = 14; // 6 (magic) + 4 (payload_len) + 4 (msg_type)

pub const MessageType = enum(u32) {
    run_command = 0,
    get_workspaces = 1,
    subscribe = 2,
    get_outputs = 3,
    get_tree = 4,
    get_marks = 5,
    get_bar_config = 6,
    get_version = 7,
    send_tick = 8,
    get_config = 9,
    get_binding_modes = 10,
};

pub const EventType = enum(u32) {
    workspace = 0x80000000,
    output = 0x80000001,
    mode = 0x80000002,
    window = 0x80000003,
    barconfig_update = 0x80000004,
    binding = 0x80000005,
};

pub const Header = struct {
    msg_type: u32,
    payload_len: u32,
};

/// Encode a request/response message into caller-provided buffer.
/// Returns filled slice. buf must be at least HEADER_SIZE + payload.len bytes.
pub fn encode(msg_type: MessageType, payload: []const u8, buf: []u8) []const u8 {
    const total = HEADER_SIZE + payload.len;
    std.debug.assert(buf.len >= total);

    @memcpy(buf[0..6], MAGIC);
    std.mem.writeInt(u32, buf[6..10], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buf[10..14], @intFromEnum(msg_type), .little);
    @memcpy(buf[14..][0..payload.len], payload);

    return buf[0..total];
}

/// Encode an event message into caller-provided buffer.
/// Returns filled slice. buf must be at least HEADER_SIZE + payload.len bytes.
pub fn encodeEvent(event_type: EventType, payload: []const u8, buf: []u8) []const u8 {
    const total = HEADER_SIZE + payload.len;
    std.debug.assert(buf.len >= total);

    @memcpy(buf[0..6], MAGIC);
    std.mem.writeInt(u32, buf[6..10], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buf[10..14], @intFromEnum(event_type), .little);
    @memcpy(buf[14..][0..payload.len], payload);

    return buf[0..total];
}

/// Decode header from buffer. Returns null if too small or invalid magic.
pub fn decodeHeader(buf: []const u8) ?Header {
    if (buf.len < HEADER_SIZE) return null;
    if (!std.mem.eql(u8, buf[0..6], MAGIC)) return null;

    const payload_len = std.mem.readInt(u32, buf[6..10], .little);
    const msg_type = std.mem.readInt(u32, buf[10..14], .little);

    return Header{
        .msg_type = msg_type,
        .payload_len = payload_len,
    };
}

/// Check if a message type value is an event (bit 31 set).
pub fn isEvent(msg_type: u32) bool {
    return (msg_type & 0x80000000) != 0;
}

// --- Server-side IPC ---

/// Get default socket path: /run/user/{uid}/zephwm/ipc.sock
pub fn getDefaultSocketPath(buf: []u8) []const u8 {
    const uid = std.os.linux.getuid();
    const len = (std.fmt.bufPrint(buf, "/run/user/{d}/zephwm/ipc.sock", .{uid}) catch return buf[0..0]).len;
    return buf[0..len];
}

/// Create and bind listening UNIX socket. Returns fd.
pub fn createServer(socket_path: []const u8) !std.posix.fd_t {
    // Create parent directory
    if (std.mem.lastIndexOfScalar(u8, socket_path, '/')) |sep| {
        const dir_path = socket_path[0..sep];
        std.posix.mkdirat(std.posix.AT.FDCWD, dir_path, 0o700) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    // Delete stale socket file
    std.posix.unlinkat(std.posix.AT.FDCWD, socket_path, 0) catch {};

    // Create socket
    const fd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        0,
    );
    errdefer std.posix.close(fd);

    // Bind
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    addr.family = std.posix.AF.UNIX;
    @memset(&addr.path, 0);
    if (socket_path.len > addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));

    // Listen
    try std.posix.listen(fd, 5);

    return fd;
}

/// Accept a client connection (non-blocking).
pub fn acceptClient(listen_fd: std.posix.fd_t) !std.posix.fd_t {
    return try std.posix.accept(listen_fd, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
}

/// Read a complete message from client fd into buf.
/// Returns msg_type + payload slice, or null if EOF/disconnect.
/// Returns error.WouldBlock if no data available yet (EAGAIN).
pub fn readMessage(fd: std.posix.fd_t, buf: []u8) error{WouldBlock}!?struct { msg_type: u32, payload: []const u8 } {
    if (buf.len < HEADER_SIZE) return null;

    // Read header
    var total_read: usize = 0;
    while (total_read < HEADER_SIZE) {
        const n = std.posix.read(fd, buf[total_read..]) catch |err| {
            if (err == error.WouldBlock) return error.WouldBlock;
            return null;
        };
        if (n == 0) return null; // EOF
        total_read += n;
    }

    // Validate magic
    const hdr = decodeHeader(buf[0..HEADER_SIZE]) orelse return null;

    const payload_len: usize = @intCast(hdr.payload_len);
    const total_needed = HEADER_SIZE + payload_len;
    if (buf.len < total_needed) return null;

    // Read payload
    while (total_read < total_needed) {
        const n = std.posix.read(fd, buf[total_read..total_needed]) catch |err| {
            if (err == error.WouldBlock) return error.WouldBlock;
            return null;
        };
        if (n == 0) return null;
        total_read += n;
    }

    return .{
        .msg_type = hdr.msg_type,
        .payload = buf[HEADER_SIZE..total_needed],
    };
}

/// Write all bytes to fd, handling partial writes.
fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = try std.posix.write(fd, data[written..]);
        if (n == 0) return error.BrokenPipe;
        written += n;
    }
}

/// Write a response to client fd.
pub fn writeResponse(fd: std.posix.fd_t, msg_type: u32, payload: []const u8) !void {
    // Write header
    var hdr_buf: [HEADER_SIZE]u8 = undefined;
    @memcpy(hdr_buf[0..6], MAGIC);
    std.mem.writeInt(u32, hdr_buf[6..10], @intCast(payload.len), .little);
    std.mem.writeInt(u32, hdr_buf[10..14], msg_type, .little);

    try writeAll(fd, &hdr_buf);
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }
}
