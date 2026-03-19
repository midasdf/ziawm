const std = @import("std");
const config = @import("config");

test "parse set variable" {
    const text =
        \\set $mod Mod4
        \\set $term st
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("Mod4", cfg.getVariable("$mod").?);
    try std.testing.expectEqualStrings("st", cfg.getVariable("$term").?);
    try std.testing.expect(cfg.getVariable("$nonexistent") == null);
}

test "parse bindsym key and command extracted" {
    const text =
        \\bindsym Mod4+Return exec st
        \\bindsym Mod4+Shift+q kill
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.keybinds.items.len);

    const kb0 = cfg.keybinds.items[0];
    try std.testing.expectEqual(config.MOD_SUPER, kb0.modifiers);
    try std.testing.expectEqualStrings("Return", kb0.key);
    try std.testing.expectEqualStrings("exec st", kb0.command);
    try std.testing.expectEqualStrings("default", kb0.mode);

    const kb1 = cfg.keybinds.items[1];
    try std.testing.expectEqual(config.MOD_SUPER | config.MOD_SHIFT, kb1.modifiers);
    try std.testing.expectEqualStrings("q", kb1.key);
    try std.testing.expectEqualStrings("kill", kb1.command);
}

test "parse bindsym with variable expansion" {
    const text =
        \\set $mod Mod4
        \\bindsym $mod+Return exec st
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.keybinds.items.len);
    const kb = cfg.keybinds.items[0];
    try std.testing.expectEqual(config.MOD_SUPER, kb.modifiers);
    try std.testing.expectEqualStrings("Return", kb.key);
}

test "parse appearance settings" {
    const text =
        \\default_border pixel 3
        \\gaps inner 10
        \\gaps outer 5
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 3), cfg.border_px);
    try std.testing.expectEqual(@as(u32, 10), cfg.gap_inner);
    try std.testing.expectEqual(@as(u32, 5), cfg.gap_outer);
}

test "parse focus_follows_mouse" {
    const text_yes =
        \\focus_follows_mouse yes
    ;
    var cfg_yes = try config.Config.parse(std.testing.allocator, text_yes);
    defer cfg_yes.deinit();
    try std.testing.expect(cfg_yes.focus_follows_mouse);

    const text_no =
        \\focus_follows_mouse no
    ;
    var cfg_no = try config.Config.parse(std.testing.allocator, text_no);
    defer cfg_no.deinit();
    try std.testing.expect(!cfg_no.focus_follows_mouse);
}

test "parse for_window rule" {
    const text =
        \\for_window [class="Firefox"] floating enable
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.window_rules.items.len);
    const rule = cfg.window_rules.items[0];
    try std.testing.expectEqualStrings("Firefox", rule.criteria.class.?);
    try std.testing.expectEqualStrings("floating enable", rule.command);
}

test "parse assign rule" {
    const text =
        \\assign [class="Firefox"] workspace 2
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.assign_rules.items.len);
    const rule = cfg.assign_rules.items[0];
    try std.testing.expectEqualStrings("Firefox", rule.criteria.class.?);
    try std.testing.expectEqualStrings("2", rule.workspace);
}

test "parse exec and exec_always strip --no-startup-id" {
    const text =
        \\exec --no-startup-id nm-applet
        \\exec_always --no-startup-id feh --bg-scale ~/wallpaper.jpg
        \\exec picom
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.exec_cmds.items.len);
    try std.testing.expectEqualStrings("nm-applet", cfg.exec_cmds.items[0]);
    try std.testing.expectEqualStrings("picom", cfg.exec_cmds.items[1]);

    try std.testing.expectEqual(@as(usize, 1), cfg.exec_always_cmds.items.len);
    try std.testing.expectEqualStrings("feh --bg-scale ~/wallpaper.jpg", cfg.exec_always_cmds.items[0]);
}

test "comments and blank lines ignored" {
    const text =
        \\# This is a comment
        \\
        \\# Another comment
        \\default_border pixel 2
        \\
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 2), cfg.border_px);
    try std.testing.expectEqual(@as(usize, 0), cfg.keybinds.items.len);
}

test "parse mode block with keybinds" {
    const text =
        \\mode "resize" {
        \\    bindsym Left resize shrink width 10 px
        \\    bindsym Right resize grow width 10 px
        \\}
        \\bindsym Mod4+r mode "resize"
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    // 2 keybinds inside resize mode + 1 in default mode
    try std.testing.expectEqual(@as(usize, 3), cfg.keybinds.items.len);

    // First two should have mode="resize"
    try std.testing.expectEqualStrings("resize", cfg.keybinds.items[0].mode);
    try std.testing.expectEqualStrings("Left", cfg.keybinds.items[0].key);

    try std.testing.expectEqualStrings("resize", cfg.keybinds.items[1].mode);
    try std.testing.expectEqualStrings("Right", cfg.keybinds.items[1].key);

    // Last one is in default mode
    try std.testing.expectEqualStrings("default", cfg.keybinds.items[2].mode);
    try std.testing.expect(cfg.modes.contains("resize"));
}

test "parse workspace output assignment" {
    const text =
        \\workspace 1 output HDMI-1
        \\workspace 2 output DP-1
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.workspace_outputs.items.len);
    try std.testing.expectEqualStrings("1", cfg.workspace_outputs.items[0].workspace);
    try std.testing.expectEqualStrings("HDMI-1", cfg.workspace_outputs.items[0].output);
    try std.testing.expectEqualStrings("2", cfg.workspace_outputs.items[1].workspace);
    try std.testing.expectEqualStrings("DP-1", cfg.workspace_outputs.items[1].output);
}

test "parse client colors" {
    const text =
        \\client.focused #4c7899 #285577 #ffffff #2e9ef4 #285577
        \\client.unfocused #333333 #222222 #888888 #292d2e #222222
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("#4c7899", cfg.focused_border);
    try std.testing.expectEqualStrings("#285577", cfg.focused_bg);
    try std.testing.expectEqualStrings("#ffffff", cfg.focused_text);
    try std.testing.expectEqualStrings("#333333", cfg.unfocused_border);
    try std.testing.expectEqualStrings("#222222", cfg.unfocused_bg);
    try std.testing.expectEqualStrings("#888888", cfg.unfocused_text);
}

test "parse bar block" {
    const text =
        \\bar {
        \\    status_command i3status
        \\    position top
        \\    colors {
        \\        background #000000
        \\        statusline #ffffff
        \\    }
        \\}
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("i3status", cfg.bar.status_command);
    try std.testing.expectEqualStrings("top", cfg.bar.position);
    try std.testing.expectEqualStrings("#000000", cfg.bar.bg_color);
    try std.testing.expectEqualStrings("#ffffff", cfg.bar.statusline_color);
}

test "unknown lines silently skipped" {
    const text =
        \\some_unknown_directive foo bar
        \\default_border pixel 1
        \\another_unknown thing
    ;
    var cfg = try config.Config.parse(std.testing.allocator, text);
    defer cfg.deinit();

    // Should not error, border_px set correctly
    try std.testing.expectEqual(@as(u32, 1), cfg.border_px);
}
