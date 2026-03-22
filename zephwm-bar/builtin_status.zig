const std = @import("std");

// --- Task 8: CPU ---

pub const CpuSample = struct {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,

    pub fn parse(line: []const u8) CpuSample {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // skip "cpu"
        return .{
            .user = parseU64(it.next() orelse "0"),
            .nice = parseU64(it.next() orelse "0"),
            .system = parseU64(it.next() orelse "0"),
            .idle = parseU64(it.next() orelse "0"),
            .iowait = parseU64(it.next() orelse "0"),
            .irq = parseU64(it.next() orelse "0"),
            .softirq = parseU64(it.next() orelse "0"),
        };
    }

    pub fn total(self: CpuSample) u64 {
        return self.user + self.nice + self.system + self.idle +
            self.iowait + self.irq + self.softirq;
    }
};

pub fn cpuPercent(prev: CpuSample, curr: CpuSample) u8 {
    const total_diff = curr.total() -| prev.total();
    const idle_diff = curr.idle -| prev.idle;
    if (total_diff == 0) return 0;
    return @intCast((total_diff - idle_diff) * 100 / total_diff);
}

fn parseU64(s: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

// --- Task 9: Memory/Swap + formatKB ---

pub const FmtBuf = struct {
    data: [8]u8 = .{0} ** 8,
    len: u8 = 0,
    pub fn slice(self: *const FmtBuf) []const u8 {
        return self.data[0..self.len];
    }
};

pub fn formatKB(kb: u64) FmtBuf {
    var result = FmtBuf{};
    const written = if (kb >= 1048576)
        std.fmt.bufPrint(&result.data, "{d}.{d}G", .{ kb / 1048576, (kb % 1048576) * 10 / 1048576 }) catch ""
    else if (kb >= 1024)
        std.fmt.bufPrint(&result.data, "{d}M", .{kb / 1024}) catch ""
    else
        std.fmt.bufPrint(&result.data, "{d}K", .{kb}) catch "";
    result.len = @intCast(written.len);
    return result;
}

pub const MemInfo = struct {
    mem_used_kb: u64,
    swap_used_kb: u64,

    pub fn parse(content: []const u8) MemInfo {
        var mem_total: u64 = 0;
        var mem_available: u64 = 0;
        var swap_total: u64 = 0;
        var swap_free: u64 = 0;
        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                mem_total = parseFieldKB(line);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                mem_available = parseFieldKB(line);
            } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
                swap_total = parseFieldKB(line);
            } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
                swap_free = parseFieldKB(line);
            }
        }
        return .{
            .mem_used_kb = mem_total -| mem_available,
            .swap_used_kb = swap_total -| swap_free,
        };
    }
};

fn parseFieldKB(line: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // skip label
    return parseU64(it.next() orelse "0");
}

// --- Task 10: Clock ---

pub fn formatClock(hour: u8, minute: u8) [5]u8 {
    var buf: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch {};
    return buf;
}

// --- Task 11: SSID Truncation ---

pub const SsidBuf = struct {
    data: [32]u8 = .{0} ** 32,
    len: u8 = 0,
    pub fn slice(self: *const SsidBuf) []const u8 {
        return self.data[0..self.len];
    }
};

pub fn truncateSsid(ssid: []const u8) SsidBuf {
    var buf = SsidBuf{};
    if (ssid.len <= 14) {
        @memcpy(buf.data[0..ssid.len], ssid);
        buf.len = @intCast(ssid.len);
    } else {
        @memcpy(buf.data[0..14], ssid[0..14]);
        @memcpy(buf.data[14..17], "...");
        buf.len = 17;
    }
    return buf;
}

// --- Task 12: Battery ---

pub fn parseBatteryCapacity(content: []const u8) u8 {
    const trimmed = std.mem.trimRight(u8, content, &.{ '\n', ' ' });
    return std.fmt.parseInt(u8, trimmed, 10) catch 0;
}

pub fn isBatteryType(content: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, content, &.{ '\n', ' ' });
    return std.mem.eql(u8, trimmed, "Battery");
}

// --- Task 13: IME + Threshold colors ---

pub fn cpuColor(pct: u8) u32 {
    return if (pct > 80) 0xe06c75 else 0x6a9955;
}

pub fn batColor(pct: u8) u32 {
    return if (pct < 20) 0xe06c75 else 0x98c379;
}

pub const ImeState = enum { japanese, direct, unavailable };

pub fn classifyIme(im_name: []const u8) ImeState {
    if (im_name.len == 0) return .direct;
    if (std.mem.indexOf(u8, im_name, "mozc") != null) return .japanese;
    if (std.mem.indexOf(u8, im_name, "anthy") != null) return .japanese;
    if (std.mem.indexOf(u8, im_name, "skk") != null) return .japanese;
    if (std.mem.startsWith(u8, im_name, "keyboard-")) return .direct;
    return .direct;
}
