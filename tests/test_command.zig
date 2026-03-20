const std = @import("std");
const command = @import("command");

// ---- split ----

test "parse split h" {
    const cmd = command.parse("split h") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.split, cmd.type);
    try std.testing.expectEqualStrings("h", cmd.args[0].?);
}

test "parse split v" {
    const cmd = command.parse("split v") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.split, cmd.type);
    try std.testing.expectEqualStrings("v", cmd.args[0].?);
}

// ---- focus ----

test "parse focus left" {
    const cmd = command.parse("focus left") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.focus, cmd.type);
    try std.testing.expectEqualStrings("left", cmd.args[0].?);
}

test "parse focus right/up/down" {
    inline for (.{ "right", "up", "down" }) |dir| {
        const cmd = command.parse("focus " ++ dir) orelse return error.ParseFailed;
        try std.testing.expectEqual(command.CommandType.focus, cmd.type);
        try std.testing.expectEqualStrings(dir, cmd.args[0].?);
    }
}

test "parse focus parent/child/mode_toggle" {
    inline for (.{ "parent", "child", "mode_toggle" }) |arg| {
        const cmd = command.parse("focus " ++ arg) orelse return error.ParseFailed;
        try std.testing.expectEqual(command.CommandType.focus, cmd.type);
        try std.testing.expectEqualStrings(arg, cmd.args[0].?);
    }
}

// ---- focus output ----

test "parse focus output left" {
    const cmd = command.parse("focus output left") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.focus_output, cmd.type);
    try std.testing.expectEqualStrings("left", cmd.args[0].?);
}

test "parse focus output right" {
    const cmd = command.parse("focus output right") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.focus_output, cmd.type);
    try std.testing.expectEqualStrings("right", cmd.args[0].?);
}

// ---- move workspace to output ----

test "parse move workspace to output right" {
    const cmd = command.parse("move workspace to output right") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.move_workspace_to_output, cmd.type);
    try std.testing.expectEqualStrings("right", cmd.args[0].?);
}

test "parse move workspace to output named" {
    const cmd = command.parse("move workspace to output HDMI-1") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.move_workspace_to_output, cmd.type);
    try std.testing.expectEqualStrings("HDMI-1", cmd.args[0].?);
}

// ---- move container to workspace ----

test "parse move container to workspace number 3" {
    const cmd = command.parse("move container to workspace number 3") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.move_workspace, cmd.type);
    try std.testing.expectEqualStrings("3", cmd.args[0].?);
}

test "parse move container to workspace named" {
    const cmd = command.parse("move container to workspace work") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.move_workspace, cmd.type);
    try std.testing.expectEqualStrings("work", cmd.args[0].?);
}

// ---- layout ----

test "parse layout tabbed" {
    const cmd = command.parse("layout tabbed") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.layout_cmd, cmd.type);
    try std.testing.expectEqualStrings("tabbed", cmd.args[0].?);
}

test "parse layout stacking" {
    const cmd = command.parse("layout stacking") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.layout_cmd, cmd.type);
    try std.testing.expectEqualStrings("stacking", cmd.args[0].?);
}

test "parse layout toggle split" {
    const cmd = command.parse("layout toggle split") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.layout_cmd, cmd.type);
    try std.testing.expectEqualStrings("toggle split", cmd.args[0].?);
}

// ---- resize ----

test "parse resize grow width 10 px" {
    const cmd = command.parse("resize grow width 10 px") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.resize, cmd.type);
    try std.testing.expectEqualStrings("grow", cmd.args[0].?);
    try std.testing.expectEqualStrings("width", cmd.args[1].?);
    try std.testing.expectEqualStrings("10", cmd.args[2].?);
    try std.testing.expectEqualStrings("px", cmd.args[3].?);
}

test "parse resize shrink height 20 px" {
    const cmd = command.parse("resize shrink height 20 px") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.resize, cmd.type);
    try std.testing.expectEqualStrings("shrink", cmd.args[0].?);
    try std.testing.expectEqualStrings("height", cmd.args[1].?);
    try std.testing.expectEqualStrings("20", cmd.args[2].?);
}

// ---- kill ----

test "parse kill graceful" {
    const cmd = command.parse("kill") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.kill, cmd.type);
    try std.testing.expectEqualStrings("graceful", cmd.args[0].?);
}

test "parse kill force" {
    const cmd = command.parse("kill kill") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.kill, cmd.type);
    try std.testing.expectEqualStrings("kill", cmd.args[0].?);
}

// ---- exec ----

test "parse exec" {
    const cmd = command.parse("exec rofi -show run") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.exec, cmd.type);
    try std.testing.expectEqualStrings("rofi -show run", cmd.args[0].?);
}

// ---- floating ----

test "parse floating toggle" {
    const cmd = command.parse("floating toggle") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.floating, cmd.type);
    try std.testing.expectEqualStrings("toggle", cmd.args[0].?);
}

test "parse floating enable/disable" {
    inline for (.{ "enable", "disable" }) |arg| {
        const cmd = command.parse("floating " ++ arg) orelse return error.ParseFailed;
        try std.testing.expectEqual(command.CommandType.floating, cmd.type);
        try std.testing.expectEqualStrings(arg, cmd.args[0].?);
    }
}

// ---- scratchpad ----

test "parse scratchpad show" {
    const cmd = command.parse("scratchpad show") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.scratchpad, cmd.type);
    try std.testing.expectEqualStrings("show", cmd.args[0].?);
}

test "parse move scratchpad" {
    const cmd = command.parse("move scratchpad") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.scratchpad, cmd.type);
    try std.testing.expectEqualStrings("move", cmd.args[0].?);
}

// ---- mark / unmark ----

test "parse mark" {
    const cmd = command.parse("mark mymark") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.mark, cmd.type);
    try std.testing.expectEqualStrings("mymark", cmd.args[0].?);
}

test "parse unmark" {
    const cmd = command.parse("unmark mymark") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.unmark, cmd.type);
    try std.testing.expectEqualStrings("mymark", cmd.args[0].?);
}

// ---- mode ----

test "parse mode strip quotes" {
    const cmd = command.parse("mode \"resize\"") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.mode, cmd.type);
    try std.testing.expectEqualStrings("resize", cmd.args[0].?);
}

test "parse mode no quotes" {
    const cmd = command.parse("mode default") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.mode, cmd.type);
    try std.testing.expectEqualStrings("default", cmd.args[0].?);
}

// ---- criteria prefix ----

test "parse with criteria prefix [class=\"Firefox\"] focus" {
    const cmd = command.parse("[class=\"Firefox\"] focus left") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.focus, cmd.type);
    try std.testing.expectEqualStrings("left", cmd.args[0].?);
    try std.testing.expect(cmd.criteria != null);
    try std.testing.expectEqualStrings("Firefox", cmd.criteria.?.class.?);
}

test "parse with criteria prefix [title=\"Git*\"] kill" {
    const cmd = command.parse("[title=\"Git*\"] kill") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.kill, cmd.type);
    try std.testing.expectEqualStrings("graceful", cmd.args[0].?);
    try std.testing.expect(cmd.criteria != null);
    try std.testing.expectEqualStrings("Git*", cmd.criteria.?.title.?);
}

// ---- reload / restart / exit ----

test "parse reload" {
    const cmd = command.parse("reload") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.reload, cmd.type);
}

test "parse restart" {
    const cmd = command.parse("restart") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.restart, cmd.type);
}

test "parse exit" {
    const cmd = command.parse("exit") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.exit, cmd.type);
}

test "parse nop" {
    const cmd = command.parse("nop") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.nop, cmd.type);
}

// ---- workspace ----

test "parse workspace number N" {
    const cmd = command.parse("workspace number 2") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.workspace, cmd.type);
    try std.testing.expectEqualStrings("2", cmd.args[0].?);
}

test "parse workspace NAME" {
    const cmd = command.parse("workspace dev") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.workspace, cmd.type);
    try std.testing.expectEqualStrings("dev", cmd.args[0].?);
}

// ---- sticky ----

test "parse sticky enable" {
    const cmd = command.parse("sticky enable") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.sticky, cmd.type);
    try std.testing.expectEqualStrings("enable", cmd.args[0].?);
}

test "parse sticky disable" {
    const cmd = command.parse("sticky disable") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.sticky, cmd.type);
    try std.testing.expectEqualStrings("disable", cmd.args[0].?);
}

test "parse sticky toggle" {
    const cmd = command.parse("sticky toggle") orelse return error.ParseFailed;
    try std.testing.expectEqual(command.CommandType.sticky, cmd.type);
    try std.testing.expectEqualStrings("toggle", cmd.args[0].?);
}

// ---- border ----

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

// ---- invalid ----

test "parse invalid returns null" {
    try std.testing.expect(command.parse("") == null);
    try std.testing.expect(command.parse("   ") == null);
    try std.testing.expect(command.parse("boguscommand foo") == null);
    try std.testing.expect(command.parse("split") == null); // missing arg
    try std.testing.expect(command.parse("focus") == null); // missing arg
}
