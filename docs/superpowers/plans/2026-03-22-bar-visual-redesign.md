# Bar Visual Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign zephwm-bar with built-in status modules, crisp visuals, and a default config so zephwm is usable on first launch.

**Architecture:** Hybrid bar that uses built-in `/proc`/`/sys` readers when no `status_command` is configured, falling back to existing i3bar JSON protocol when one is set. Both paths produce `StatusBlock[]` consumed by a shared `drawBar()` renderer with per-block color support.

**Tech Stack:** Zig, XCB, Xlib/Xft, Linux `/proc`/`/sys` filesystem, `ioctl(SIOCGIWESSID)`

**Spec:** `docs/superpowers/specs/2026-03-22-bar-visual-redesign.md`

---

## File Structure

### Modified files
| File | Responsibility | Key Changes |
|------|---------------|-------------|
| `src/config.zig:27-32` | BarConfig struct + parser | Add `enabled`, `height` fields; set `enabled=true` on `bar {` |
| `src/bar.zig:15-76` | Bar process spawning | Remove early-return guard on empty status_command |
| `src/main.zig:732-734,248,864-870` | Bar spawn, IPC, reload | Use `bar.enabled`, dynamic height, bar respawn on reload |
| `src/event.zig:311-317` | Bar space reservation | Use `bar.enabled` + `bar.height` instead of hardcoded 20 |
| `zephwm-bar/main.zig` | Bar binary | StatusBlock color, visual constants, built-in mode, drawBar |
| `build.zig:49-66` | Build config | Add `builtin_status.zig` module to bar build |
| `tests/test_config.zig` | Config tests | Test new BarConfig fields |

### New files
| File | Responsibility |
|------|---------------|
| `zephwm-bar/builtin_status.zig` | All built-in status module implementations (CPU, MEM, swap, WiFi, battery, IME, clock) |
| `tests/test_builtin_status.zig` | Unit tests for `/proc` parsers and module logic |

---

## Chunk 1: WM-Side Plumbing

### Task 1: BarConfig struct and parser changes

**Files:**
- Modify: `src/config.zig:27-32` (BarConfig struct)
- Modify: `src/config.zig:464` (parser `bar {` entry)
- Modify: `tests/test_config.zig`

- [ ] **Step 1: Write failing test for BarConfig.enabled**

In `tests/test_config.zig`, add a test that parses a config with a `bar {}` block and asserts `cfg.bar.enabled == true`:

```zig
const config = @import("config");

test "bar block sets enabled flag" {
    const input = "bar {\n    position top\n}\n";
    var cfg = try config.Config.parse(std.testing.allocator, input);
    defer cfg.deinit();
    try std.testing.expect(cfg.bar.enabled);
    try std.testing.expectEqualStrings("top", cfg.bar.position);
}

test "no bar block leaves enabled false" {
    const input = "bindsym Mod1+Return exec st\n";
    var cfg = try config.Config.parse(std.testing.allocator, input);
    defer cfg.deinit();
    try std.testing.expect(!cfg.bar.enabled);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "bar block"`
Expected: FAIL (no `enabled` field on BarConfig)

- [ ] **Step 3: Add `enabled` and `height` fields to BarConfig**

In `src/config.zig:27-32`, update the struct:

```zig
pub const BarConfig = struct {
    enabled: bool = false,
    status_command: []const u8 = "",
    position: []const u8 = "bottom",
    bg_color: []const u8 = "#222222",
    statusline_color: []const u8 = "#dddddd",
    height: u16 = 16,
};
```

Note: `height` is not user-configurable via config syntax yet. It solely replaces the hardcoded `20` across the codebase. A future `height N` parser branch inside the `in_bar` block can be added when needed.

- [ ] **Step 4: Set `enabled = true` when parser enters `bar {`**

In `src/config.zig:464`, where `in_bar = true` is set, also add:

```zig
cfg.bar.enabled = true;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add src/config.zig tests/test_config.zig
git commit -m "feat(config): add enabled and height fields to BarConfig"
```

---

### Task 2: Remove spawnBar early-return guard

**Files:**
- Modify: `src/bar.zig:18`

- [ ] **Step 1: Remove the early-return guard**

In `src/bar.zig:18`, delete the line:

```zig
if (status_command.len == 0) return;
```

- [ ] **Step 2: Run existing tests to verify no regression**

Run: `zig build test`
Expected: All pass. (No existing test calls `spawnBar` with empty string.)

- [ ] **Step 3: Commit**

```bash
git add src/bar.zig
git commit -m "feat(bar): allow spawning bar without status_command"
```

---

### Task 3: WM-side bar spawning and space reservation

**Files:**
- Modify: `src/main.zig:732-734` (bar spawn)
- Modify: `src/main.zig:248` (IPC GET_BAR_CONFIG)
- Modify: `src/event.zig:311-317` (bar space reservation)

- [ ] **Step 1: Change bar spawning to use `bar.enabled`**

In `src/main.zig:732-734`, change:

```zig
// Before:
if (cfg.bar.status_command.len > 0) {
    bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
}

// After:
if (cfg.bar.enabled) {
    bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
}
```

- [ ] **Step 2: Update GET_BAR_CONFIG IPC response**

In `src/main.zig:248`, the current line is:
```zig
w.writeAll("\",\"bar_height\":20,\"colors\":{\"background\":\"") catch return "{}";
```

Split into three writes to insert the dynamic height:
```zig
w.writeAll("\",\"bar_height\":") catch return "{}";
w.print("{d}", .{cfg.bar.height}) catch return "{}";
w.writeAll(",\"colors\":{\"background\":\"") catch return "{}";
```

- [ ] **Step 3: Update event.zig bar space reservation**

In `src/event.zig:311-317`, change:

```zig
// Before:
if (c_cfg.bar.status_command.len > 0) {
    bar_height = 20;
    // ...
}

// After:
if (c_cfg.bar.enabled) {
    bar_height = c_cfg.bar.height;
    // ...
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/event.zig
git commit -m "feat: decouple bar presence from status_command"
```

---

### Task 4: Bar respawn on config reload

**Files:**
- Modify: `src/main.zig:864-870` (SIGUSR1 handler)

- [ ] **Step 1: Add killBar + spawnBar to reload handler**

In the SIGUSR1 handler in `src/main.zig`, insert after `event.grabKeys(&ctx, cfg)` (line ~883), before the `} else {` branch:

```zig
bar.killBar();
if (cfg.bar.enabled) {
    bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: All pass.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat: respawn bar on config reload"
```

---

### Task 5: Default config auto-generation

**Files:**
- Modify: `src/main.zig` (config loading section, around line 378-412)

- [ ] **Step 1: Write the default config string as a comptime constant**

In `src/main.zig`, add a `const default_config` string containing the full default config from the spec (Mod1, arrow keys, zt terminal, 4 workspaces, bar { position top }).

- [ ] **Step 2: Add auto-generation logic after config search fails**

After the 4-path config search loop, if `config == null`:

```zig
if (config == null) {
    const home = std.posix.getenv("HOME");
    const wrote_file = if (home) |h| blk: {
        const config_dir = std.fmt.allocPrint(allocator, "{s}/.config/zephwm", .{h}) catch break :blk false;
        // makePath creates intermediate dirs recursively (like mkdir -p)
        std.fs.cwd().makePath(config_dir) catch break :blk false;
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{config_dir}) catch break :blk false;
        const file = std.fs.createFileAbsolute(config_path, .{}) catch break :blk false;
        defer file.close();
        file.writeAll(default_config) catch break :blk false;
        log.info("Generated default config at {s}", .{config_path});
        // Now load from the written file
        config = Config.parse(allocator, default_config) catch break :blk false;
        break :blk true;
    } else false;

    if (!wrote_file) {
        log.warn("Could not write config, using in-memory defaults", .{});
        config = Config.parse(allocator, default_config) catch null;
    }
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: All pass. (Config generation doesn't run during unit tests.)

- [ ] **Step 4: Manual test**

Run zephwm in Xephyr with no config file. Verify:
- Config file created at `~/.config/zephwm/config`
- Bar appears at top
- Keybinds work (Alt+Return should try to launch `zt`)

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "feat: auto-generate default config on first launch"
```

---

## Chunk 2: Bar Visual Constants & StatusBlock Color

### Task 6: Update bar visual constants

**Files:**
- Modify: `zephwm-bar/main.zig:11-28` (constants)

- [ ] **Step 1: Update constants**

```zig
// Line 17:
const BAR_HEIGHT: u16 = 16;    // was 20

// Line 28:
const FONT_NAME = "monospace:size=8";  // was size=10

// Colors - update existing:
const BG_COLOR: u32 = 0x1a1a2e;       // was 0x222222
const FOCUSED_BG: u32 = 0x4a6fa5;     // was 0x285577

// Add new:
const SEPARATOR_COLOR_STR = "#505060";
const SEPARATOR_PAD: u16 = 4;

// Update string colors:
const UNFOCUSED_FG_STR = "#606060";    // was "#888888"
```

- [ ] **Step 2: Build to verify compilation**

Run: `zig build`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add zephwm-bar/main.zig
git commit -m "feat(bar): update visual constants for crisp minimal style"
```

---

### Task 7: Add color field to StatusBlock and update drawBar

**Files:**
- Modify: `zephwm-bar/main.zig:51-71` (StatusBlock struct)
- Modify: `zephwm-bar/main.zig:470-532` (drawBar function)

- [ ] **Step 1: Add `color` field to StatusBlock**

In `zephwm-bar/main.zig`, add to StatusBlock:

```zig
color: u32 = 0,  // 0xRRGGBB, 0 = use default FG_COLOR
```

- [ ] **Step 2: Add u32-to-XftColor helper**

Add a helper that directly populates the `XRenderColor` fields from a u32, avoiding the slow `XftColorAllocName` string parsing path:

```zig
fn xftColorFromU32(pixel: u32) c.XftColor {
    return .{
        .pixel = pixel,
        .color = .{
            .red = @as(u16, @intCast((pixel >> 16) & 0xFF)) * 257,   // 0-255 → 0-65535
            .green = @as(u16, @intCast((pixel >> 8) & 0xFF)) * 257,
            .blue = @as(u16, @intCast(pixel & 0xFF)) * 257,
            .alpha = 0xFFFF,
        },
    };
}
```

No `XftColorAllocName`/`XftColorFree` needed — we set the color struct directly. This is safe for `XftDrawStringUtf8` which only reads the `XRenderColor` fields.

- [ ] **Step 3: Update drawBar to use per-block color**

In the status block rendering loop within `drawBar()` (right-to-left drawing):

- If `block.color != 0`: use `xftColorFromU32(block.color)`.
- If `block.color == 0`: use the existing default `fg_xft_color`.

Also add separator rendering between blocks:
- Before drawing each block (except the rightmost), draw `|` in `SEPARATOR_COLOR` with `SEPARATOR_PAD` spacing on each side.
- Create `separator_xft_color` once at init using `xftColorFromU32(0x505060)`.
- Skip separators for hidden blocks (`full_text_len == 0`).

- [ ] **Step 3: Build and test visually**

Run: `zig build`
Test in Xephyr with an existing i3blocks config to verify external mode still works (all blocks use default color since `color=0`).

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/main.zig
git commit -m "feat(bar): per-block color support and separator rendering in drawBar"
```

---

## Chunk 3: Built-in Status Modules

### Task 8: Create builtin_status.zig scaffold + CPU module

**Files:**
- Create: `zephwm-bar/builtin_status.zig`
- Modify: `build.zig:49-66` (add module)
- Create: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write failing test for CPU parser**

Create `tests/test_builtin_status.zig`:

```zig
const std = @import("std");
const builtin_status = @import("builtin_status");

test "parse /proc/stat cpu line" {
    const line1 = "cpu  1000 200 300 5000 100 0 50 0 0 0";
    const line2 = "cpu  1100 210 320 5200 110 0 55 0 0 0";
    const prev = builtin_status.CpuSample.parse(line1);
    const curr = builtin_status.CpuSample.parse(line2);
    const pct = builtin_status.cpuPercent(prev, curr);
    // total_diff = (1100+210+320+5200+110+0+55) - (1000+200+300+5000+100+0+50) = 345
    // idle_diff = 5200 - 5000 = 200
    // usage = (345 - 200) / 345 * 100 = 42%
    try std.testing.expectEqual(@as(u8, 42), pct);
}

test "cpu percent zero diff returns 0" {
    const line = "cpu  1000 200 300 5000 100 0 50 0 0 0";
    const s = builtin_status.CpuSample.parse(line);
    const pct = builtin_status.cpuPercent(s, s);
    try std.testing.expectEqual(@as(u8, 0), pct);
}
```

- [ ] **Step 2: Create builtin_status.zig with CpuSample**

Create `zephwm-bar/builtin_status.zig`:

```zig
const std = @import("std");

pub const CpuSample = struct {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,

    pub fn parse(line: []const u8) CpuSample {
        // Parse "cpu  1000 200 300 5000 100 0 50 0 0 0"
        // Skip "cpu" prefix, then parse 7 space-separated u64 values
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

    fn total(self: CpuSample) u64 {
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
```

- [ ] **Step 3: Add module to build.zig**

In `build.zig`, in the zephwm-bar executable section (around line 49-66), add:

```zig
const builtin_status_mod = b.addModule("builtin_status", .{
    .root_source_file = b.path("zephwm-bar/builtin_status.zig"),
});
bar_exe.root_module.addImport("builtin_status", builtin_status_mod);
```

Also add to the test section (around line 139-256), create a test for `builtin_status`:

```zig
const builtin_test = b.addTest(.{
    .root_source_file = b.path("tests/test_builtin_status.zig"),
    .target = target,
    .optimize = optimize,
});
builtin_test.root_module.addImport("builtin_status", builtin_status_mod);
test_step.dependOn(&b.addRunArtifact(builtin_test).step);
```

Note: `StatusBlock` is defined in `zephwm-bar/main.zig`. `builtin_status.zig` should NOT import it. Instead, `builtin_status.zig` defines its own `ModuleOutput` struct with `text` and `color` fields. The main.zig code converts `ModuleOutput` → `StatusBlock` when copying to the render array. This avoids circular module dependencies.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: CPU parser tests pass.

- [ ] **Step 5: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig build.zig
git commit -m "feat(bar): add CPU usage parser module"
```

---

### Task 9: Memory and Swap parsers

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`
- Modify: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "parse meminfo for used memory" {
    const input =
        \\MemTotal:        512000 kB
        \\MemFree:         100000 kB
        \\MemAvailable:    278000 kB
        \\SwapTotal:       1024000 kB
        \\SwapFree:        980000 kB
    ;
    const info = builtin_status.MemInfo.parse(input);
    try std.testing.expectEqual(@as(u64, 234000), info.mem_used_kb);  // 512000 - 278000
    try std.testing.expectEqual(@as(u64, 44000), info.swap_used_kb);  // 1024000 - 980000
}

test "format memory as human readable" {
    // 234000 kB / 1024 = 228 MB
    try std.testing.expectEqualStrings("228M", builtin_status.formatKB(234000).slice());
    // 1258000 kB / 1048576 = 1.19... → "1.1G"
    try std.testing.expectEqualStrings("1.1G", builtin_status.formatKB(1258000).slice());
    try std.testing.expectEqualStrings("512K", builtin_status.formatKB(512).slice());
}
```

- [ ] **Step 2: Implement MemInfo parser and formatKB**

In `builtin_status.zig`:

```zig
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
    // "MemTotal:        512000 kB" → 512000
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // skip label
    return parseU64(it.next() orelse "0");
}

pub const FmtBuf = struct {
    data: [8]u8 = .{0} ** 8,
    len: u8 = 0,

    pub fn slice(self: *const FmtBuf) []const u8 {
        return self.data[0..self.len];
    }
};

pub fn formatKB(kb: u64) FmtBuf {
    var result = FmtBuf{};
    const written = if (kb >= 1048576) // >= 1GB in kB
        std.fmt.bufPrint(&result.data, "{d}.{d}G", .{ kb / 1048576, (kb % 1048576) * 10 / 1048576 }) catch ""
    else if (kb >= 1024) // >= 1MB in kB
        std.fmt.bufPrint(&result.data, "{d}M", .{kb / 1024}) catch ""
    else
        std.fmt.bufPrint(&result.data, "{d}K", .{kb}) catch "";
    result.len = @intCast(written.len);
    return result;
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig
git commit -m "feat(bar): add memory and swap parsers"
```

---

### Task 10: Clock module

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`
- Modify: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write test for clock formatting**

```zig
test "format clock from epoch" {
    // 2026-03-22 14:32:00 JST (UTC+9) = epoch 1774000320 - approximate
    // Instead, test the formatter directly with a known tm struct
    const result = builtin_status.formatClock(14, 32);
    try std.testing.expectEqualStrings("14:32", result[0..5]);
}
```

- [ ] **Step 2: Implement clock formatter**

```zig
const time_c = @cImport({ @cInclude("time.h"); });

pub fn formatClock(hour: u8, minute: u8) [5]u8 {
    var buf: [5]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch {};
    return buf;
}

pub const ClockState = struct {
    hour: u8,
    minute: u8,
};

pub fn getCurrentClock() ?ClockState {
    const ts = std.posix.clock_gettime(.REALTIME) catch return null;
    const secs: time_c.time_t = @intCast(ts.sec);
    var tm: time_c.struct_tm = undefined;
    if (time_c.localtime_r(&secs, &tm) == null) return null;
    return .{
        .hour = @intCast(tm.tm_hour),
        .minute = @intCast(tm.tm_min),
    };
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: Pass.

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig
git commit -m "feat(bar): add clock module with localtime_r"
```

---

### Task 11: Network (SSID) module

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`
- Modify: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write test for SSID truncation**

```zig
test "truncate long SSID" {
    const long = "BCW730J-8086A-A_EXT";  // 19 chars
    const result = builtin_status.truncateSsid(long);
    try std.testing.expectEqualStrings("BCW730J-8086A-...", result.slice());
}

test "short SSID not truncated" {
    const short = "Kotoko";  // 6 chars
    const result = builtin_status.truncateSsid(short);
    try std.testing.expectEqualStrings("Kotoko", result.slice());
}

test "exactly 14 char SSID not truncated" {
    const exact = "12345678901234";
    const result = builtin_status.truncateSsid(exact);
    try std.testing.expectEqualStrings("12345678901234", result.slice());
}
```

- [ ] **Step 2: Implement SSID truncation and network reader**

```zig
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

pub fn discoverWirelessInterface() ?[16]u8 {
    // Iterate /sys/class/net/*, check for wireless/ subdir
    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        // Check if wireless/ subdir exists
        var net_path_buf: [128]u8 = undefined;
        const net_path = std.fmt.bufPrint(&net_path_buf, "/sys/class/net/{s}/wireless", .{entry.name}) catch continue;
        std.fs.accessAbsolute(net_path, .{}) catch continue;
        var name: [16]u8 = .{0} ** 16;
        const len = @min(entry.name.len, 16);
        @memcpy(name[0..len], entry.name[0..len]);
        return name;
    }
    return null;
}

// getSsid() uses ioctl(SIOCGIWESSID) — implemented as a C-interop call
// Full implementation: open socket, fill iwreq, call ioctl
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: Truncation tests pass. (discoverWirelessInterface not unit-testable without /sys.)

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig
git commit -m "feat(bar): add network SSID detection and truncation"
```

---

### Task 12: Battery module

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`
- Modify: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write test for battery type filter**

```zig
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
```

- [ ] **Step 2: Implement battery parser**

```zig
pub fn parseBatteryCapacity(content: []const u8) u8 {
    const trimmed = std.mem.trimRight(u8, content, &.{ '\n', ' ' });
    return std.fmt.parseInt(u8, trimmed, 10) catch 0;
}

pub fn isBatteryType(content: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, content, &.{ '\n', ' ' });
    return std.mem.eql(u8, trimmed, "Battery");
}

pub fn readBatteryPercent() ?u8 {
    var dir = std.fs.openDirAbsolute("/sys/class/power_supply", .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        // Read type file
        var type_path_buf: [128]u8 = undefined;
        const type_path = std.fmt.bufPrint(&type_path_buf, "/sys/class/power_supply/{s}/type", .{entry.name}) catch continue;
        var type_buf: [32]u8 = undefined;
        const type_content = readFileContent(type_path, &type_buf) orelse continue;
        if (!isBatteryType(type_content)) continue;

        // Read capacity
        var cap_path_buf: [128]u8 = undefined;
        const cap_path = std.fmt.bufPrint(&cap_path_buf, "/sys/class/power_supply/{s}/capacity", .{entry.name}) catch continue;
        var cap_buf: [8]u8 = undefined;
        const cap_content = readFileContent(cap_path, &cap_buf) orelse continue;
        return parseBatteryCapacity(cap_content);
    }
    return null;
}

fn readFileContent(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    return buf[0..n];
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: Pass.

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig
git commit -m "feat(bar): add battery detection module"
```

---

### Task 13: IME module

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`
- Modify: `tests/test_builtin_status.zig`

- [ ] **Step 1: Write test for IME state classification**

```zig
test "cpu threshold color" {
    // CPU > 80% should use alert color
    try std.testing.expectEqual(@as(u32, 0xe06c75), builtin_status.cpuColor(85));
    try std.testing.expectEqual(@as(u32, 0x6a9955), builtin_status.cpuColor(50));
    try std.testing.expectEqual(@as(u32, 0x6a9955), builtin_status.cpuColor(80)); // 80 is not > 80
}

test "battery threshold color" {
    // BAT < 20% should use alert color
    try std.testing.expectEqual(@as(u32, 0xe06c75), builtin_status.batColor(15));
    try std.testing.expectEqual(@as(u32, 0x98c379), builtin_status.batColor(20)); // 20 is not < 20
    try std.testing.expectEqual(@as(u32, 0x98c379), builtin_status.batColor(78));
}

test "classify IME state" {
    try std.testing.expectEqual(builtin_status.ImeState.japanese, builtin_status.classifyIme("mozc"));
    try std.testing.expectEqual(builtin_status.ImeState.japanese, builtin_status.classifyIme("anthy"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme("keyboard-us"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme("keyboard-jp"));
    try std.testing.expectEqual(builtin_status.ImeState.direct, builtin_status.classifyIme(""));
}
```

- [ ] **Step 2: Implement IME classifier**

```zig
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

// readImeState() uses XGetWindowProperty on _FCITX_CURRENT_IM atom
// This requires the Xlib Display* pointer, so it's called from main.zig
// and the result is passed to the module.
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: Pass.

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig tests/test_builtin_status.zig
git commit -m "feat(bar): add IME state detection module"
```

---

## Chunk 4: Module Integration & Built-in Mode

### Task 14: Integrate all modules into bar main loop

**Files:**
- Modify: `zephwm-bar/main.zig` (main loop, built-in mode)
- Modify: `zephwm-bar/builtin_status.zig` (add `updateAll` coordinator)

- [ ] **Step 1: Add module state and update coordinator to builtin_status.zig**

```zig
pub const ModuleState = struct {
    // Timestamps (seconds since epoch, from monotonic clock)
    cpu_last: i64 = 0,
    mem_last: i64 = 0,
    net_last: i64 = 0,
    bat_last: i64 = 0,
    ime_last: i64 = 0,
    clock_last_minute: i8 = -1,

    // CPU needs previous sample
    cpu_prev: CpuSample = .{ .user = 0, .nice = 0, .system = 0, .idle = 0, .iowait = 0, .irq = 0, .softirq = 0 },

    // Cached wireless interface name
    wifi_iface: ?[16]u8 = null,
    wifi_iface_discovered: bool = false,

    dirty: bool = true,  // Force initial draw

    // Module colors
    const CPU_COLOR: u32 = 0x6a9955;
    const CPU_ALERT: u32 = 0xe06c75;
    const MEM_COLOR: u32 = 0x569cd6;
    const SWAP_COLOR: u32 = 0xd19a66;
    const NET_COLOR: u32 = 0x56b6c2;
    const NET_OFF_COLOR: u32 = 0x555555;
    const BAT_COLOR: u32 = 0x98c379;
    const BAT_ALERT: u32 = 0xe06c75;
    const IME_COLOR: u32 = 0xc678dd;
    const CLOCK_COLOR: u32 = 0xe0e0e0;

    // Update intervals in seconds
    const CPU_INTERVAL: i64 = 2;
    const MEM_INTERVAL: i64 = 5;
    const NET_INTERVAL: i64 = 10;
    const BAT_INTERVAL: i64 = 30;
    const IME_INTERVAL: i64 = 1;
};
```

- [ ] **Step 2: Define ModuleOutput struct (no StatusBlock dependency)**

`builtin_status.zig` defines its own output struct to avoid importing `StatusBlock` from `main.zig`:

```zig
pub const ModuleOutput = struct {
    text: [256]u8 = .{0} ** 256,
    text_len: u16 = 0,
    color: u32 = 0,

    pub fn set(self: *ModuleOutput, str: []const u8, col: u32) void {
        const len = @min(str.len, 256);
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = @intCast(len);
        self.color = col;
    }

    pub fn hide(self: *ModuleOutput) void {
        self.text_len = 0;
    }
};
```

Module order: CPU(0), MEM(1), SW(2), WiFi(3), BAT(4), IME(5), Clock(6).

- [ ] **Step 3: Implement `updateAll` function**

```zig
pub fn updateAll(state: *ModuleState, now: i64, display: *anyopaque, root_window: u64, outputs: *[7]ModuleOutput) void {
    // CPU (every 2s)
    if (now - state.cpu_last >= CPU_INTERVAL) {
        state.cpu_last = now;
        var buf: [512]u8 = undefined;
        if (readFileContent("/proc/stat", &buf)) |content| {
            // Find first line starting with "cpu "
            var lines = std.mem.tokenizeScalar(u8, content, '\n');
            if (lines.next()) |cpu_line| {
                const curr = CpuSample.parse(cpu_line);
                const pct = cpuPercent(state.cpu_prev, curr);
                state.cpu_prev = curr;
                var text_buf: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&text_buf, "CPU {d}%", .{pct}) catch "CPU ?%";
                const color = if (pct > 80) ModuleState.CPU_ALERT else ModuleState.CPU_COLOR;
                outputs[0].set(text, color);
                state.dirty = true;
            }
        }
    }

    // MEM + SWAP (every 5s)
    if (now - state.mem_last >= MEM_INTERVAL) {
        state.mem_last = now;
        var buf: [2048]u8 = undefined;
        if (readFileContent("/proc/meminfo", &buf)) |content| {
            const info = MemInfo.parse(content);
            var mem_text: [16]u8 = undefined;
            const mem_fmt = formatKB(info.mem_used_kb);
            const mt = std.fmt.bufPrint(&mem_text, "MEM {s}", .{mem_fmt.slice()}) catch "MEM ?";
            outputs[1].set(mt, ModuleState.MEM_COLOR);

            var sw_text: [16]u8 = undefined;
            const sw_fmt = formatKB(info.swap_used_kb);
            const st = std.fmt.bufPrint(&sw_text, "SW {s}", .{sw_fmt.slice()}) catch "SW ?";
            outputs[2].set(st, ModuleState.SWAP_COLOR);
            state.dirty = true;
        }
    }

    // Network (every 10s)
    if (now - state.net_last >= NET_INTERVAL) {
        state.net_last = now;
        if (!state.wifi_iface_discovered) {
            state.wifi_iface = discoverWirelessInterface();
            state.wifi_iface_discovered = true;
        }
        if (state.wifi_iface) |iface| {
            if (getSsid(iface[0..std.mem.indexOfScalar(u8, &iface, 0) orelse 16])) |ssid| {
                var text_buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&text_buf, "WiFi {s}", .{ssid.slice()}) catch "WiFi ?";
                outputs[3].set(text, ModuleState.NET_COLOR);
            } else {
                outputs[3].set("No WiFi", ModuleState.NET_OFF_COLOR);
            }
        } else {
            outputs[3].hide();
        }
        state.dirty = true;
    }

    // Battery (every 30s)
    if (now - state.bat_last >= BAT_INTERVAL) {
        state.bat_last = now;
        if (readBatteryPercent()) |pct| {
            var text_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "BAT {d}%", .{pct}) catch "BAT ?%";
            const color = if (pct < 20) ModuleState.BAT_ALERT else ModuleState.BAT_COLOR;
            outputs[4].set(text, color);
        } else {
            outputs[4].hide();
        }
        state.dirty = true;
    }

    // IME (every 1s) - uses Xlib Display* passed from main
    if (now - state.ime_last >= IME_INTERVAL) {
        state.ime_last = now;
        const ime_state = readImeProperty(@ptrCast(display), @intCast(root_window));
        switch (ime_state) {
            .japanese => outputs[5].set("\xe3\x81\x82", ModuleState.IME_COLOR), // "あ" UTF-8
            .direct => outputs[5].set("A", ModuleState.IME_COLOR),
            .unavailable => outputs[5].hide(),
        }
        state.dirty = true;
    }

    // Clock (check minute boundary)
    if (getCurrentClock()) |clock| {
        if (clock.minute != state.clock_last_minute) {
            state.clock_last_minute = @intCast(clock.minute);
            const text = formatClock(clock.hour, clock.minute);
            outputs[6].set(&text, ModuleState.CLOCK_COLOR);
            state.dirty = true;
        }
    }
}
```

Hidden modules (no battery, no WiFi, no fcitx5) have `text_len = 0` and are skipped by drawBar.

- [ ] **Step 4: Modify main.zig main loop for built-in mode**

The bar determines its mode from the `GET_BAR_CONFIG` IPC response (not argv). The bar already fetches `status_command` via IPC at startup (line ~250-262 of zephwm-bar/main.zig). If the IPC returns an empty `status_command`, the bar enters built-in mode.

After the existing IPC config fetch:

```zig
// Determine mode based on IPC-fetched status_command
const builtin_mode = (status_command_len == 0);
var module_state = builtin_status.ModuleState{};
var builtin_outputs: [7]builtin_status.ModuleOutput = .{.{}} ** 7;

// In the epoll loop, where status pipe would be read:
if (builtin_mode) {
    const now = getMonotonicSeconds();
    builtin_status.updateAll(&module_state, now, display, root_window, &builtin_outputs);
    if (module_state.dirty) {
        // Convert ModuleOutput → StatusBlock for rendering
        block_count = 0;
        for (builtin_outputs) |output| {
            if (output.text_len > 0) {
                blocks[block_count].full_text_len = output.text_len;
                @memcpy(blocks[block_count].full_text[0..output.text_len], output.text[0..output.text_len]);
                blocks[block_count].color = output.color;
                block_count += 1;
            }
        }
        module_state.dirty = false;
        needs_redraw = true;
    }
} else {
    // existing: read from status pipe, parseStatusUpdate
}
```

- [ ] **Step 4: Update drawBar to skip hidden modules**

In `drawBar()`, when iterating status blocks right-to-left, skip blocks with `full_text_len == 0`. Only draw separators between visible blocks.

- [ ] **Step 5: Build and test in Xephyr**

Run: `zig build`
Launch in Xephyr with config `bar { position top }` (no status_command).
Verify: bar shows CPU, MEM, SW, Clock. WiFi/BAT/IME may or may not show depending on system.

- [ ] **Step 6: Commit**

```bash
git add zephwm-bar/main.zig zephwm-bar/builtin_status.zig
git commit -m "feat(bar): integrate built-in status modules into main loop"
```

---

### Task 15: SSID ioctl implementation

**Files:**
- Modify: `zephwm-bar/builtin_status.zig`

- [ ] **Step 1: Implement ioctl SSID reading**

This requires C-interop for `ioctl(SIOCGIWESSID)`:

```zig
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("linux/wireless.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
});

pub fn getSsid(iface_name: []const u8) ?SsidBuf {
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return null;
    defer std.posix.close(sock);

    var essid_buf: [32]u8 = .{0} ** 32;
    var iwreq: c.struct_iwreq = std.mem.zeroes(c.struct_iwreq);

    // Set interface name
    const name_len = @min(iface_name.len, 15);
    @memcpy(iwreq.ifr_ifrn.ifrn_name[0..name_len], iface_name[0..name_len]);

    // Set essid pointer and length
    iwreq.u.essid.pointer = &essid_buf;
    iwreq.u.essid.length = 32;

    if (std.c.ioctl(sock, c.SIOCGIWESSID, &iwreq) < 0) return null;

    const ssid_len = @min(iwreq.u.essid.length, 32);
    if (ssid_len == 0) return null;

    return truncateSsid(essid_buf[0..ssid_len]);
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `zig build`
Expected: Compiles. (The wireless headers should be available on the build system.)

- [ ] **Step 3: Commit**

```bash
git add zephwm-bar/builtin_status.zig
git commit -m "feat(bar): implement SSID reading via ioctl SIOCGIWESSID"
```

---

### Task 16: IME X property reading

**Files:**
- Modify: `zephwm-bar/builtin_status.zig` or `zephwm-bar/main.zig`

- [ ] **Step 1: Implement _FCITX_CURRENT_IM reading**

This uses the existing Xlib Display* connection:

Note: Requires `@cInclude("X11/Xatom.h")` in the bar's `@cImport` block for `XA_STRING`.

```zig
const xlib_c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
});

pub fn readImeProperty(display: *xlib_c.Display, root: xlib_c.Window) ImeState {
    const atom = xlib_c.XInternAtom(display, "_FCITX_CURRENT_IM", 1); // only_if_exists=true
    if (atom == 0) return .unavailable;

    var actual_type: xlib_c.Atom = undefined;
    var actual_format: c_int = undefined;
    var nitems: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop: [*c]u8 = undefined;

    const status = xlib_c.XGetWindowProperty(
        display, root, atom, 0, 64, 0,
        xlib_c.XA_STRING, &actual_type, &actual_format,
        &nitems, &bytes_after, @ptrCast(&prop),
    );

    if (status != 0 or actual_type == 0) return .unavailable;
    defer _ = xlib_c.XFree(@ptrCast(prop));

    const len: usize = @intCast(nitems);
    if (len == 0) return .unavailable;
    return classifyIme(prop[0..len]);
}
```

- [ ] **Step 2: Wire into updateAll**

In the IME section of `updateAll`, call `readImeProperty(display, root)` and format the block:
- `.japanese` → `full_text = "あ"`, `color = IME_COLOR`
- `.direct` → `full_text = "A"`, `color = IME_COLOR`
- `.unavailable` → `full_text_len = 0` (hidden)

- [ ] **Step 3: Build**

Run: `zig build`
Expected: Compiles.

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig zephwm-bar/main.zig
git commit -m "feat(bar): read IME state from _FCITX_CURRENT_IM X property"
```

---

## Chunk 5: Integration Testing & Polish

### Task 17: Integration test — built-in mode

- [ ] **Step 1: Create test config with no status_command**

Write a temp config file:
```
bar {
    position top
}
bindsym Mod1+Return exec true
```

- [ ] **Step 2: Run zephwm in Xephyr and verify**

```bash
Xephyr :99 -screen 720x720 &
DISPLAY=:99 ./zig-out/bin/zephwm &
sleep 2
# Verify bar window exists
DISPLAY=:99 xdotool search --name "" --class "zephwm-bar" | head -1
# Take screenshot
DISPLAY=:99 import -window root /tmp/builtin-mode.png
```

Expected: Bar at top, 16px height, showing status modules with colors.

- [ ] **Step 3: Verify external mode still works**

Test config:
```
bar {
    position top
    status_command i3blocks
}
```

Run same test. Expected: Bar shows i3blocks output with default color.

- [ ] **Step 4: Commit test artifacts if applicable**

```bash
git add tests/
git commit -m "test: add integration test configs for bar modes"
```

---

### Task 18: Default config generation test

- [ ] **Step 1: Test in clean environment**

```bash
Xephyr :99 -screen 720x720 &
HOME=/tmp/zephwm-test DISPLAY=:99 ./zig-out/bin/zephwm &
sleep 2
# Verify config was created
cat /tmp/zephwm-test/.config/zephwm/config
# Verify bar is running
DISPLAY=:99 xdotool search --class "" | wc -l
```

Expected: Config file exists with default content. Bar window present.

- [ ] **Step 2: Commit**

```bash
git commit --allow-empty -m "test: verified default config generation"
```

---

### Task 19: Run full test suite

- [ ] **Step 1: Run all unit tests**

Run: `zig build test`
Expected: All pass.

- [ ] **Step 2: Run existing Docker integration tests**

Run the existing Docker test suite to verify no regressions in WM behavior.

- [ ] **Step 3: Fix any failures**

Address any test failures found.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete bar visual redesign with built-in status modules

- Hybrid bar: built-in /proc readers when no status_command, i3bar protocol when set
- Built-in modules: CPU, MEM, Swap, WiFi (SSID via ioctl), Battery, IME (fcitx5), Clock
- Per-module color rendering with threshold alerts (CPU>80%, BAT<20%)
- Bar visuals: 16px height, monospace:size=8, deep dark bg, pipe separators
- Default config auto-generation on first launch
- Bar respawn on config reload"
```
