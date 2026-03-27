// Built-in keysym name ↔ value lookup table.
// Replaces libxkbcommon dependency (only xkb_keysym_from_name / xkb_keysym_get_name were used).
const std = @import("std");

const Entry = struct { []const u8, u32 };

// Sorted by name for StaticStringMap.
const table: []const Entry = &.{
    // Digits
    .{ "0", 0x0030 },
    .{ "1", 0x0031 },
    .{ "2", 0x0032 },
    .{ "3", 0x0033 },
    .{ "4", 0x0034 },
    .{ "5", 0x0035 },
    .{ "6", 0x0036 },
    .{ "7", 0x0037 },
    .{ "8", 0x0038 },
    .{ "9", 0x0039 },
    // Modifiers
    .{ "Alt_L", 0xffe9 },
    .{ "Alt_R", 0xffea },
    // Navigation
    .{ "BackSpace", 0xff08 },
    .{ "Caps_Lock", 0xffe5 },
    .{ "Control_L", 0xffe3 },
    .{ "Control_R", 0xffe4 },
    .{ "Delete", 0xffff },
    .{ "Down", 0xff54 },
    .{ "End", 0xff57 },
    .{ "Escape", 0xff1b },
    // Function keys
    .{ "F1", 0xffbe },
    .{ "F10", 0xffc7 },
    .{ "F11", 0xffc8 },
    .{ "F12", 0xffc9 },
    .{ "F2", 0xffbf },
    .{ "F3", 0xffc0 },
    .{ "F4", 0xffc1 },
    .{ "F5", 0xffc2 },
    .{ "F6", 0xffc3 },
    .{ "F7", 0xffc4 },
    .{ "F8", 0xffc5 },
    .{ "F9", 0xffc6 },
    .{ "Home", 0xff50 },
    .{ "Insert", 0xff63 },
    .{ "Left", 0xff51 },
    .{ "Next", 0xff56 },
    .{ "Num_Lock", 0xff7f },
    .{ "Page_Down", 0xff56 },
    .{ "Page_Up", 0xff55 },
    .{ "Pause", 0xff13 },
    .{ "Print", 0xff61 },
    .{ "Prior", 0xff55 },
    .{ "Return", 0xff0d },
    .{ "Right", 0xff53 },
    .{ "Scroll_Lock", 0xff14 },
    .{ "Shift_L", 0xffe1 },
    .{ "Shift_R", 0xffe2 },
    .{ "Super_L", 0xffeb },
    .{ "Super_R", 0xffec },
    .{ "Tab", 0xff09 },
    .{ "Up", 0xff52 },
    // Media / XF86
    .{ "XF86AudioLowerVolume", 0x1008ff11 },
    .{ "XF86AudioMicMute", 0x1008ffb2 },
    .{ "XF86AudioMute", 0x1008ff12 },
    .{ "XF86AudioNext", 0x1008ff17 },
    .{ "XF86AudioPause", 0x1008ff31 },
    .{ "XF86AudioPlay", 0x1008ff14 },
    .{ "XF86AudioPrev", 0x1008ff16 },
    .{ "XF86AudioRaiseVolume", 0x1008ff13 },
    .{ "XF86AudioStop", 0x1008ff15 },
    .{ "XF86MonBrightnessDown", 0x1008ff03 },
    .{ "XF86MonBrightnessUp", 0x1008ff02 },
    // Letters
    .{ "a", 0x0061 },
    .{ "apostrophe", 0x0027 },
    .{ "b", 0x0062 },
    .{ "backslash", 0x005c },
    .{ "bracketleft", 0x005b },
    .{ "bracketright", 0x005d },
    .{ "c", 0x0063 },
    .{ "colon", 0x003a },
    .{ "comma", 0x002c },
    .{ "d", 0x0064 },
    .{ "e", 0x0065 },
    .{ "equal", 0x003d },
    .{ "f", 0x0066 },
    .{ "g", 0x0067 },
    .{ "grave", 0x0060 },
    .{ "h", 0x0068 },
    .{ "i", 0x0069 },
    .{ "j", 0x006a },
    .{ "k", 0x006b },
    .{ "l", 0x006c },
    .{ "m", 0x006d },
    .{ "minus", 0x002d },
    .{ "n", 0x006e },
    .{ "o", 0x006f },
    .{ "p", 0x0070 },
    .{ "period", 0x002e },
    .{ "plus", 0x002b },
    .{ "q", 0x0071 },
    .{ "quotedbl", 0x0022 },
    .{ "r", 0x0072 },
    .{ "s", 0x0073 },
    .{ "semicolon", 0x003b },
    .{ "slash", 0x002f },
    .{ "space", 0x0020 },
    .{ "t", 0x0074 },
    .{ "u", 0x0075 },
    .{ "v", 0x0076 },
    .{ "w", 0x0077 },
    .{ "x", 0x0078 },
    .{ "y", 0x0079 },
    .{ "z", 0x007a },
};

const name_map = std.StaticStringMap(u32).initComptime(table);

/// Convert a keysym name to its value. Returns 0 if not found.
pub fn fromName(name: []const u8) u32 {
    return name_map.get(name) orelse 0;
}

/// Convert a keysym value to its canonical name. Returns null if not found.
pub fn toName(keysym: u32) ?[]const u8 {
    // Linear scan is fine — only called for IPC binding events, not hot path.
    for (table) |entry| {
        if (entry[1] == keysym) return entry[0];
    }
    return null;
}

test "basic lookups" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0xff0d), fromName("Return"));
    try testing.expectEqual(@as(u32, 0xff51), fromName("Left"));
    try testing.expectEqual(@as(u32, 0x0061), fromName("a"));
    try testing.expectEqual(@as(u32, 0x0031), fromName("1"));
    try testing.expectEqual(@as(u32, 0x1008ff13), fromName("XF86AudioRaiseVolume"));
    try testing.expectEqual(@as(u32, 0), fromName("nonexistent"));
}

test "reverse lookups" {
    const testing = std.testing;
    try testing.expectEqualStrings("Return", toName(0xff0d).?);
    try testing.expectEqualStrings("a", toName(0x0061).?);
    try testing.expect(toName(0xdeadbeef) == null);
}
