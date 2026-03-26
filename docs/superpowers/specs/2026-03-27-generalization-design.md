# zephwm Generalization — Multi-Platform Portability

**Date**: 2026-03-27
**Goal**: Remove HackberryPi-specific assumptions so zephwm works correctly on x86_64 desktops, laptops, and other ARM boards without code changes.

## Scope

Minimum changes to fix portability issues. No DPI-awareness, no module system redesign, no new features.

## Changes

### 1. IwreqRaw Architecture Portability

**File**: `zephwm-bar/builtin_status.zig`

**Problem**: The `IwreqRaw` struct hardcodes an x86_64-specific layout with a raw pointer and manual 4-byte padding. On 32-bit architectures, pointer size differs and the padding is wrong. The layout comment even says "x86_64".

**Fix**: The `iwreq` union `ifr_ifru` is always 16 bytes on Linux regardless of architecture. Use comptime to calculate correct padding:

```zig
const IwreqRaw = extern struct {
    ifrn_name: [IFNAMSIZ]u8,       // 16 bytes
    pointer: ?[*]u8,               // arch-dependent (4 or 8)
    length: u16,
    flags: u16,
    // Pad to fixed 16-byte union size
    _pad: [16 - @sizeOf(?[*]u8) - @sizeOf(u16) - @sizeOf(u16)]u8,
};
comptime { if (@sizeOf(IwreqRaw) != 32) @compileError("IwreqRaw size mismatch"); }
```

This computes the correct padding at comptime for any architecture.

### 2. Fallback Output Resolution

**File**: `src/main.zig`, function `buildOutputsJson`

**Problem**: When RandR returns no outputs, the IPC response hardcodes `720x720`.

**Fix**: Add `screen_width: u16` and `screen_height: u16` fields to `EventContext`. Populate them from `screen.width_in_pixels` / `screen.height_in_pixels` at initialization (alongside other screen-derived fields). `buildOutputsJson` reads these from `ctx` for the fallback:

```zig
if (first) {
    w.print("[{{\"name\":\"default\",\"active\":true,\"primary\":true," ++
        "\"rect\":{{\"x\":0,\"y\":0,\"width\":{d},\"height\":{d}}}," ++
        "\"current_workspace\":\"1\"}}]", .{ ctx.screen_width, ctx.screen_height }) catch return "[]";
    return fbs.getWritten();
}
```

No function signature change needed — values come from `ctx`.

### 3. Font Name Config

**Files**: `src/config.zig`, `src/main.zig`, `zephwm-bar/main.zig`

**Problem**: Font is hardcoded as `monospace:size=8` in the bar binary. Too small for anything above 720p.

**Config syntax** (i3-compatible):
```
bar {
    font monospace:size=11
}
```

**Default**: `monospace:size=11`.

**Data flow**:
1. `config.zig`: Add `font: []const u8 = "monospace:size=11"` to `BarConfig`. Add `bar_font_owned: bool = false` to `Config` for memory management. Free in `deinit` when owned (same pattern as `bar_status_command_owned`).
2. `config.zig`: Parse `font` directive in the `bar {}` block.
3. `main.zig` (`buildBarConfigJson`): Include `"font":"..."` in IPC JSON response (via `jsonEscapeWrite`).
4. `zephwm-bar/main.zig`: Parse `font` field from IPC bar config JSON. Fall back to `monospace:size=11` if parse fails.

### 4. Bar Height Config

**Files**: `src/config.zig`, `zephwm-bar/main.zig`

**Problem**: `BAR_HEIGHT` is hardcoded as `16` in the bar binary, ignoring the `bar_height` value already sent via IPC.

**Default change**: `16` → `22` in both `config.zig` BarConfig default and the bar binary fallback constant.

**Data flow**:
1. `config.zig`: Change default from `16` to `22`
2. `main.zig` (`buildBarConfigJson`): Already includes `bar_height` in IPC response — no change
3. `zephwm-bar/main.zig`: Parse `bar_height` from IPC JSON, replace `BAR_HEIGHT` const with parsed variable throughout (window creation, struts, draw, click events)

### 5. Padding and Text Centering

**File**: `zephwm-bar/main.zig`

**Problem**: `WS_BUTTON_PAD=10`, `STATUS_PAD=8`, `SEPARATOR_PAD=4` are hardcoded for `BAR_HEIGHT=16`. Text y-offset is `font.ascent + 2` which works at 16px but misaligns at larger heights.

**Fix padding**: Derive from bar height, with minimum clamps:
```zig
const ws_button_pad: u16 = @max(bar_height / 2, 4);
const status_pad: u16 = @max(bar_height * 3 / 8, 3);
const separator_pad: u16 = @max(bar_height / 4, 2);
```

**Fix text centering**: Replace hardcoded `font.ascent + 2` with proper vertical centering:
```zig
const text_y: c_int = @intCast((@as(c_int, bar_height) - (font.ascent + font.descent)) / 2 + font.ascent);
```

### 6. Bar Binary Initialization Order (Critical)

**File**: `zephwm-bar/main.zig`

**Problem**: The current initialization order is:
1. Open display, get screen
2. Create X windows (uses `BAR_HEIGHT` const)
3. Open font (uses `FONT_NAME` const)
4. Parse IPC bar config (reads `status_command`)

Config is parsed AFTER windows and font are created, so `font` and `bar_height` config values would be ignored.

**Fix**: Move IPC bar config query to BEFORE window creation and font opening. The new order:
1. Open display, get screen, discover outputs
2. **Query IPC for bar config (font, height, status_command)**
3. Open font with config value (fallback to default on failure)
4. Create X windows with config bar_height
5. Start status_command / enter built-in mode

This is a reorder of existing code, not new logic. The IPC socket path is already available at this point.

## Out of Scope

- DPI-aware scaling
- Per-module color configuration
- Module enable/disable in config (hardware auto-detection handles this)
- Font configuration for WM title bars (separate concern)
- Multi-font fallback chains

## Test Plan

- Existing unit tests pass (no behavioral changes to tree/layout/config core)
- `comptime` assertion: `@sizeOf(IwreqRaw) == 32`
- Config parser handles `font` directive correctly
- Config parser test for `height` inside bar block
- Bar binary falls back to defaults when IPC config fields are missing
- Manual test: x86_64 desktop at 1920x1080 with default config
- Manual test: HackberryPi 720x720 with `font monospace:size=8` + `height 16` override (verify old behavior still works)
