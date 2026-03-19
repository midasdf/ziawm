const std = @import("std");
const ipc = @import("ipc");

test "encode run_command: magic, length, type, payload" {
    var buf: [256]u8 = undefined;
    const payload = "nop";
    const msg = ipc.encode(.run_command, payload, &buf);

    // magic
    try std.testing.expectEqualSlices(u8, ipc.MAGIC, msg[0..6]);
    // payload length (LE u32)
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, msg[6..10], .little));
    // message type (LE u32) — run_command = 0
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, msg[10..14], .little));
    // payload
    try std.testing.expectEqualSlices(u8, payload, msg[14..17]);
    // total length
    try std.testing.expectEqual(ipc.HEADER_SIZE + payload.len, msg.len);
}

test "decode header" {
    var buf: [256]u8 = undefined;
    _ = ipc.encode(.get_version, "", &buf);
    const hdr = ipc.decodeHeader(&buf).?;

    try std.testing.expectEqual(@as(u32, 7), hdr.msg_type); // get_version
    try std.testing.expectEqual(@as(u32, 0), hdr.payload_len);
}

test "decode header with payload, extract payload slice" {
    var buf: [256]u8 = undefined;
    const payload = "hello";
    const msg = ipc.encode(.run_command, payload, &buf);

    const hdr = ipc.decodeHeader(msg).?;
    try std.testing.expectEqual(@as(u32, payload.len), hdr.payload_len);

    // Extract payload using decoded length
    const extracted = msg[ipc.HEADER_SIZE .. ipc.HEADER_SIZE + hdr.payload_len];
    try std.testing.expectEqualSlices(u8, payload, extracted);
}

test "invalid magic returns null" {
    var buf: [256]u8 = undefined;
    _ = ipc.encode(.get_version, "", &buf);
    // Corrupt first byte of magic
    buf[0] = 'X';
    try std.testing.expect(ipc.decodeHeader(&buf) == null);
}

test "too short buffer returns null" {
    const tiny = [_]u8{ 'i', '3', '-' };
    try std.testing.expect(ipc.decodeHeader(&tiny) == null);
}

test "event type has bit 31 set" {
    try std.testing.expect(ipc.isEvent(@intFromEnum(ipc.EventType.workspace)));
    try std.testing.expect(ipc.isEvent(@intFromEnum(ipc.EventType.window)));
    try std.testing.expect(ipc.isEvent(@intFromEnum(ipc.EventType.binding)));
    // Normal message types must NOT have bit 31 set
    try std.testing.expect(!ipc.isEvent(@intFromEnum(ipc.MessageType.run_command)));
    try std.testing.expect(!ipc.isEvent(@intFromEnum(ipc.MessageType.get_version)));
}

test "roundtrip encode/decode all message types" {
    var buf: [256]u8 = undefined;
    const payload = "{}";
    const types = [_]ipc.MessageType{
        .run_command,
        .get_workspaces,
        .subscribe,
        .get_outputs,
        .get_tree,
        .get_marks,
        .get_bar_config,
        .get_version,
        .send_tick,
        .get_config,
        .get_binding_modes,
    };
    for (types) |mt| {
        const msg = ipc.encode(mt, payload, &buf);
        const hdr = ipc.decodeHeader(msg).?;
        try std.testing.expectEqual(@intFromEnum(mt), hdr.msg_type);
        try std.testing.expectEqual(@as(u32, payload.len), hdr.payload_len);
        try std.testing.expect(!ipc.isEvent(hdr.msg_type));
    }
}

test "encode event type" {
    var buf: [256]u8 = undefined;
    const payload = "{\"change\":\"focus\"}";
    const msg = ipc.encodeEvent(.workspace, payload, &buf);

    // magic
    try std.testing.expectEqualSlices(u8, ipc.MAGIC, msg[0..6]);
    // payload length
    try std.testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, msg[6..10], .little));
    // event type value
    const et_val = @intFromEnum(ipc.EventType.workspace);
    try std.testing.expectEqual(et_val, std.mem.readInt(u32, msg[10..14], .little));
    // bit 31 set
    try std.testing.expect(ipc.isEvent(std.mem.readInt(u32, msg[10..14], .little)));
    // payload content
    try std.testing.expectEqualSlices(u8, payload, msg[14 .. 14 + payload.len]);
}
