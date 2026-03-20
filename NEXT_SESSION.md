# zephwm — Next Session Prompt

## What is zephwm?
i3-compatible tiling WM written in Zig. ~7,500 LOC (src + bar), 3 binaries (zephwm, zephwm-msg, zephwm-bar). Target: HackberryPi Zero (RPi Zero 2W, 512MB RAM). All tests pass (~576 tests), zero memory leaks.

## What's done (v0.3.0)
- Core tiling: hsplit/vsplit/tabbed/stacked, focus/move/resize, marks, scratchpad
- Frame windows: full X11 reparenting for stable title bars, Expose-based redraw
- Font detection: 4-font fallback with metrics-based text positioning and truncation
- Multi-monitor: XRandR 1.5, focus_output, hot-plug, workspace-output config
- Per-output bar: one bar window per monitor, output-scoped strut
- IPC: all 11 message types, event subscription (workspace/window/mode/binding/output)
- i3bar click protocol: bidirectional stdin/stdout with per-block tracking
- Config: keybinds, variables, modes, colors, gaps, for_window, assign, exec/exec_always
- Commands: border none/pixel/normal/toggle, sticky enable/disable/toggle, move workspace to output
- Urgent workspace: WM_HINTS urgency propagation to workspace level, clear on focus
- Performance: O(1) window HashMap, batched xcb flush, single-pass render
- Mouse: floating drag move/resize, tiling drag resize
- Restart: in-place re-exec with ICCCM-compliant unreparent + save-set
- Testing: 576+ tests (unit + IPC integration + multi-resolution + visual pixel verification)

## What needs work

### Testing (High)
1. **HackberryPi real hardware test** — build and run on actual RPi Zero 2W (720x720 HyperPixel4)

### Polish (Low — deferred, YAGNI)
2. **bindcode** — keycode-based bindings (keysym-only currently, works fine)
3. **event.zig is 2400+ lines** — could split, but works and tests pass
4. **IPC subscribe JSON parsing** — string search works, no bugs reported

## Key Architecture Notes
- Single-threaded epoll loop (main.zig)
- Container tree: root → output → workspace → split_con → window
- Frame windows: every managed window reparented into WM-owned frame (border + title bar)
- Pure Zig modules (tree, layout, config, command, criteria, ipc, workspace, scratchpad) have zero XCB dependency — fully unit-testable
- Window lookup: HashMap(u32, *Container) for O(1), both client_id and frame_id
- UnmapNotify: pending_unmap counter + mapped state + ev.event==ev.window filter + frame_id guard
- Render: single-pass with deferred floating/fullscreen, title bars drawn after frame configure
- Save-set: clients added to X server save-set for crash recovery (ICCCM)

## Test Suites
```
zig build test                    # ~110 unit tests
bash test_xephyr.sh               # 73 basic integration
bash test_xephyr_newfeatures.sh   # 43 new feature tests
bash test_xephyr_resolutions.sh   # 180 multi-resolution (10 resolutions)
bash test_xephyr_visual.sh        # 170 pixel verification (10 resolutions)
bash test_xephyr_extended.sh      # 59 advanced tests
bash test_xephyr_multimon.sh      # 35 multi-monitor tests
```

## Git
- Repo: git@github.com:midasdf/zephwm.git
- Branch: master
