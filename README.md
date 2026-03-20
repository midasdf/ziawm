# zephwm

**Zig Extreme Performance Hyper Window Manager** — an i3-compatible tiling window manager written in Zig.

Born out of frustration with running i3 on a [HackberryPi Zero](https://github.com/ZitaoTech/Hackberry-Pi_Zero) (RPi Zero 2W, 512MB RAM) where everything felt sluggish — i3 plus its dependencies consumed precious memory and every operation had noticeable latency. zephwm strips away GLib, pango, cairo, and other heavy dependencies, using xcb directly and keeping the entire WM under 200KB. It speaks the i3 IPC protocol, reads i3-style config files, and supports the core i3 workflow: tree-based container management with horizontal/vertical splits, tabbed and stacked layouts, workspaces, and keybind-driven operation.

## Status

**v0.2.0 — Functional.** Core tiling, multi-monitor, status bar, and all essential i3 commands work. 266+ integration tests pass with zero memory leaks.

### Implemented

- Tree-based container model (split h/v, tabbed, stacked)
- Directional focus and move (left/right/up/down/parent/child)
- Resize command (grow/shrink width/height)
- Workspaces (numbered, named, auto-created on demand)
- workspace_auto_back_and_forth
- Multi-monitor via XRandR 1.5 (real hardware + virtual monitors)
- Output hot-plug detection with workspace reflow
- focus_output (left/right/up/down/name)
- i3-compatible IPC protocol (all 11 message types)
- IPC event subscription (workspace, window, mode, output, binding)
- i3-style config file parsing (keybinds, variables, modes, colors, gaps)
- Window kill (graceful WM_DELETE_WINDOW + xcb_kill_client force)
- Fullscreen toggle
- Floating window toggle
- Floating window move/resize (Mod4 + mouse drag)
- Marks (add/remove/query)
- Scratchpad (move/show, multiple windows)
- Exec (fork + /bin/sh -c)
- Config reload (SIGUSR1)
- Restart (in-place re-exec preserving X connection)
- Click-to-focus and focus-follows-mouse
- for_window rules (criteria-based auto-commands)
- assign rules (criteria-based workspace assignment)
- Criteria matching: class, instance, title, window_role, window_type, floating, workspace (glob wildcards)
- EWMH properties (_NET_SUPPORTED, _NET_ACTIVE_WINDOW, _NET_CURRENT_DESKTOP, _NET_CLIENT_LIST, etc.)
- Status bar (zephwm-bar: workspace buttons, status text, click-to-switch, Xft rendering)
- Inner/outer gaps
- Custom border width and colors
- Workspace-output config assignments (`workspace N output NAME`)
- exec_always (re-executed on restart, exec only on fresh start)
- i3bar JSON protocol support in status bar
- Tabbed/stacked title bar text rendering
- Mouse resize for tiling windows (Mod4 + right-drag)

### Not yet implemented

- Binding modes for resize (keybind resize works, mouse resize works)
- Full i3bar click protocol (click events back to status_command)

## Architecture

zephwm is a single-threaded, epoll-based event loop. All core logic (tree, layout, config, command parsing, criteria matching, IPC protocol) is xcb-independent and fully unit-tested.

```
zephwm/
├── src/
│   ├── main.zig          Entry point, epoll event loop, IPC server
│   ├── tree.zig          Container tree (doubly-linked children, marks)
│   ├── layout.zig        Layout calculation (hsplit/vsplit/tabbed/stacked)
│   ├── event.zig         X11 event handlers, command execution
│   ├── config.zig        i3-style config parser
│   ├── command.zig       i3 command string parser
│   ├── criteria.zig      [class="X" title="Y*"] matcher with glob
│   ├── ipc.zig           i3-ipc binary protocol (shared by all binaries)
│   ├── xcb.zig           XCB/RandR C bindings via @cImport
│   ├── atoms.zig         EWMH/ICCCM atom management
│   ├── render.zig        Apply layout geometry to X windows
│   ├── workspace.zig     Workspace find/create helpers
│   ├── scratchpad.zig    Scratchpad operations
│   ├── output.zig        XRandR 1.5 multi-monitor detection + hot-plug
│   └── bar.zig           Bar process spawning
├── zephwm-msg/
│   └── main.zig          IPC client CLI (like i3-msg)
├── zephwm-bar/
│   └── main.zig          Status bar (XCB + Xft)
├── tests/                107+ unit tests
├── config/
│   └── default_config    Default i3-compatible config
├── build.zig
└── build.zig.zon
```

3 binaries: `zephwm` (WM), `zephwm-msg` (IPC client), `zephwm-bar` (status bar).

## Building

Requires **Zig 0.15.0+** and the following system libraries:

```
xcb xcb-keysyms xcb-randr xcb-xkb xkbcommon xkbcommon-x11 X11 X11-xcb xft fontconfig
```

### Arch Linux

```bash
sudo pacman -S libxcb xcb-util-keysyms libxkbcommon libxft fontconfig libx11
```

### Build

```bash
git clone https://github.com/midasdf/zephwm.git
cd zephwm
zig build
```

Binaries are in `zig-out/bin/`.

### Run tests

```bash
zig build test                    # 99 unit tests
bash test_xephyr.sh              # 73 basic integration tests
bash test_xephyr_extended.sh     # 59 extended tests
bash test_xephyr_multimon.sh     # 35 multi-monitor tests
bash test_xephyr_resolutions.sh  # 180 multi-resolution tests
```

### Cross-compile for aarch64

Requires an aarch64 sysroot with xcb/xkbcommon libraries. For HackberryPi, building natively on the device is recommended:

```bash
# On HackberryPi (aarch64)
zig build -Doptimize=ReleaseSmall
```

## Usage

### Start zephwm

zephwm is an X11 window manager. Start it from your `.xinitrc` or display manager:

```bash
# .xinitrc
exec zephwm
```

Or test with Xephyr:

```bash
Xephyr -br -ac -noreset -screen 720x720 :1 &
DISPLAY=:1 zephwm
```

Multi-monitor testing with virtual monitors:

```bash
Xephyr -br -ac -noreset -screen 3286x1080 :1 &
DISPLAY=:1 xrandr --setmonitor LEFT 1920/507x1080/285+0+0 default
DISPLAY=:1 xrandr --setmonitor RIGHT 1366/361x1080/285+1920+0 none
DISPLAY=:1 zephwm
```

### Config file

zephwm reads an i3-style config from (in order):

1. `$XDG_CONFIG_HOME/zephwm/config`
2. `~/.config/zephwm/config`
3. `~/.zephwm/config`
4. `/etc/zephwm/config`

If no config file is found, built-in defaults are used. Copy the shipped default as a starting point:

```bash
mkdir -p ~/.config/zephwm
cp /path/to/zephwm/config/default_config ~/.config/zephwm/config
```

### Default keybinds

| Key | Action |
|-----|--------|
| `Mod4+Return` | Open terminal (st) |
| `Mod4+Shift+q` | Kill focused window |
| `Mod4+h/j/k/l` | Focus left/down/up/right |
| `Mod4+Shift+h/j/k/l` | Move window left/down/up/right |
| `Mod4+b` | Split horizontal |
| `Mod4+v` | Split vertical |
| `Mod4+w` | Layout tabbed |
| `Mod4+s` | Layout stacking |
| `Mod4+e` | Layout toggle split |
| `Mod4+f` | Fullscreen toggle |
| `Mod4+Shift+space` | Floating toggle |
| `Mod4+r` | Resize mode |
| `Mod4+1-9,0` | Switch to workspace 1-10 |
| `Mod4+Shift+1-9,0` | Move to workspace 1-10 |
| `Mod4+minus` | Scratchpad show |
| `Mod4+Shift+minus` | Move to scratchpad |
| `Mod4+Shift+c` | Reload config |
| `Mod4+Shift+r` | Restart (in-place) |
| `Mod4+Shift+e` | Exit |

### IPC

zephwm uses the i3 IPC protocol. The `zephwm-msg` tool sends commands:

```bash
zephwm-msg 'split v'
zephwm-msg 'resize grow width 100 px'
zephwm-msg 'workspace number 3'
zephwm-msg 'focus output right'
zephwm-msg -t get_workspaces
zephwm-msg -t get_tree
zephwm-msg -t get_outputs
zephwm-msg -t get_bar_config
```

`i3-msg` also works if pointed at the socket:

```bash
i3-msg -s $I3SOCK 'focus left'
```

The socket path is set in `$I3SOCK` and on the X root window as `I3_SOCKET_PATH`.

## Dependencies

| Library | Purpose |
|---------|---------|
| libxcb | X11 protocol |
| xcb-keysyms | Key symbol lookup |
| xcb-randr | Multi-monitor support |
| xcb-xkb | Keyboard extension |
| libxkbcommon | Keysym name resolution |
| libxkbcommon-x11 | X11 keyboard integration |
| libX11 + libX11-xcb | Xlib-XCB bridge (for zephwm-bar Xft) |
| libxft | Font rendering (zephwm-bar) |
| fontconfig | Font configuration (zephwm-bar) |

No GLib, pango, cairo, or other heavy dependencies. Linux only (uses epoll and signalfd).

## Design decisions

- **xcb direct** — No Xlib wrapper for the WM core. Lower overhead, explicit control.
- **xcb-free core** — Tree, layout, config, command parsing have zero xcb dependency. All unit-testable without an X server.
- **i3 IPC compatibility** — Same binary protocol, same magic string. Existing i3 tools (i3-msg, polybar, i3blocks) work.
- **i3 config syntax** — Familiar configuration for i3 users.
- **Single-threaded** — One epoll loop multiplexes X events, IPC, and signals. No thread safety concerns.
- **O(1) window lookup** — HashMap-based window ID lookup instead of tree walking.
- **Zig** — Memory safety without GC, comptime optimizations, small binaries.

## License

[MIT](LICENSE)
