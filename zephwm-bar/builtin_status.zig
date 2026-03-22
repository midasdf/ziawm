const std = @import("std");

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("time.h");
});

const posix = std.posix;

// --- Task 14: ModuleOutput + ModuleState ---

pub const ModuleOutput = struct {
    text: [256]u8 = .{0} ** 256,
    text_len: u16 = 0,
    color: u32 = 0,

    pub fn set(self: *ModuleOutput, str: []const u8, col: u32) void {
        const len: u16 = @intCast(@min(str.len, 256));
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = len;
        self.color = col;
    }

    pub fn hide(self: *ModuleOutput) void {
        self.text_len = 0;
    }
};

pub const ModuleState = struct {
    cpu_last: i64 = 0,
    mem_last: i64 = 0,
    net_last: i64 = 0,
    bat_last: i64 = 0,
    ime_last: i64 = 0,
    clock_last_minute: i8 = -1,
    cpu_prev: CpuSample = .{ .user = 0, .nice = 0, .system = 0, .idle = 0, .iowait = 0, .irq = 0, .softirq = 0 },
    wifi_iface: ?[16]u8 = null,
    wifi_iface_discovered: bool = false,
    dirty: bool = true,

    pub const CPU_COLOR: u32 = 0x6a9955;
    pub const CPU_ALERT: u32 = 0xe06c75;
    pub const MEM_COLOR: u32 = 0x569cd6;
    pub const SWAP_COLOR: u32 = 0xd19a66;
    pub const NET_COLOR: u32 = 0x56b6c2;
    pub const NET_OFF_COLOR: u32 = 0x555555;
    pub const BAT_COLOR: u32 = 0x98c379;
    pub const BAT_ALERT: u32 = 0xe06c75;
    pub const IME_COLOR: u32 = 0xc678dd;
    pub const CLOCK_COLOR: u32 = 0xe0e0e0;

    pub const CPU_INTERVAL: i64 = 2;
    pub const MEM_INTERVAL: i64 = 5;
    pub const NET_INTERVAL: i64 = 10;
    pub const BAT_INTERVAL: i64 = 30;
    pub const IME_INTERVAL: i64 = 1;
};

// Module indices: CPU(0), MEM(1), SW(2), WiFi(3), BAT(4), IME(5), Clock(6)
pub const MOD_CPU: usize = 0;
pub const MOD_MEM: usize = 1;
pub const MOD_SW: usize = 2;
pub const MOD_WIFI: usize = 3;
pub const MOD_BAT: usize = 4;
pub const MOD_IME: usize = 5;
pub const MOD_CLOCK: usize = 6;
pub const MODULE_COUNT: usize = 7;

/// Read file content into buffer, returning the slice or null on failure.
pub fn readFileContent(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    return buf[0..n];
}

/// Update all built-in status modules based on elapsed time.
/// Module order: CPU(0), MEM(1), SW(2), WiFi(3), BAT(4), IME(5), Clock(6).
pub fn updateAll(state: *ModuleState, now: i64, display: ?*anyopaque, root_window: u64, outputs: *[MODULE_COUNT]ModuleOutput) void {
    // --- CPU (index 0) ---
    if (now - state.cpu_last >= ModuleState.CPU_INTERVAL) {
        state.cpu_last = now;
        var proc_buf: [512]u8 = undefined;
        if (readFileContent("/proc/stat", &proc_buf)) |content| {
            // First line is aggregate "cpu ..."
            var lines = std.mem.tokenizeScalar(u8, content, '\n');
            if (lines.next()) |first_line| {
                if (std.mem.startsWith(u8, first_line, "cpu ")) {
                    const curr = CpuSample.parse(first_line);
                    const pct = cpuPercent(state.cpu_prev, curr);
                    state.cpu_prev = curr;

                    var fmt_buf: [16]u8 = undefined;
                    const text = std.fmt.bufPrint(&fmt_buf, "CPU {d}%", .{pct}) catch "CPU ?%";
                    outputs[MOD_CPU].set(text, cpuColor(pct));
                    state.dirty = true;
                }
            }
        }
    }

    // --- MEM + SW (indices 1, 2) ---
    if (now - state.mem_last >= ModuleState.MEM_INTERVAL) {
        state.mem_last = now;
        var mem_buf: [1024]u8 = undefined;
        if (readFileContent("/proc/meminfo", &mem_buf)) |content| {
            const info = MemInfo.parse(content);

            // MEM module
            const mem_fmt = formatKB(info.mem_used_kb);
            var mem_text_buf: [16]u8 = undefined;
            const mem_text = std.fmt.bufPrint(&mem_text_buf, "MEM {s}", .{mem_fmt.slice()}) catch "MEM ?";
            outputs[MOD_MEM].set(mem_text, ModuleState.MEM_COLOR);

            // SW module - hide if no swap used
            if (info.swap_used_kb > 0) {
                const sw_fmt = formatKB(info.swap_used_kb);
                var sw_text_buf: [16]u8 = undefined;
                const sw_text = std.fmt.bufPrint(&sw_text_buf, "SW {s}", .{sw_fmt.slice()}) catch "SW ?";
                outputs[MOD_SW].set(sw_text, ModuleState.SWAP_COLOR);
            } else {
                outputs[MOD_SW].hide();
            }
            state.dirty = true;
        }
    }

    // --- WiFi (index 3) ---
    if (now - state.net_last >= ModuleState.NET_INTERVAL) {
        state.net_last = now;

        // Discover wireless interface on first call
        if (!state.wifi_iface_discovered) {
            state.wifi_iface_discovered = true;
            state.wifi_iface = discoverWirelessInterface();
        }

        if (state.wifi_iface) |iface| {
            const iface_name = std.mem.sliceTo(&iface, 0);
            if (getSsid(iface_name)) |ssid_raw| {
                const ssid = truncateSsid(ssid_raw.slice());
                var wifi_text_buf: [48]u8 = undefined;
                const wifi_text = std.fmt.bufPrint(&wifi_text_buf, "W:{s}", .{ssid.slice()}) catch "W:?";
                outputs[MOD_WIFI].set(wifi_text, ModuleState.NET_COLOR);
            } else {
                outputs[MOD_WIFI].set("W:---", ModuleState.NET_OFF_COLOR);
            }
        } else {
            outputs[MOD_WIFI].hide();
        }
        state.dirty = true;
    }

    // --- Battery (index 4) ---
    if (now - state.bat_last >= ModuleState.BAT_INTERVAL) {
        state.bat_last = now;

        if (findBatteryCapacity()) |cap| {
            var bat_text_buf: [16]u8 = undefined;
            const bat_text = std.fmt.bufPrint(&bat_text_buf, "BAT {d}%", .{cap}) catch "BAT ?%";
            outputs[MOD_BAT].set(bat_text, batColor(cap));
        } else {
            outputs[MOD_BAT].hide();
        }
        state.dirty = true;
    }

    // --- IME (index 5) ---
    if (display != null and now - state.ime_last >= ModuleState.IME_INTERVAL) {
        state.ime_last = now;

        const ime_state = readImeProperty(display.?, root_window);
        switch (ime_state) {
            .japanese => outputs[MOD_IME].set("JP", ModuleState.IME_COLOR),
            .direct => outputs[MOD_IME].set("EN", ModuleState.IME_COLOR),
            .unavailable => outputs[MOD_IME].hide(),
        }
        state.dirty = true;
    } else if (display == null) {
        outputs[MOD_IME].hide();
    }

    // --- Clock (index 6) ---
    {
        const epoch = std.time.timestamp();
        var c_time: x11.time_t = @intCast(epoch);
        var tm: x11.struct_tm = undefined;
        _ = x11.localtime_r(&c_time, &tm);
        const minute: i8 = @intCast(tm.tm_min);
        if (minute != state.clock_last_minute) {
            state.clock_last_minute = minute;
            const hour: u8 = @intCast(tm.tm_hour);
            const min_u8: u8 = @intCast(tm.tm_min);
            const clock_text = formatClock(hour, min_u8);
            outputs[MOD_CLOCK].set(&clock_text, ModuleState.CLOCK_COLOR);
            state.dirty = true;
        }
    }
}

/// Iterate /sys/class/power_supply/ to find a Battery and return its capacity.
fn findBatteryCapacity() ?u8 {
    const base_path = "/sys/class/power_supply";
    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        // Check type
        var type_path_buf: [128]u8 = undefined;
        const type_path = std.fmt.bufPrint(&type_path_buf, "{s}/{s}/type", .{ base_path, entry.name }) catch continue;
        var type_content_buf: [32]u8 = undefined;
        const type_content = readFileContent(type_path, &type_content_buf) orelse continue;
        if (!isBatteryType(type_content)) continue;

        // Read capacity
        var cap_path_buf: [128]u8 = undefined;
        const cap_path = std.fmt.bufPrint(&cap_path_buf, "{s}/{s}/capacity", .{ base_path, entry.name }) catch continue;
        var cap_content_buf: [8]u8 = undefined;
        const cap_content = readFileContent(cap_path, &cap_content_buf) orelse continue;
        return parseBatteryCapacity(cap_content);
    }
    return null;
}

// --- Task 15: SSID ioctl implementation (stub — implemented in next commit) ---

/// Get SSID from a wireless interface via ioctl SIOCGIWESSID.
/// TODO: implement with actual ioctl call
pub fn getSsid(iface_name: []const u8) ?SsidBuf {
    _ = iface_name;
    return null;
}

/// Discover the first wireless interface by checking /sys/class/net/*/wireless/.
pub fn discoverWirelessInterface() ?[16]u8 {
    const base_path = "/sys/class/net";
    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        // Check if this interface has a "wireless" subdirectory
        var check_path_buf: [128]u8 = undefined;
        const check_path = std.fmt.bufPrint(&check_path_buf, "{s}/{s}/wireless", .{ base_path, entry.name }) catch continue;

        // Try to stat the wireless directory
        std.fs.accessAbsolute(check_path, .{}) catch continue;

        // Found a wireless interface
        var result: [16]u8 = .{0} ** 16;
        const name_len = @min(entry.name.len, 15);
        @memcpy(result[0..name_len], entry.name[0..name_len]);
        return result;
    }
    return null;
}

// --- Task 16: IME X property reading (stub — implemented in next commit) ---

/// Read the _FCITX_CURRENT_IM property from the X root window.
/// TODO: implement with actual XGetWindowProperty call
pub fn readImeProperty(display: *anyopaque, root: u64) ImeState {
    _ = display;
    _ = root;
    return .unavailable;
}

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
