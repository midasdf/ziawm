# zephwm — Next Session Prompt

## What is zephwm?
i3-compatible tiling WM written in Zig. ~7,500 LOC (src + bar), 3 binaries (zephwm, zephwm-msg, zephwm-bar). Target: HackberryPi Zero (RPi Zero 2W, 512MB RAM). All tests pass (~700+ tests across 7 suites), zero memory leaks.

## What's done (v0.3.1)
- **Frame windows**: full X11 reparenting with save-set for crash recovery, ICCCM-compliant unreparent on shutdown/restart
- **Font detection**: 4-font fallback (fixed → misc-fixed-semicondensed → misc-fixed-normal → cursor) with xcb_query_font metrics
- **Per-output bar**: one bar window per monitor, output-scoped _NET_WM_STRUT_PARTIAL, per-bar workspace filtering
- **i3bar click protocol**: bidirectional stdin/stdout, per-block tracking (StatusBlock), protocol header detection (click_events:true)
- **Synthetic ConfigureNotify**: sent to all clients after relayout (ICCCM requirement for reparenting WMs)
- **Border layout fix**: frame content shrunk by 2*border so borders fit within layout rect (visible on all 4 sides)
- **`border normal`**: i3-compatible title bar on individual windows — per-window title bar with ellipsis text truncation, deferred flush-then-draw, layout space reservation, Expose/PropertyNotify redraw
- **`border normal <width>`**: width argument parsing for both `border normal N` and `border pixel N`
- **Ellipsis**: long window titles truncated with "..." in tabbed, stacked, and border normal title bars
- **Frame background fix**: XCB_CW_BACK_PIXMAP=None prevents X server white repaint on resize
- Core tiling: hsplit/vsplit/tabbed/stacked, focus/move/resize, marks, scratchpad
- Multi-monitor: XRandR 1.5, focus_output, hot-plug, workspace-output config, move workspace to output
- IPC: all 11 message types, event subscription (workspace/window/mode/binding/output)
- Commands: border none/pixel/normal/toggle, sticky enable/disable/toggle, splith/splitv
- Urgent workspace: WM_HINTS urgency propagation, clear on focus
- Performance: O(1) window HashMap, batched xcb flush, single-pass render with deferred floating/fullscreen
- Config: keybinds, variables, modes, colors, gaps, for_window, assign, exec/exec_always

## Rendering pipeline notes
- drawTitleBars runs AFTER frame configure (with flush), not before — prevents X11 clear-on-resize
- Client window uses separate mask (no CONFIG_WINDOW_BORDER_WIDTH) — was causing random client borders
- Stacked GC_BACKGROUND set for correct text background on unfocused headers
- Last tab extends to frame edge (integer division remainder fix)
- Zero-size windows clamped to 1px minimum
- config_border_px passed through applyTree for correct per-window default

## Test suites
```
zig build test                    # ~110 unit tests
bash test_xephyr.sh               # 73 basic integration
bash test_xephyr_newfeatures.sh   # 43 new feature tests
bash test_xephyr_extended.sh      # 59 advanced tests
bash test_xephyr_multimon.sh      # 35 multi-monitor tests
bash test_xephyr_resolutions.sh   # 180 multi-resolution (10 resolutions)
bash test_xephyr_visual.sh        # 170 pixel verification (10 resolutions)
bash test_docker_realapps.sh      # 65 Docker tests (xterm + alacritty + kitty, screenshot pixel checks)
```
Docker tests use Xvfb inside container (2GB mem limit), no host impact.

## What needs work

### High priority
1. **HackberryPi real hardware test** — build and run on actual RPi Zero 2W (720x720 HyperPixel4)
   - Cross-compile: `zig build -Doptimize=ReleaseSmall` on device or with aarch64 sysroot
   - Test with actual i3 config, i3blocks, rofi

### Known limitations
- kitty/alacritty pixel content checks skipped in Docker (GPU rendering doesn't work with Xvfb)
- `border toggle` does not reset `border_width_override` when cycling styles (pre-existing)
- `bindcode` not implemented (keysym works for all keys)

## Key architecture
- Single-threaded epoll loop (main.zig)
- Container tree: root → output → workspace → split_con → window
- Frame windows: every managed window reparented into WM-owned frame
- Window lookup: HashMap(u32, *Container) for O(1), both client_id and frame_id
- UnmapNotify: pending_unmap counter + mapped state + ev.event==ev.window guard + frame_id guard
- Render: single-pass, title bars after frame configure + flush, deferred floating/fullscreen
- Save-set: clients added to X server save-set before reparent (crash recovery)
- Synthetic ConfigureNotify: sent to all managed windows after relayoutAndRender

## Git
- Repo: git@github.com:midasdf/zephwm.git
- Branch: master
- Latest: 5dc9780
