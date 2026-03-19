# zephwm

**Zig Extreme Performance Hyper Window Manager** — an i3-compatible tiling window manager written in Zig.

zephwm aims to be a lightweight, fast alternative to i3 for X11 Linux systems. It speaks the i3 IPC protocol, reads i3-style config files, and supports the core i3 workflow: tree-based container management with horizontal/vertical splits, tabbed and stacked layouts, workspaces, and keybind-driven operation.

## Status

**v0.1.0 — Early development.** Core tiling and window management work. Not yet feature-complete with i3.

Working:
- Tree-based container model (split h/v, tabbed, stacked)
- Directional focus and move (left/right/up/down/parent/child)
- Workspaces (numbered, auto-created on demand)
- i3-compatible IPC protocol (partial — 6 of 11 message types)
- i3-style config file parsing (keybinds, variables, modes, colors)
- Window kill (graceful WM_DELETE_WINDOW with xcb_kill_client fallback)
- Fullscreen toggle
- Floating window toggle
- Marks (add/remove/query)
- Scratchpad (move/show)
- Exec (fork + /bin/sh -c)
- Config reload (SIGUSR1)
- Click-to-focus and focus-follows-mouse
- EWMH properties (_NET_SUPPORTED, _NET_ACTIVE_WINDOW, _NET_CURRENT_DESKTOP, etc.)

Not yet implemented:
- Resize command
- Restart (in-place re-exec with state preservation)
- Status bar (zephwm-bar is a stub)
- IPC event subscription (subscribe acknowledged but events not streamed)
- for_window / assign rules (parsed but not applied)
- Multi-monitor (XRandR detection exists but disabled)
- focus_output command

## Architecture

zephwm is designed as a single-threaded, epoll-based event loop. All core logic (tree, layout, config, command parsing, criteria matching, IPC protocol) is xcb-independent and fully unit-tested.

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
│   ├── xcb.zig           XCB C bindings via @cImport
│   ├── atoms.zig         EWMH/ICCCM atom management
│   ├── render.zig        Apply layout geometry to X windows
│   ├── workspace.zig     Workspace find/create helpers
│   ├── scratchpad.zig    Scratchpad operations
│   ├── output.zig        Output/monitor detection
│   └── bar.zig           Bar process management (stub)
├── zephwm-msg/
│   └── main.zig          IPC client CLI (like i3-msg)
├── zephwm-bar/
│   └── main.zig          Status bar (stub)
├── tests/                99 unit tests
├── config/
│   └── default_config    Default i3-compatible config
├── build.zig
└── build.zig.zon
```

3 binaries: `zephwm` (WM), `zephwm-msg` (IPC client), `zephwm-bar` (stub).

## Building

Requires **Zig 0.15.0+** and the following system libraries:

```
xcb xcb-keysyms xcb-randr xcb-xkb xkbcommon xkbcommon-x11 xft fontconfig
```

### Arch Linux

```bash
sudo pacman -S libxcb xcb-util-keysyms libxkbcommon libxft fontconfig
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
zig build test
```

### Cross-compile for aarch64

```bash
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall
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
| `Mod4+1-9,0` | Switch to workspace 1-10 |
| `Mod4+Shift+1-9,0` | Move to workspace 1-10 |
| `Mod4+minus` | Scratchpad show |
| `Mod4+Shift+minus` | Move to scratchpad |
| `Mod4+Shift+c` | Reload config |
| `Mod4+Shift+e` | Exit |

### IPC

zephwm uses the i3 IPC protocol. The `zephwm-msg` tool sends commands:

```bash
zephwm-msg 'split v'
zephwm-msg 'workspace number 3'
zephwm-msg -t get_workspaces
zephwm-msg -t get_tree
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
| xcb-randr | Multi-monitor (future) |
| xcb-xkb | Keyboard extension |
| libxkbcommon | Keysym name resolution |
| libxkbcommon-x11 | X11 keyboard integration |
| libxft | Font rendering (bar, future) |
| fontconfig | Font configuration (bar, future) |

No GLib, pango, cairo, or other heavy dependencies. Linux only (uses epoll and signalfd).

## Design decisions

- **xcb direct** — No Xlib wrapper. Lower overhead, explicit control.
- **xcb-free core** — Tree, layout, config, command parsing have zero xcb dependency. All unit-testable without an X server.
- **i3 IPC compatibility** — Same binary protocol, same magic string. Existing i3 tools work.
- **i3 config syntax** — Familiar configuration for i3 users.
- **Single-threaded** — One epoll loop multiplexes X events, IPC, and signals.
- **Zig** — Memory safety without GC, comptime optimizations, small binaries.

## License

[MIT](LICENSE)
