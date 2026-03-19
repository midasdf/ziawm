// IPC module — shared between ziawm, ziawm-msg, and ziawm-bar
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
