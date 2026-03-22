# zephwm-bar Visual Redesign & Default Startup Experience

## Summary

Redesign zephwm-bar for a crisp, minimal aesthetic optimized for the 720x720 HackberryPi display. Add built-in status modules so the bar works out-of-the-box with no external dependencies. Generate a default config on first launch so new users see a usable WM immediately.

## Problem

1. **Black screen on first launch**: Without a config file, zephwm shows nothing — no bar, no keybinds, no programs. The WM is effectively unusable.
2. **External dependency for status**: The bar requires `status_command` pointing to an external program (e.g., i3blocks). On a fresh system, nothing is installed.
3. **Bar visuals are plain**: Hardcoded i3 defaults (20px, monospace:size=10, single-color status text) don't look sharp on the HackberryPi's 720x720 display.

## Design

### 1. Hybrid Status Architecture

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

### 2. Built-in Status Modules

| Module | Source | Update Interval | Display Format | Color |
|--------|--------|----------------|----------------|-------|
| CPU | `/proc/stat` (diff between reads) | 2s | `CPU 12%` | `#6a9955` (green) |
| Memory | `/proc/meminfo` MemAvailable | 5s | `MEM 234M` | `#569cd6` (blue) |
| Swap | `/proc/meminfo` SwapTotal-SwapFree | 5s | `SW 45M` | `#d19a66` (orange) |
| Network | `/proc/net/wireless` + `/proc/net/if_inet6` or ioctl for SSID | 10s | `WiFi BCW730J-8086A` | `#56b6c2` (cyan) |
| Battery | `/sys/class/power_supply/*/capacity` | 30s | `BAT 78%` | `#98c379` (green) |
| IME | X input method property or fcitx5 state | 1s | `IME` or `あ` | `#c678dd` (purple) |
| Clock | `clock_gettime(CLOCK_REALTIME)` | 60s | `14:32` | `#e0e0e0` (white) |

Module order (left to right in the right section): CPU, MEM, SW, WiFi, BAT, IME, Clock.

#### Threshold-based color changes

- CPU > 80%: label turns `#e06c75` (red)
- BAT < 20%: label turns `#e06c75` (red)
- WiFi disconnected: displays `No WiFi` in `#555555` (dark gray)

#### SSID truncation

Long SSIDs are truncated to 14 characters with `...` suffix. Example: `BCW730J-8086A-...`.

#### Update scheduling

Each module tracks its own `last_updated` timestamp. On each epoll cycle (500ms), the bar checks which modules are due for refresh. Only stale modules re-read their `/proc` or `/sys` sources. This keeps I/O minimal.

### 3. Bar Visual Improvements

Changes from current rendering constants:

| Property | Current | New |
|----------|---------|-----|
| Bar height | 20px | 16px |
| Font | `monospace:size=10` | `monospace:size=8` |
| Background | `#222222` | `#1a1a2e` |
| Status text | all `#dddddd` | per-module color (see table above) |
| Separator | none | `\|` pipe in `#505060` |
| Focused workspace bg | `#285577` | `#4a6fa5` |
| Unfocused workspace text | `#888888` | `#606060` |

The rendering changes are in `drawBar()`. For built-in mode, each `StatusBlock` carries a color field that `drawBar()` uses. For external mode, the existing single-color rendering is preserved (unless the i3bar protocol's `color` field is set per-block, which is already part of the protocol but not currently parsed).

### 4. Default Config Auto-Generation

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
  → mkdir -p ~/.config/zephwm/
  → write default config to ~/.config/zephwm/config
  → log: "Generated default config at ~/.config/zephwm/config"
  → load the generated file as config
```

### 5. Bar Spawning Without status_command

Current logic in `main.zig`:
```zig
if (cfg.bar.status_command.len > 0) {
    bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
}
```

This must change to spawn the bar even without `status_command`:
```zig
if (cfg.bar.status_command.len > 0) {
    bar.spawnBar(cfg.bar.status_command, cfg.bar.position);
} else {
    bar.spawnBar("", cfg.bar.position);  // built-in mode
}
```

The bar binary itself checks: if `status_command` is empty, initialize built-in modules instead of spawning an external process.

### 6. IME State Detection

For fcitx5 (installed on HackberryPi):

**Approach**: Read the X root window property `_FCITX_INPUT_STATUS` or use the `XMODIFIERS` / fcitx5 remote tool. The simplest reliable method is:

- Check `_NET_WM_PID` of focused window for input method client
- Read `/proc/bus/input/devices` or poll fcitx5's D-Bus interface

**Practical approach for minimal deps**: Use `XGetInputFocus` + check `_XWAYLAND_INPUT_METHOD_STATE` or the XIM protocol state. If fcitx5 is not available, display `--` instead.

**Fallback**: If no IME detection method works, the IME module is silently hidden (no space consumed in the bar).

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
