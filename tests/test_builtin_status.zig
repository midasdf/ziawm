const std = @import("std");
const builtin_status = @import("builtin_status");

test "parse /proc/stat cpu line" {
    const line1 = "cpu  1000 200 300 5000 100 0 50 0 0 0";
    const line2 = "cpu  1100 210 320 5200 110 0 55 0 0 0";
    const prev = builtin_status.CpuSample.parse(line1);
    const curr = builtin_status.CpuSample.parse(line2);
    const pct = builtin_status.cpuPercent(prev, curr);
    // iowait (10 diff) is counted as idle, so: (345 - 210) * 100 / 345 = 39
    try std.testing.expectEqual(@as(u8, 39), pct);
}

test "cpu percent zero diff returns 0" {
    const line = "cpu  1000 200 300 5000 100 0 50 0 0 0";
    const s = builtin_status.CpuSample.parse(line);
    const pct = builtin_status.cpuPercent(s, s);
    try std.testing.expectEqual(@as(u8, 0), pct);
}

test "parse meminfo for used memory" {
    const input =
        \\MemTotal:        512000 kB
        \\MemFree:         100000 kB
        \\MemAvailable:    278000 kB
        \\SwapTotal:       1024000 kB
        \\SwapFree:        980000 kB
    ;
    const info = builtin_status.MemInfo.parse(input);
    try std.testing.expectEqual(@as(u64, 234000), info.mem_used_kb);
    try std.testing.expectEqual(@as(u64, 44000), info.swap_used_kb);
}

test "format memory as human readable" {
    try std.testing.expectEqualStrings("228M", builtin_status.formatKB(234000).slice());
    try std.testing.expectEqualStrings("1.1G", builtin_status.formatKB(1258000).slice());
    try std.testing.expectEqualStrings("512K", builtin_status.formatKB(512).slice());
}

test "format clock" {
    const result = builtin_status.formatClock(14, 32);
    try std.testing.expectEqualStrings("14:32", &result);
}

test "format clock midnight" {
    const result = builtin_status.formatClock(0, 5);
    try std.testing.expectEqualStrings("00:05", &result);
}

test "truncate long SSID" {
    const long = "BCW730J-8086A-A_EXT";
    const result = builtin_status.truncateSsid(long);
    try std.testing.expectEqualStrings("BCW730J-8086A-...", result.slice());
}

test "short SSID not truncated" {
    const short = "Kotoko";
    const result = builtin_status.truncateSsid(short);
    try std.testing.expectEqualStrings("Kotoko", result.slice());
}

test "exactly 14 char SSID not truncated" {
    const exact = "12345678901234";
    const result = builtin_status.truncateSsid(exact);
    try std.testing.expectEqualStrings("12345678901234", result.slice());
}

test "parse battery capacity" {
    try std.testing.expectEqual(@as(u8, 78), builtin_status.parseBatteryCapacity("78\n"));
    try std.testing.expectEqual(@as(u8, 100), builtin_status.parseBatteryCapacity("100\n"));
    try std.testing.expectEqual(@as(u8, 0), builtin_status.parseBatteryCapacity("invalid"));
}

test "isBatteryType" {
    try std.testing.expect(builtin_status.isBatteryType("Battery\n"));
    try std.testing.expect(!builtin_status.isBatteryType("Mains\n"));
    try std.testing.expect(!builtin_status.isBatteryType("USB\n"));
}

test "cpu threshold color" {
    try std.testing.expectEqual(@as(u32, 0xe06c75), builtin_status.cpuColor(85));
    try std.testing.expectEqual(@as(u32, 0x6a9955), builtin_status.cpuColor(50));
    try std.testing.expectEqual(@as(u32, 0x6a9955), builtin_status.cpuColor(80));
}

test "battery threshold color" {
    try std.testing.expectEqual(@as(u32, 0xe06c75), builtin_status.batColor(15));
    try std.testing.expectEqual(@as(u32, 0x98c379), builtin_status.batColor(20));
    try std.testing.expectEqual(@as(u32, 0x98c379), builtin_status.batColor(78));
}

test "classify IME state" {
    try std.testing.expectEqual(builtin_status.ImeState.japanese, builtin_status.classifyIme("mozc"));
    try std.testing.expectEqual(builtin_status.ImeState.japanese, builtin_status.classifyIme("anthy"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme("keyboard-us"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme("keyboard-jp"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme(""));
}
