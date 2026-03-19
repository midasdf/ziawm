const std = @import("std");
const criteria_mod = @import("criteria.zig");

pub const CommandType = enum {
    split,
    focus,
    move,
    layout_cmd,
    resize,
    workspace,
    move_workspace,
    kill,
    exec,
    floating,
    fullscreen,
    mark,
    unmark,
    scratchpad,
    mode,
    reload,
    restart,
    exit,
    focus_output,
    nop,
};

pub const Command = struct {
    type: CommandType,
    args: [4]?[]const u8 = .{null} ** 4,
    criteria: ?criteria_mod.Criteria = null,
};

/// Skip leading whitespace, return slice starting at first non-whitespace.
fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

/// Parse an optional criteria prefix "[...]" from the start of input.
/// Returns the criteria (or null) and the remainder of the string after the criteria block.
fn parseCriteriaPrefix(input: []const u8) struct { crit: ?criteria_mod.Criteria, rest: []const u8 } {
    const s = trimLeft(input);
    if (s.len == 0 or s[0] != '[') {
        return .{ .crit = null, .rest = s };
    }
    // Find the closing ']'
    const end = std.mem.indexOfScalar(u8, s, ']') orelse {
        return .{ .crit = null, .rest = s };
    };
    const crit_str = s[0 .. end + 1];
    const crit = criteria_mod.parse(crit_str);
    const rest = trimLeft(s[end + 1 ..]);
    return .{ .crit = crit, .rest = rest };
}

/// Parse i3 command string. Supports optional [criteria] prefix.
/// Returns null if the command string is unrecognised.
pub fn parse(input: []const u8) ?Command {
    const prep = parseCriteriaPrefix(trimLeft(input));
    const crit = prep.crit;
    const s = prep.rest;

    // Helper: check if s starts with prefix (followed by whitespace or end)
    // For keywords that require arguments
    const startsWith = std.mem.startsWith;

    // ---- multi-word prefixes first (longest-match) ----

    // "move container to workspace number N"
    if (startsWith(u8, s, "move container to workspace number ")) {
        const rest = trimLeft(s["move container to workspace number ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .move_workspace, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "move container to workspace NAME"
    if (startsWith(u8, s, "move container to workspace ")) {
        const rest = trimLeft(s["move container to workspace ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .move_workspace, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "move scratchpad"
    if (std.mem.eql(u8, s, "move scratchpad")) {
        return Command{ .type = .scratchpad, .args = .{ "move", null, null, null }, .criteria = crit };
    }

    // "focus output left/right/..."
    if (startsWith(u8, s, "focus output ")) {
        const rest = trimLeft(s["focus output ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .focus_output, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "workspace number N"
    if (startsWith(u8, s, "workspace number ")) {
        const rest = trimLeft(s["workspace number ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .workspace, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "layout stacking" / "layout tabbed" / "layout toggle split" / etc.
    if (startsWith(u8, s, "layout ")) {
        const rest = trimLeft(s["layout ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .layout_cmd, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "resize grow/shrink width/height N px" — args[0..3]
    if (startsWith(u8, s, "resize ")) {
        const rest = trimLeft(s["resize ".len..]);
        // tokenise up to 4 words
        var args: [4]?[]const u8 = .{null} ** 4;
        var rem = rest;
        var i: usize = 0;
        while (i < 4 and rem.len > 0) : (i += 1) {
            const sp = std.mem.indexOfAny(u8, rem, " \t");
            if (sp) |pos| {
                args[i] = rem[0..pos];
                rem = trimLeft(rem[pos..]);
            } else {
                args[i] = rem;
                rem = "";
            }
        }
        return Command{ .type = .resize, .args = args, .criteria = crit };
    }

    // "floating enable/disable/toggle"
    if (startsWith(u8, s, "floating ")) {
        const rest = trimLeft(s["floating ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .floating, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "fullscreen toggle" (or just "fullscreen")
    if (startsWith(u8, s, "fullscreen")) {
        return Command{ .type = .fullscreen, .args = .{ null, null, null, null }, .criteria = crit };
    }

    // "split h/v"
    if (startsWith(u8, s, "split ")) {
        const rest = trimLeft(s["split ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .split, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "focus left/right/up/down/parent/child/mode_toggle"
    if (startsWith(u8, s, "focus ")) {
        const rest = trimLeft(s["focus ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .focus, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "move left/right/up/down" (generic move, not "move container to workspace")
    if (startsWith(u8, s, "move ")) {
        const rest = trimLeft(s["move ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .move, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "workspace NAME" (no "number" keyword)
    if (startsWith(u8, s, "workspace ")) {
        const rest = trimLeft(s["workspace ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .workspace, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "kill kill" (force kill) — must come before plain "kill"
    if (std.mem.eql(u8, s, "kill kill")) {
        return Command{ .type = .kill, .args = .{ "kill", null, null, null }, .criteria = crit };
    }

    // "kill" (graceful)
    if (std.mem.eql(u8, s, "kill")) {
        return Command{ .type = .kill, .args = .{ "graceful", null, null, null }, .criteria = crit };
    }

    // "exec [--no-startup-id] CMD"
    if (startsWith(u8, s, "exec ")) {
        var rest = trimLeft(s["exec ".len..]);
        // Strip --no-startup-id at parse time
        if (startsWith(u8, rest, "--no-startup-id ")) {
            rest = trimLeft(rest["--no-startup-id ".len..]);
        }
        if (rest.len == 0) return null;
        return Command{ .type = .exec, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "mark NAME"
    if (startsWith(u8, s, "mark ")) {
        const rest = trimLeft(s["mark ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .mark, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "unmark NAME"
    if (startsWith(u8, s, "unmark ")) {
        const rest = trimLeft(s["unmark ".len..]);
        if (rest.len == 0) return null;
        return Command{ .type = .unmark, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // "scratchpad show"
    if (std.mem.eql(u8, s, "scratchpad show")) {
        return Command{ .type = .scratchpad, .args = .{ "show", null, null, null }, .criteria = crit };
    }

    // "mode "name"" — strip quotes
    if (startsWith(u8, s, "mode ")) {
        var rest = trimLeft(s["mode ".len..]);
        if (rest.len == 0) return null;
        // Strip surrounding quotes if present
        if (rest[0] == '"') {
            rest = rest[1..];
            if (rest.len > 0 and rest[rest.len - 1] == '"') {
                rest = rest[0 .. rest.len - 1];
            }
        }
        return Command{ .type = .mode, .args = .{ rest, null, null, null }, .criteria = crit };
    }

    // Single-word commands
    if (std.mem.eql(u8, s, "reload")) {
        return Command{ .type = .reload, .criteria = crit };
    }
    if (std.mem.eql(u8, s, "restart")) {
        return Command{ .type = .restart, .criteria = crit };
    }
    if (std.mem.eql(u8, s, "exit")) {
        return Command{ .type = .exit, .criteria = crit };
    }
    if (std.mem.eql(u8, s, "nop")) {
        return Command{ .type = .nop, .criteria = crit };
    }

    return null;
}
