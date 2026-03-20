# i3 Features Batch 2 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add move workspace to output, per-window border control, IPC output event, and urgent workspace.

**Architecture:** Four independent features. IPC output event is a single line. Urgent workspace adds propagation logic. Move workspace to output reuses existing output lookup. Border adds per-window style to render path.

**Tech Stack:** Zig, XCB

**Spec:** `docs/superpowers/specs/2026-03-20-i3-features-batch2-design.md`

---

## Chunk 1: IPC Output Event + Urgent Workspace + Move Workspace to Output

### Task 1: IPC output event broadcast

**Files:**
- Modify: `src/event.zig` (`handleRandrScreenChange`)

- [ ] **Step 1: Add broadcast after updateOutputs**

In `handleRandrScreenChange`, after `output.updateOutputs()` succeeds and before `relayoutAndRender(ctx)`, add:

```zig
    broadcastIpcEvent(ctx, .output, "{\"change\":\"unspecified\"}");
```

- [ ] **Step 2: Build and test**

Run: `zig build && zig build test`

- [ ] **Step 3: Commit**

```bash
git add src/event.zig
git commit -m "feat: broadcast IPC output event on RandR screen change"
```

### Task 2: Urgent workspace — data model + propagation

**Files:**
- Modify: `src/tree.zig:35-39` (WorkspaceData)
- Modify: `src/event.zig` (handlePropertyNotify + executeWorkspace)
- Modify: `src/main.zig` (buildWorkspacesJson)

- [ ] **Step 1: Add urgent field to WorkspaceData**

In `src/tree.zig` WorkspaceData struct, add after `output_name`:

```zig
    urgent: bool = false,
```

- [ ] **Step 2: Add urgency propagation in handlePropertyNotify**

In `src/event.zig`, in `handlePropertyNotify`'s WM_HINTS branch, after setting `wd.urgency` (line ~1264), add:

```zig
                // Propagate urgency to workspace
                if (wd.urgency) {
                    var ws_con = con.parent;
                    while (ws_con) |p| : (ws_con = p.parent) {
                        if (p.type == .workspace) {
                            if (p.workspace) |*wsd| {
                                // Only set urgent if workspace is not focused
                                if (!p.is_focused) {
                                    wsd.urgent = true;
                                    broadcastIpcEvent(ctx, .workspace, "{\"change\":\"urgent\"}");
                                }
                            }
                            break;
                        }
                    }
                }
```

- [ ] **Step 3: Clear urgency on workspace focus**

In `src/event.zig` `executeWorkspace`, after `setFocus(ctx, target_ws)` (line ~1693), add:

```zig
        // Clear urgency on focused workspace
        if (target_ws.workspace) |*wsd| {
            if (wsd.urgent) {
                wsd.urgent = false;
                // Clear urgency on all windows in this workspace
                var child_cur = target_ws.children.first;
                while (child_cur) |child| : (child_cur = child.next) {
                    if (child.window) |*wd| {
                        wd.urgency = false;
                    }
                }
            }
        }
```

Also do the same in the back_and_forth path, after `setFocus(ctx, prev_ws)`.

- [ ] **Step 4: Update buildWorkspacesJson to read wsd.urgent**

In `src/main.zig` `buildWorkspacesJson`, find where `"urgent":` is emitted. Change it to read from `wsd.urgent` if available:

Find the existing urgent output and ensure it uses `wsd.urgent` instead of iterating children.

- [ ] **Step 5: Build and test**

Run: `zig build && zig build test`

- [ ] **Step 6: Commit**

```bash
git add src/tree.zig src/event.zig src/main.zig
git commit -m "feat: urgent workspace — propagate window urgency, clear on focus"
```

### Task 3: Move workspace to output

**Files:**
- Modify: `src/command.zig` (CommandType + parse)
- Modify: `src/event.zig` (executeCommand + handler)

- [ ] **Step 1: Add command type and parsing**

In `src/command.zig`:

Add `move_workspace_to_output` to CommandType enum.

In the `parse` function, before the existing `"move container to workspace number "` block (it must come before `"move "` catch-all), add:

```zig
    // "move workspace to output NAME/left/right/up/down"
    if (startsWith(u8, s, "move workspace to output ")) {
        const rest = trimLeft(s["move workspace to output ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .move_workspace_to_output, .args = .{ rest, null, null, null }, .criteria = crit };
    }
```

- [ ] **Step 2: Add command test**

In `tests/test_command.zig`:

```zig
test "parse move workspace to output right" {
    const cmd = command.parse("move workspace to output right") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.move_workspace_to_output, cmd.type);
    try std.testing.expectEqualStrings("right", cmd.args[0].?);
}
```

- [ ] **Step 3: Implement executeMoveWorkspaceToOutput**

In `src/event.zig`, add to `executeCommand` switch:

```zig
        .move_workspace_to_output => executeMoveWorkspaceToOutput(ctx, cmd),
```

Add the handler:

```zig
fn executeMoveWorkspaceToOutput(ctx: *EventContext, cmd: command_mod.Command) void {
    const direction = cmd.args[0] orelse return;
    const current_ws = getFocusedWorkspace(ctx.tree_root) orelse return;
    const current_out = current_ws.parent orelse return;
    if (current_out.type != .output) return;

    // Find target output
    const target_out = blk: {
        if (std.mem.eql(u8, direction, "left")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .left);
        } else if (std.mem.eql(u8, direction, "right")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .right);
        } else if (std.mem.eql(u8, direction, "up")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .up);
        } else if (std.mem.eql(u8, direction, "down")) {
            break :blk output.findAdjacent(ctx.tree_root, current_out, .down);
        } else {
            // Named output
            break :blk output.findByName(ctx.tree_root, direction);
        }
    } orelse return;

    if (target_out == current_out) return;

    // Move workspace to target output
    current_ws.unlink();
    target_out.appendChild(current_ws);
    current_ws.rect = target_out.rect;

    // Update workspace output_name
    if (current_ws.workspace) |*wsd| {
        if (target_out.workspace) |tout_wsd| {
            wsd.output_name = tout_wsd.output_name;
        }
    }

    // Ensure source output still has a workspace
    if (current_out.children.first == null) {
        // Create a default workspace for the now-empty output
        if (workspace.create(ctx.allocator, "1", 1)) |new_ws| {
            current_out.appendChild(new_ws);
            new_ws.rect = current_out.rect;
        } else |_| {}
    }

    relayoutAndRender(ctx);
    broadcastIpcEvent(ctx, .workspace, "{\"change\":\"move\"}");
}
```

Note: check what `output.findAdjacent` signature is. Read `src/output.zig` to verify parameter order and direction enum names.

- [ ] **Step 4: Build and test**

Run: `zig build && zig build test`

- [ ] **Step 5: Commit**

```bash
git add src/command.zig src/event.zig tests/test_command.zig
git commit -m "feat: move workspace to output command"
```

---

## Chunk 2: Border Command

### Task 4: Border data model + command

**Files:**
- Modify: `src/tree.zig` (Container struct)
- Modify: `src/command.zig` (CommandType + parse)
- Modify: `src/event.zig` (executeCommand + handler)
- Modify: `src/render.zig` (applyWindow border width)

- [ ] **Step 1: Add BorderStyle and fields to Container**

In `src/tree.zig`, before Container struct, add:

```zig
pub const BorderStyle = enum { pixel, none, normal };
```

In Container struct, after `is_sticky`:

```zig
    border_style: BorderStyle = .pixel,
    border_width_override: i16 = -1, // -1 = use config default
```

- [ ] **Step 2: Add border command parsing**

In `src/command.zig`, add `border` to CommandType.

In parse function, add before `"fullscreen"`:

```zig
    // "border none/pixel/pixel N/normal/toggle"
    if (startsWith(u8, s, "border ")) {
        const rest = trimLeft(s["border ".len..]);
        if (rest.len == 0) return null;
        // Check for "pixel N" pattern
        if (startsWith(u8, rest, "pixel ")) {
            const num_str = trimLeft(rest["pixel ".len..]);
            return Command{ .type = .border, .args = .{ "pixel", num_str, null, null }, .criteria = crit };
        }
        return Command{ .type = .border, .args = .{ rest, null, null, null }, .criteria = crit };
    }
```

- [ ] **Step 3: Add command tests**

In `tests/test_command.zig`:

```zig
test "parse border none" {
    const cmd = command.parse("border none") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.border, cmd.type);
    try std.testing.expectEqualStrings("none", cmd.args[0].?);
}

test "parse border pixel 3" {
    const cmd = command.parse("border pixel 3") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.border, cmd.type);
    try std.testing.expectEqualStrings("pixel", cmd.args[0].?);
    try std.testing.expectEqualStrings("3", cmd.args[1].?);
}

test "parse border toggle" {
    const cmd = command.parse("border toggle") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.border, cmd.type);
    try std.testing.expectEqualStrings("toggle", cmd.args[0].?);
}
```

- [ ] **Step 4: Implement executeBorder**

In `src/event.zig`, add to `executeCommand` switch:

```zig
        .border => executeBorder(ctx, cmd),
```

Add handler:

```zig
fn executeBorder(ctx: *EventContext, cmd: command_mod.Command) void {
    const arg = cmd.args[0] orelse return;
    const focused = getFocusedContainer(ctx.tree_root) orelse return;
    if (focused.type != .window) return;

    if (std.mem.eql(u8, arg, "none")) {
        focused.border_style = .none;
    } else if (std.mem.eql(u8, arg, "pixel")) {
        focused.border_style = .pixel;
        if (cmd.args[1]) |width_str| {
            if (std.fmt.parseInt(i16, width_str, 10)) |w| {
                focused.border_width_override = w;
            } else |_| {}
        }
    } else if (std.mem.eql(u8, arg, "normal")) {
        focused.border_style = .normal;
    } else if (std.mem.eql(u8, arg, "toggle")) {
        focused.border_style = switch (focused.border_style) {
            .none => .pixel,
            .pixel => .normal,
            .normal => .none,
        };
    }

    relayoutAndRender(ctx);
}
```

- [ ] **Step 5: Apply per-window border in render.zig**

In `src/render.zig` `applyWindow`, in the frame_id != 0 branch, after configuring frame position/size, add border width to the configure call:

```zig
    // Compute effective border width
    const effective_border: u16 = blk: {
        if (con.border_style == .none) break :blk 0;
        if (con.border_width_override >= 0) break :blk @intCast(con.border_width_override);
        // Default from config — not directly available here, use frame's current border
        break :blk 2; // fallback default
    };

    // Add border width to frame configure
    const values = [_]u32{
        @bitCast(r.x),
        @bitCast(frame_y),
        r.w,
        frame_h,
        @as(u32, effective_border),
    };
    const mask: u16 = xcb.CONFIG_WINDOW_X | xcb.CONFIG_WINDOW_Y |
        xcb.CONFIG_WINDOW_WIDTH | xcb.CONFIG_WINDOW_HEIGHT |
        xcb.CONFIG_WINDOW_BORDER_WIDTH;
```

Note: the exact integration depends on the current code structure. Read `applyWindow` to find the right insertion point. The key change is adding `CONFIG_WINDOW_BORDER_WIDTH` to the mask and the effective width to the values array.

- [ ] **Step 6: Build and test**

Run: `zig build && zig build test`

- [ ] **Step 7: Commit**

```bash
git add src/tree.zig src/command.zig src/event.zig src/render.zig tests/test_command.zig
git commit -m "feat: border none/pixel/normal/toggle command with per-window style"
```

### Task 5: Final build verification

- [ ] **Step 1: Full build and test**

Run: `zig build && zig build test`

- [ ] **Step 2: Commit fixups if needed**

```bash
git add -A && git commit -m "chore: fixups for i3 features batch 2"
```
