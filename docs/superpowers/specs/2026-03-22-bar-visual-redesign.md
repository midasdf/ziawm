# zephwm-bar Visual Redesign & Default Startup Experience

## Summary

Redesign zephwm-bar for a crisp, minimal aesthetic optimized for the 720x720 HackberryPi display. Add built-in status modules so the bar works out-of-the-box with no external dependencies. Generate a default config on first launch so new users see a usable WM immediately.

## Problem

1. **Black screen on first launch**: Without a config file, zephwm shows nothing — no bar, no keybinds, no programs. The WM is effectively unusable.
2. **External dependency for status**: The bar requires `status_command` pointing to an external program (e.g., i3blocks). On a fresh system, nothing is installed.
3. **Bar visuals are plain**: Hardcoded i3 defaults (20px, monospace:size=10, single-color status text) don't look sharp on the HackberryPi's 720x720 display.

## Design

### 1. Bar Presence Decoupled from status_command

Currently, the bar's existence is coupled to `status_command.len > 0` in three places:
- `main.zig`: bar spawning
- `event.zig`: bar space reservation (`bar_height = 20`)
- `main.zig` IPC: `GET_BAR_CONFIG` response

This coupling must be broken. The bar should be spawned and space reserved whenever a `bar {}` block is present in config, regardless of `status_command`. A new `BarConfig.enabled` flag (set to `true` when a `bar {}` block is parsed) controls all bar-related behavior.

Changes required:
- `config.zig`: Update `BarConfig` struct and parser:

```zig
pub const BarConfig = struct {
    enabled: bool = false,                  // NEW: true when bar {} block is parsed
    status_command: []const u8 = "",
    position: []const u8 = "bottom",
    bg_color: []const u8 = "#222222",
    statusline_color: []const u8 = "#dddddd",
    height: u16 = 16,                       // NEW: bar height in pixels (default 16)
};
```

In the config parser, when entering the `bar {` block (currently sets `in_bar = true`), also set `cfg.bar.enabled = true`.

- `main.zig` bar spawning: Check `cfg.bar.enabled` instead of `cfg.bar.status_command.len > 0`.
- `event.zig` space reservation: Check `cfg.bar.enabled` instead of `cfg.bar.status_command.len > 0`. Use `cfg.bar.height` instead of hardcoded 20.
- `bar.zig` `spawnBar()`: Remove the `if (status_command.len == 0) return;` early-return guard. The `status_command` parameter is still passed to the bar binary as `argv[1]`. When `status_command` is `""`, the bar binary receives an empty string as argv[1] and enters built-in mode. When non-empty, it spawns the external process as before.
- `main.zig` IPC `GET_BAR_CONFIG`: Report `bar_height` from `cfg.bar.height`, not hardcoded 20.
- `main.zig` reload handler (SIGUSR1): Add `bar.killBar()` + `bar.spawnBar()` to the reload path. Currently the reload handler does NOT respawn the bar — this must be added so the bar picks up new config on `$mod+Shift+c`.

### 2. Hybrid Status Architecture

The bar operates in two modes, selected automatically:

- **Built-in mode** (default): When `status_command` is not set in the `bar {}` config block, the bar reads system stats directly from `/proc` and `/sys` and renders them with per-module coloring.
- **External mode** (existing): When `status_command` is set, the bar uses the existing i3bar JSON protocol to receive status blocks from the external process. No changes to this path.

Both modes produce the same internal data structure (`StatusBlock[]`) and share the same rendering pipeline.

```
Built-in mode:
  /proc/stat, /proc/meminfo, /sys/class/... → StatusBlock[] → drawBar()

External mode:
  status_command stdout (i3bar JSON) → StatusBlock[] → drawBar()
```

#### StatusBlock struct change

The existing `StatusBlock` struct gains a `color` field:

```zig
const StatusBlock = struct {
    name: [64]u8,
    instance: [64]u8,
    full_text: [256]u8,
    full_text_len: u16,
    color: u32,           // NEW: pixel color value (0xRRGGBB), 0 = use default fg
};
```

- Built-in modules populate `color` with their assigned module color (e.g., `0x6a9955` for CPU).
- External mode sets `color = 0` (use default `FG_COLOR`). Parsing the i3bar protocol `color` field is out of scope.

### 3. Built-in Status Modules

| Module | Source | Update Interval | Display Format | Color |
|--------|--------|----------------|----------------|-------|
| CPU | `/proc/stat` (diff between reads) | 2s | `CPU 12%` | `#6a9955` (green) |
| Memory | `/proc/meminfo` (MemTotal - MemAvailable = used) | 5s | `MEM 234M` | `#569cd6` (blue) |
| Swap | `/proc/meminfo` (SwapTotal - SwapFree = used) | 5s | `SW 45M` | `#d19a66` (orange) |
| Network | See SSID detection below | 10s | `WiFi BCW730J-8086A` | `#56b6c2` (cyan) |
| Battery | See battery detection below | 30s | `BAT 78%` | `#98c379` (green) |
| IME | See IME detection below | 1s | `IME` or `あ` | `#c678dd` (purple) |
| Clock | `clock_gettime(CLOCK_REALTIME)` + `localtime_r()` | see below | `14:32` | `#e0e0e0` (white) |

Module order (left to right in the right section): CPU, MEM, SW, WiFi, BAT, IME, Clock.

Notes:
- Memory and Swap display **used** amounts (not available/free).
- Clock uses local time via `localtime_r()` (thread-safe, avoids static buffer), not raw UTC.
- Clock update: compute seconds remaining until the next minute boundary. On each epoll cycle, check if the current minute has changed; only set dirty flag when it has. This avoids both the 59s lag problem and unnecessary 1s polling.

#### SSID detection

1. Discover wireless interface: iterate `/sys/class/net/`, check for `wireless/` subdirectory (e.g., `wlu1u1`, not hardcoded `wlan0`).
2. Get SSID: `ioctl(SIOCGIWESSID)` on a raw socket for the discovered interface. No external library needed — Zig can make this syscall directly.
3. Get connection state: check if the interface is UP and has an SSID.

#### Battery detection

1. Iterate `/sys/class/power_supply/` directory entries.
2. For each entry, read the `type` file. Only use entries where `type` reads `Battery` (skip `Mains`/`USB` AC adapter entries).
3. Read `capacity` file for percentage (0-100).
4. If no battery entry found, the battery module is silently hidden (no space consumed).

#### IME state detection

Use the X root window property `_FCITX_CURRENT_IM` set by fcitx5. This property contains the current input method name as a string (e.g., `keyboard-us`, `mozc`).

- Poll: `XGetWindowProperty` on the root window for `_FCITX_CURRENT_IM` atom every 1s.
- If the property value contains `mozc` or a known Japanese IM name → display `あ` (Japanese active).
- If the property value is `keyboard-*` or empty → display `A` (direct input).
- If the property does not exist (fcitx5 not running) → hide the IME module entirely.

No D-Bus dependency. XGetWindowProperty is already available via the existing Xlib connection.

#### Threshold-based color changes

- CPU > 80%: label turns `#e06c75` (red)
- BAT < 20%: label turns `#e06c75` (red)
- WiFi disconnected: displays `No WiFi` in `#555555` (dark gray)

#### SSID truncation

Long SSIDs are truncated to 14 characters of the original SSID, then `...` is appended (total display width up to 17 characters). Example: `BCW730J-8086A-` (14 chars) + `...` = `BCW730J-8086A-...`. SSIDs of 14 characters or fewer are displayed in full without ellipsis.

#### Separator rendering

- Separator character: `|` rendered in `#505060`.
- Spacing: 4px on each side of the pipe character.
- Separators appear between every visible module (hidden modules produce no separator).
- No trailing separator after the rightmost module (Clock).

#### Update scheduling

Each module tracks its own `last_updated` timestamp. On each epoll cycle (500ms), the bar checks which modules are due for refresh. Only stale modules re-read their `/proc` or `/sys` sources. A global `dirty` flag is set when any module updates; `drawBar()` is only called when `dirty == true` or an X expose event occurs. This minimizes unnecessary X traffic.

### 4. Bar Visual Improvements

Changes from current rendering constants:

| Property | Current | New |
|----------|---------|-----|
| Bar height | 20px | 16px |
| Font | `monospace:size=10` | `monospace:size=8` |
| Background | `#222222` | `#1a1a2e` |
| Status text | all `#dddddd` | per-module color via `StatusBlock.color` |
| Separator | none | `\|` pipe in `#505060` with 4px padding each side |
| Focused workspace bg | `#285577` | `#4a6fa5` |
| Unfocused workspace text | `#888888` | `#606060` |

**Bar height must be updated in all locations:**
- `zephwm-bar/main.zig`: `BAR_HEIGHT` constant (window creation, struts, rendering)
- `src/event.zig`: `bar_height` assignment (workspace layout reservation)
- `src/main.zig`: `GET_BAR_CONFIG` IPC response (`"bar_height"` field)

All three must use the same value (16). Ideally, `event.zig` and the IPC response read the bar height from `BarConfig` rather than using a hardcoded value.

The `drawBar()` rendering changes:
- For built-in mode: each `StatusBlock` has its `color` field set; `drawBar()` creates an `XftColor` from it.
- For external mode: `StatusBlock.color` is 0, so `drawBar()` uses the default `FG_COLOR` (`#dddddd`).

### 5. Default Config Auto-Generation

When zephwm starts and no config file is found at any of the 4 search paths:
1. `$XDG_CONFIG_HOME/zephwm/config`
2. `~/.config/zephwm/config`
3. `~/.zephwm/config`
4. `/etc/zephwm/config`

The WM creates `~/.config/zephwm/config` with a minimal default config, then loads it.

#### Default config contents

```
# zephwm default config

set $mod Mod1

# Terminal
bindsym $mod+Return exec zt

# Close window
bindsym $mod+Shift+q kill

# Focus
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right

# Move
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

# Split
bindsym $mod+b splith
bindsym $mod+v splitv

# Layout
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Fullscreen
bindsym $mod+f fullscreen toggle

# Floating
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle

# Workspaces
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4

bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4

# Reload / Exit
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exit

# Bar (built-in status modules, no external status_command needed)
bar {
    position top
}
```

Key decisions:
- `Mod1` (Alt) — HackberryPi P9981 keyboard has no Win/Super key
- Arrow keys for focus/move — HackberryPi keyboard makes hjkl awkward
- `zt` as default terminal — user's custom terminal
- 4 workspaces — practical limit for 720x720 screen
- `bar { position top }` with no `status_command` — triggers built-in modules

#### Auto-generation flow in main.zig

```
loadConfig():
  try 4 paths → all fail
  → attempt mkdir -p ~/.config/zephwm/
  → if mkdir fails (permissions, read-only FS, HOME unset):
      → log warning: "Could not create config directory: {error}"
      → use in-memory default config (same content, not written to disk)
      → continue startup normally
  → if mkdir succeeds:
      → write default config to ~/.config/zephwm/config
      → log: "Generated default config at ~/.config/zephwm/config"
      → load the generated file as config
```

The WM must never fail to start due to config generation errors. If writing fails, the same defaults are applied in memory.

### 6. Config Reload Behavior

The current reload handler (SIGUSR1 in `main.zig`) does NOT respawn the bar. It only reloads keybinds, colors, and flags. A new step must be added to the reload handler: call `bar.killBar()` then `bar.spawnBar(cfg.bar.status_command, cfg.bar.position)` so the bar picks up new visual settings on `$mod+Shift+c`.

## Scope

### In scope
- Built-in status modules (CPU, MEM, Swap, WiFi, Battery, IME, Clock)
- Hybrid mode (built-in vs external status_command)
- Bar visual refresh (colors, height, font, separators)
- Default config auto-generation
- Bar spawning without status_command
- Per-module color rendering in drawBar()
- SSID truncation (14 chars + ellipsis)
- Threshold-based color changes (CPU high, battery low, WiFi disconnected)

### Out of scope
- Xft font changes in WM title bars (separate effort)
- i3bar protocol `color` field parsing for external mode (nice-to-have, not required)
- Config hot-reload of bar visual settings (existing reload mechanism covers this)
- Custom module ordering via config (hardcoded order for now)

## Testing

- Unit tests for each `/proc` parser (CPU, memory, swap, network, battery)
- Unit tests for SSID truncation logic
- Unit tests for threshold color selection
- Integration test: bar starts in built-in mode with no status_command
- Integration test: bar starts in external mode with status_command set
- Docker test: default config generated when none exists
- Visual verification: bar renders at 16px with correct colors on 720x720 Xephyr
