# zephwm Generalization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove HackberryPi-specific assumptions so zephwm works on any Linux x86_64/aarch64 system.

**Architecture:** Five targeted fixes across 4 files: comptime struct padding for IwreqRaw, screen-size fallback via EventContext, font/height config flow from config.zig through IPC to bar binary, and bar init reordering.

**Tech Stack:** Zig, XCB, Xft, Linux sysfs/ioctl

**Spec:** `docs/superpowers/specs/2026-03-27-generalization-design.md`

---

## Chunk 1: WM-side changes (config, IPC, fallback)

### Task 1: IwreqRaw comptime padding

**Files:**
- Modify: `zephwm-bar/builtin_status.zig:229-246`

- [ ] **Step 1: Replace IwreqRaw with comptime-padded version**

Replace the existing struct and comments at lines 233-246:

```zig
// iwreq layout: 32 bytes total (16-byte name + 16-byte union)
// Union ifr_ifru is always 16 bytes on Linux regardless of architecture.
const IwreqRaw = extern struct {
    ifrn_name: [IFNAMSIZ]u8,
    // iw_point members from union iwreq_data
    pointer: ?[*]u8,
    length: u16,
    flags: u16,
    // Pad to fixed 16-byte union size (arch-independent)
    _pad: [16 - @sizeOf(?[*]u8) - @sizeOf(u16) - @sizeOf(u16)]u8,
};
comptime {
    if (@sizeOf(IwreqRaw) != 32) @compileError("IwreqRaw size mismatch");
}
```

- [ ] **Step 2: Build and verify comptime assertion passes**

Run: `zig build 2>&1`
Expected: clean build, no compile errors

- [ ] **Step 3: Run existing tests**

Run: `zig build test 2>&1`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add zephwm-bar/builtin_status.zig
git commit -m "fix: make IwreqRaw arch-portable with comptime padding"
```

---

### Task 2: Fallback output resolution via EventContext

**Files:**
- Modify: `src/event.zig:28-59` (EventContext struct)
- Modify: `src/main.zig:294-295` (buildOutputsJson fallback)
- Modify: `src/main.zig` (~line 769, EventContext init)

- [ ] **Step 1: Add screen_width/height to EventContext**

In `src/event.zig`, add to the `EventContext` struct after `randr_base_event`:

```zig
    screen_width: u16 = 0,
    screen_height: u16 = 0,
```

- [ ] **Step 2: Populate screen dimensions at init**

In `src/main.zig`, find where `EventContext` is initialized (search for `var ctx = EventContext{` or `.tree_root =`). Add:

```zig
    .screen_width = screen.width_in_pixels,
    .screen_height = screen.height_in_pixels,
```

- [ ] **Step 3: Replace 720x720 hardcode in buildOutputsJson**

In `src/main.zig`, function `buildOutputsJson`, replace the hardcoded return at line 295:

```zig
    if (first) {
        var fallback_fbs = std.io.fixedBufferStream(buf);
        const fw = fallback_fbs.writer();
        fw.print("[{{\"name\":\"default\",\"active\":true,\"primary\":true," ++
            "\"rect\":{{\"x\":0,\"y\":0,\"width\":{d},\"height\":{d}}}," ++
            "\"current_workspace\":\"1\"}}]", .{ ctx.screen_width, ctx.screen_height }) catch return "[]";
        return fallback_fbs.getWritten();
    }
```

Note: `buf` is the `dyn_buf` parameter. Use a separate `fixedBufferStream` since `fbs`/`w` are already positioned past any partial output writes.

- [ ] **Step 4: Build and test**

Run: `zig build test 2>&1`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add src/event.zig src/main.zig
git commit -m "fix: use actual screen size for fallback output resolution"
```

---

### Task 3: Font config — WM side

**Files:**
- Modify: `src/config.zig:27-34` (BarConfig)
- Modify: `src/config.zig:86-89` (owned flags)
- Modify: `src/config.zig:163-175` (bar block parsing)
- Modify: `src/config.zig:547-551` (deinit)
- Modify: `src/main.zig:304-323` (buildBarConfigJson)

- [ ] **Step 1: Add font field to BarConfig**

In `src/config.zig`, `BarConfig` struct:

```zig
pub const BarConfig = struct {
    enabled: bool = false,
    status_command: []const u8 = "",
    position: []const u8 = "bottom",
    font: []const u8 = "monospace:size=11",
    bg_color: []const u8 = "#222222",
    statusline_color: []const u8 = "#dddddd",
    height: u16 = 22,
};
```

Note: `height` default changes from `16` to `22`.

- [ ] **Step 2: Add bar_font_owned flag**

In `src/config.zig`, `Config` struct, after `bar_position_owned`:

```zig
    bar_font_owned: bool = false,
```

- [ ] **Step 3: Parse font directive in bar block**

In `src/config.zig`, in the `if (in_bar)` block, after the `height` parsing, add:

```zig
                } else if (std.mem.startsWith(u8, line, "font ")) {
                    if (cfg.bar_font_owned) cfg.allocator.free(cfg.bar.font);
                    cfg.bar.font = try allocator.dupe(u8, std.mem.trim(u8, line["font ".len..], " \t"));
                    cfg.bar_font_owned = true;
```

- [ ] **Step 4: Free font in deinit**

In `src/config.zig`, `deinit` function, after `bar_statusline_color_owned` line:

```zig
        if (self.bar_font_owned) self.allocator.free(self.bar.font);
```

- [ ] **Step 5: Include font in IPC bar config JSON**

In `src/main.zig`, `buildBarConfigJson`, add font field after `bar_height`:

```zig
    w.writeAll(",\"font\":\"") catch return "{}";
    jsonEscapeWrite(w, cfg.bar.font) catch return "{}";
    w.writeAll("\"") catch return "{}";
```

This goes between the `bar_height` line and the `colors` block.

- [ ] **Step 6: Write config parser test for font**

In the existing test file `tests/test_config.zig`, add:

```zig
test "bar font parsing" {
    const input =
        \\bar {
        \\    font DejaVu Sans Mono:size=10
        \\    position top
        \\}
    ;
    var cfg = try Config.parse(std.testing.allocator, input);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("DejaVu Sans Mono:size=10", cfg.bar.font);
    try std.testing.expect(cfg.bar.enabled);
}
```

- [ ] **Step 7: Build and test**

Run: `zig build test 2>&1`
Expected: all pass including new font test

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/main.zig tests/test_config.zig
git commit -m "feat: add font config for bar with IPC support"
```

---

## Chunk 2: Bar binary changes (init reorder, height, padding)

### Task 4: Bar init reorder + config parsing

**Files:**
- Modify: `zephwm-bar/main.zig` (main function, lines 66-310)

This is the critical task. The bar binary must query IPC config BEFORE creating windows and opening fonts.

- [ ] **Step 1: Add config parsing helper**

Add a helper function before `pub fn main()` in `zephwm-bar/main.zig`:

```zig
/// Parse bar config from IPC JSON. Returns (font_name, bar_height).
/// Falls back to defaults on parse failure.
fn parseBarConfig(allocator: std.mem.Allocator, sock_path: []const u8) struct {
    font: []const u8,
    bar_height: u16,
    status_command: []const u8,
} {
    const default_font = "monospace:size=11";
    const default_height: u16 = 22;

    const bar_cfg = ipc.sendRequest(allocator, sock_path, .get_bar_config, "") orelse
        return .{ .font = default_font, .bar_height = default_height, .status_command = "" };
    defer allocator.free(bar_cfg);

    // Parse font
    var font: []const u8 = default_font;
    if (std.mem.indexOf(u8, bar_cfg, "\"font\":\"")) |pos| {
        const start = pos + 8;
        if (std.mem.indexOfScalar(u8, bar_cfg[start..], '"')) |end| {
            font = bar_cfg[start .. start + end];
        }
    }

    // Parse bar_height
    var bar_height: u16 = default_height;
    if (std.mem.indexOf(u8, bar_cfg, "\"bar_height\":")) |pos| {
        const start = pos + 13;
        var num_end = start;
        while (num_end < bar_cfg.len and bar_cfg[num_end] >= '0' and bar_cfg[num_end] <= '9') : (num_end += 1) {}
        if (num_end > start) {
            bar_height = std.fmt.parseInt(u16, bar_cfg[start..num_end], 10) catch default_height;
        }
    }

    // Parse status_command
    var status_cmd: []const u8 = "";
    if (std.mem.indexOf(u8, bar_cfg, "\"status_command\":\"")) |pos| {
        const start = pos + 18;
        if (std.mem.indexOfScalar(u8, bar_cfg[start..], '"')) |end| {
            status_cmd = bar_cfg[start .. start + end];
        }
    }

    return .{ .font = font, .bar_height = bar_height, .status_command = status_cmd };
}
```

- [ ] **Step 2: Reorder main() — move IPC config query before window/font creation**

In `main()`, after output discovery (line 137, after `bar_count = 1` fallback), insert the IPC config query:

```zig
    // Query IPC for bar config (font, height) BEFORE creating windows/fonts
    const bar_cfg = parseBarConfig(allocator, sock_path);
    const bar_height: u16 = bar_cfg.bar_height;

    // Compute padding from bar height
    const ws_button_pad: u16 = @max(bar_height / 2, 4);
    const status_pad: u16 = @max(bar_height * 3 / 8, 3);
    const separator_pad: u16 = @max(bar_height / 4, 2);
```

- [ ] **Step 3: Replace BAR_HEIGHT const references**

Replace the `const BAR_HEIGHT: u16 = 16;` line with a comment:

```zig
// BAR_HEIGHT is now dynamic — parsed from IPC config in main()
```

Then replace ALL occurrences of `BAR_HEIGHT` in the file with the local `bar_height` variable. The affected locations:
- Window creation: `bar_y` calculation and `xcb_create_window` height
- Strut partial: `strut[2]` and `strut[3]`
- `drawBar`: background fill rect height, workspace button rect height
- `handleClick`: click event JSON height

Since `bar_height` is a local in `main()`, and `drawBar`/`handleClick` are separate functions, pass `bar_height` as a parameter to both functions.

Update `drawBar` signature to include `bar_height: u16, ws_button_pad: u16, status_pad: u16, separator_pad: u16`.
Update `handleClick` signature to include `bar_height: u16, ws_button_pad: u16`.

- [ ] **Step 4: Replace FONT_NAME with config value**

Replace:
```zig
const font = c.XftFontOpenName(dpy, screen_num, FONT_NAME) orelse {
```
With:
```zig
    // Use font from config, null-terminated for C API
    var font_buf: [256]u8 = undefined;
    const font_len = @min(bar_cfg.font.len, font_buf.len - 1);
    @memcpy(font_buf[0..font_len], bar_cfg.font[0..font_len]);
    font_buf[font_len] = 0;
    const font_z: [*:0]const u8 = @ptrCast(font_buf[0..font_len :0]);

    const font = c.XftFontOpenName(dpy, screen_num, font_z) orelse {
        std.debug.print("zephwm-bar: cannot open font '{s}'\n", .{bar_cfg.font});
        return;
    };
```

Remove the `const FONT_NAME` constant.

- [ ] **Step 5: Replace WS_BUTTON_PAD, STATUS_PAD, SEPARATOR_PAD constants**

Remove these three constants from the top of the file. They are now computed in `main()` from `bar_height` and passed as parameters.

- [ ] **Step 6: Fix text vertical centering**

In `drawBar`, replace:
```zig
    const text_y: c_int = @intCast(font.*.ascent + 2);
```
With:
```zig
    const text_y: c_int = @intCast((@as(c_int, bar_height) - (font.*.ascent + font.*.descent)) / 2 + font.*.ascent);
```

- [ ] **Step 7: Move status_command handling after parseBarConfig**

The existing status_command parsing code (lines 251-276) that does its own IPC query can be simplified since `parseBarConfig` already parsed it. Replace the IPC query block with:

```zig
    var status_pipe_fd: std.posix.fd_t = -1;
    var status_stdin_fd: std.posix.fd_t = -1;
    const status_command_len = bar_cfg.status_command.len;
    if (status_command_len > 0) {
        const spawn_result = spawnStatusCommand(bar_cfg.status_command);
        status_pipe_fd = spawn_result.stdout_fd;
        status_stdin_fd = spawn_result.stdin_fd;
    }
```

- [ ] **Step 8: Build**

Run: `zig build 2>&1`
Expected: clean build

- [ ] **Step 9: Run all tests**

Run: `zig build test 2>&1`
Expected: all pass

- [ ] **Step 10: Commit**

```bash
git add zephwm-bar/main.zig
git commit -m "feat: bar reads font/height from config, dynamic padding and text centering"
```

---

### Task 5: Update default config and final verification

**Files:**
- Modify: `src/main.zig` (embedded default config, ~line 85-96)
- Modify: `config/default_config` (if exists)

- [ ] **Step 1: Update embedded default config**

In `src/main.zig`, the embedded default config string. Change:
```
\\# Bar (built-in status modules, no external status_command needed)
\\bar {
\\    position top
\\}
```
To:
```
\\# Bar (built-in status modules, no external status_command needed)
\\bar {
\\    position top
\\    font monospace:size=11
\\    height 22
\\}
```

- [ ] **Step 2: Update config/default_config if present**

Check if `config/default_config` exists. If so, add `font` and `height` lines to its `bar {}` block.

- [ ] **Step 3: Full build and test**

Run: `zig build test 2>&1`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add src/main.zig config/
git commit -m "chore: update default config with font and height defaults"
```
