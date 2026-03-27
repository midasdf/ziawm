const std = @import("std");
const criteria_mod = @import("criteria.zig");

const Allocator = std.mem.Allocator;

fn ArrayListManaged(comptime T: type) type {
    return std.array_list.Managed(T);
}

fn StringHashMapManaged(comptime V: type) type {
    return std.HashMap([]const u8, V, std.hash_map.StringContext, std.hash_map.default_max_load_percentage);
}

// Modifier bitmask constants
pub const MOD_SUPER: u8 = 0b0001; // Mod4
pub const MOD_SHIFT: u8 = 0b0010;
pub const MOD_CTRL: u8 = 0b0100; // Control
pub const MOD_ALT: u8 = 0b1000; // Mod1

pub const Keybind = struct {
    modifiers: u8 = 0,
    key: []const u8,
    command: []const u8,
    mode: []const u8 = "default",
};

pub const BarConfig = struct {
    enabled: bool = false,
    status_command: []const u8 = "",
    position: []const u8 = "bottom",
    font: []const u8 = "monospace:size=11",
    bg_color: []const u8 = "#222222",
    statusline_color: []const u8 = "#dddddd",
    height: u16 = 22,
};

pub const WindowRule = struct {
    criteria: criteria_mod.Criteria,
    command: []const u8,
};

pub const AssignRule = struct {
    criteria: criteria_mod.Criteria,
    workspace: []const u8,
};

pub const WorkspaceOutput = struct {
    workspace: []const u8,
    output: []const u8,
};

pub const HideEdgeBorders = enum { none, vertical, horizontal, both, smart };

pub const Config = struct {
    allocator: Allocator,
    variables: StringHashMapManaged([]const u8),
    keybinds: ArrayListManaged(Keybind),
    border_px: u32 = 2,
    default_border_style: @import("tree.zig").BorderStyle = .normal,
    gap_inner: u32 = 0,
    gap_outer: u32 = 0,
    focus_follows_mouse: bool = true,
    focus_wrapping: bool = true,
    workspace_auto_back_and_forth: bool = false,
    // Colors (owned = heap-allocated, must free on deinit)
    focused_border: []const u8 = "#4c7899",
    focused_bg: []const u8 = "#285577",
    focused_text: []const u8 = "#ffffff",
    unfocused_border: []const u8 = "#333333",
    unfocused_bg: []const u8 = "#222222",
    unfocused_text: []const u8 = "#888888",
    focused_inactive_border: []const u8 = "#333333",
    focused_inactive_bg: []const u8 = "#5f676a",
    focused_inactive_text: []const u8 = "#ffffff",
    hide_edge_borders: HideEdgeBorders = .none,
    // Bitmask tracking which string fields are heap-allocated (must free on deinit)
    const OwnedFlag = enum(u16) {
        focused_border = 1 << 0,
        focused_bg = 1 << 1,
        focused_text = 1 << 2,
        unfocused_border = 1 << 3,
        unfocused_bg = 1 << 4,
        unfocused_text = 1 << 5,
        focused_inactive_border = 1 << 6,
        focused_inactive_bg = 1 << 7,
        focused_inactive_text = 1 << 8,
        bar_status_command = 1 << 9,
        bar_position = 1 << 10,
        bar_font = 1 << 11,
        bar_bg_color = 1 << 12,
        bar_statusline_color = 1 << 13,
    };
    owned: u16 = 0,

    fn isOwned(self: *const Config, flag: OwnedFlag) bool {
        return (self.owned & @intFromEnum(flag)) != 0;
    }

    fn setOwned(self: *Config, flag: OwnedFlag) void {
        self.owned |= @intFromEnum(flag);
    }

    fn freeIfOwned(self: *Config, flag: OwnedFlag, ptr: []const u8) void {
        if (self.isOwned(flag)) self.allocator.free(ptr);
    }

    // Bar
    bar: BarConfig = .{},
    // Rules
    window_rules: ArrayListManaged(WindowRule),
    assign_rules: ArrayListManaged(AssignRule),
    // Exec commands
    exec_cmds: ArrayListManaged([]const u8),
    exec_always_cmds: ArrayListManaged([]const u8),
    // Workspace -> output
    workspace_outputs: ArrayListManaged(WorkspaceOutput),
    // Mode names (known modes besides "default")
    modes: StringHashMapManaged(void),
    pub fn parse(allocator: Allocator, text: []const u8) !Config {
        var cfg = Config{
            .allocator = allocator,
            .variables = StringHashMapManaged([]const u8).init(allocator),
            .keybinds = ArrayListManaged(Keybind).init(allocator),
            .window_rules = ArrayListManaged(WindowRule).init(allocator),
            .assign_rules = ArrayListManaged(AssignRule).init(allocator),
            .exec_cmds = ArrayListManaged([]const u8).init(allocator),
            .exec_always_cmds = ArrayListManaged([]const u8).init(allocator),
            .workspace_outputs = ArrayListManaged(WorkspaceOutput).init(allocator),
            .modes = StringHashMapManaged(void).init(allocator),
        };
        errdefer cfg.deinit();

        var current_mode: []const u8 = "default";
        var in_bar: bool = false;
        var in_bar_colors: bool = false;

        var line_iter = std.mem.splitScalar(u8, text, '\n');
        while (line_iter.next()) |raw_line| {
            // Trim trailing \r
            const line_cr = std.mem.trimRight(u8, raw_line, "\r");
            // Trim leading/trailing whitespace
            const line_trimmed = std.mem.trim(u8, line_cr, " \t");

            // Skip blank lines and comments
            if (line_trimmed.len == 0) continue;
            if (line_trimmed[0] == '#') continue;

            // Expand variables in this line
            var expanded_buf: [1024]u8 = undefined;
            const line = expandVariables(&cfg, line_trimmed, &expanded_buf) catch continue; // skip lines that exceed 1024 chars after expansion

            // Handle closing brace (end of mode or bar block)
            if (std.mem.eql(u8, line, "}")) {
                if (in_bar_colors) {
                    in_bar_colors = false;
                } else if (in_bar) {
                    in_bar = false;
                } else {
                    current_mode = "default";
                }
                continue;
            }

            // Inside bar colors block
            if (in_bar_colors) {
                if (std.mem.startsWith(u8, line, "background ")) {
                    cfg.freeIfOwned(.bar_bg_color, cfg.bar.bg_color);
                    cfg.bar.bg_color = try allocator.dupe(u8, std.mem.trim(u8, line["background ".len..], " \t"));
                    cfg.setOwned(.bar_bg_color);
                } else if (std.mem.startsWith(u8, line, "statusline ")) {
                    cfg.freeIfOwned(.bar_statusline_color, cfg.bar.statusline_color);
                    cfg.bar.statusline_color = try allocator.dupe(u8, std.mem.trim(u8, line["statusline ".len..], " \t"));
                    cfg.setOwned(.bar_statusline_color);
                }
                continue;
            }

            // Inside bar block
            if (in_bar) {
                if (std.mem.startsWith(u8, line, "status_command ")) {
                    cfg.freeIfOwned(.bar_status_command, cfg.bar.status_command);
                    cfg.bar.status_command = try allocator.dupe(u8, std.mem.trim(u8, line["status_command ".len..], " \t"));
                    cfg.setOwned(.bar_status_command);
                } else if (std.mem.startsWith(u8, line, "position ")) {
                    cfg.freeIfOwned(.bar_position, cfg.bar.position);
                    cfg.bar.position = try allocator.dupe(u8, std.mem.trim(u8, line["position ".len..], " \t"));
                    cfg.setOwned(.bar_position);
                } else if (std.mem.startsWith(u8, line, "height ")) {
                    const raw = std.mem.trim(u8, line["height ".len..], " \t");
                    cfg.bar.height = std.fmt.parseInt(u16, raw, 10) catch cfg.bar.height;
                } else if (std.mem.startsWith(u8, line, "font ")) {
                    cfg.freeIfOwned(.bar_font, cfg.bar.font);
                    cfg.bar.font = try allocator.dupe(u8, std.mem.trim(u8, line["font ".len..], " \t"));
                    cfg.setOwned(.bar_font);
                } else if (std.mem.startsWith(u8, line, "colors {") or std.mem.eql(u8, line, "colors {")) {
                    in_bar_colors = true;
                }
                continue;
            }

            // set $var value
            if (std.mem.startsWith(u8, line, "set ")) {
                const rest = std.mem.trim(u8, line[4..], " \t");
                if (rest.len > 0 and rest[0] == '$') {
                    var i: usize = 1;
                    while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') : (i += 1) {}
                    const var_name = rest[0..i]; // includes '$'
                    const var_value = std.mem.trim(u8, rest[i..], " \t");
                    const name_owned = try allocator.dupe(u8, var_name);
                    const value_owned = try allocator.dupe(u8, var_value);
                    try cfg.variables.put(name_owned, value_owned);
                }
                continue;
            }

            // bindsym [--release] modifiers+key command
            if (std.mem.startsWith(u8, line, "bindsym ")) {
                const rest = std.mem.trim(u8, line[8..], " \t");
                var sym_rest = rest;
                if (std.mem.startsWith(u8, sym_rest, "--release ")) {
                    sym_rest = std.mem.trim(u8, sym_rest["--release ".len..], " \t");
                }
                const sp = std.mem.indexOfScalar(u8, sym_rest, ' ') orelse continue;
                const bind_spec = sym_rest[0..sp];
                const cmd = std.mem.trim(u8, sym_rest[sp + 1 ..], " \t");

                var mods: u8 = 0;
                var spec_rest = bind_spec;
                while (true) {
                    if (std.mem.startsWith(u8, spec_rest, "Mod4+")) {
                        mods |= MOD_SUPER;
                        spec_rest = spec_rest[5..];
                    } else if (std.mem.startsWith(u8, spec_rest, "Shift+")) {
                        mods |= MOD_SHIFT;
                        spec_rest = spec_rest[6..];
                    } else if (std.mem.startsWith(u8, spec_rest, "Control+")) {
                        mods |= MOD_CTRL;
                        spec_rest = spec_rest[8..];
                    } else if (std.mem.startsWith(u8, spec_rest, "Ctrl+")) {
                        mods |= MOD_CTRL;
                        spec_rest = spec_rest[5..];
                    } else if (std.mem.startsWith(u8, spec_rest, "Mod1+")) {
                        mods |= MOD_ALT;
                        spec_rest = spec_rest[5..];
                    } else if (std.mem.startsWith(u8, spec_rest, "Alt+")) {
                        mods |= MOD_ALT;
                        spec_rest = spec_rest[4..];
                    } else {
                        break;
                    }
                }

                try cfg.keybinds.append(.{
                    .modifiers = mods,
                    .key = try allocator.dupe(u8, spec_rest),
                    .command = try allocator.dupe(u8, cmd),
                    .mode = try allocator.dupe(u8, current_mode),
                });
                continue;
            }

            // default_border pixel N / normal N / none
            if (std.mem.startsWith(u8, line, "default_border ")) {
                const rest = std.mem.trim(u8, line["default_border ".len..], " \t");
                if (std.mem.startsWith(u8, rest, "pixel ")) {
                    const num_str = std.mem.trim(u8, rest["pixel ".len..], " \t");
                    cfg.border_px = std.fmt.parseInt(u32, num_str, 10) catch cfg.border_px;
                    cfg.default_border_style = .pixel;
                } else if (std.mem.startsWith(u8, rest, "normal ")) {
                    const num_str = std.mem.trim(u8, rest["normal ".len..], " \t");
                    cfg.border_px = std.fmt.parseInt(u32, num_str, 10) catch cfg.border_px;
                    cfg.default_border_style = .normal;
                } else if (std.mem.eql(u8, rest, "pixel")) {
                    cfg.default_border_style = .pixel;
                } else if (std.mem.eql(u8, rest, "normal")) {
                    cfg.default_border_style = .normal;
                } else if (std.mem.eql(u8, rest, "none")) {
                    cfg.default_border_style = .none;
                    cfg.border_px = 0;
                }
                continue;
            }

            // gaps inner N / gaps outer N
            if (std.mem.startsWith(u8, line, "gaps inner ")) {
                const num_str = std.mem.trim(u8, line["gaps inner ".len..], " \t");
                cfg.gap_inner = std.fmt.parseInt(u32, num_str, 10) catch cfg.gap_inner;
                continue;
            }
            if (std.mem.startsWith(u8, line, "gaps outer ")) {
                const num_str = std.mem.trim(u8, line["gaps outer ".len..], " \t");
                cfg.gap_outer = std.fmt.parseInt(u32, num_str, 10) catch cfg.gap_outer;
                continue;
            }

            // focus_follows_mouse yes/no
            if (std.mem.startsWith(u8, line, "focus_follows_mouse ")) {
                const val = std.mem.trim(u8, line["focus_follows_mouse ".len..], " \t");
                cfg.focus_follows_mouse = std.mem.eql(u8, val, "yes");
                continue;
            }

            // focus_wrapping yes/no
            if (std.mem.startsWith(u8, line, "focus_wrapping ")) {
                const val = std.mem.trim(u8, line["focus_wrapping ".len..], " \t");
                cfg.focus_wrapping = std.mem.eql(u8, val, "yes");
                continue;
            }

            // workspace_auto_back_and_forth yes/no
            if (std.mem.startsWith(u8, line, "workspace_auto_back_and_forth ")) {
                const val = std.mem.trim(u8, line["workspace_auto_back_and_forth ".len..], " \t");
                cfg.workspace_auto_back_and_forth = std.mem.eql(u8, val, "yes");
                continue;
            }

            // for_window [criteria] command
            if (std.mem.startsWith(u8, line, "for_window ")) {
                const rest = std.mem.trim(u8, line["for_window ".len..], " \t");
                if (rest.len > 0 and rest[0] == '[') {
                    const close_bracket = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
                    const crit_str = rest[0 .. close_bracket + 1];
                    const cmd = std.mem.trim(u8, rest[close_bracket + 1 ..], " \t");
                    const crit = criteria_mod.parse(crit_str) orelse continue;
                    try cfg.window_rules.append(.{
                        .criteria = crit,
                        .command = try allocator.dupe(u8, cmd),
                    });
                }
                continue;
            }

            // assign [criteria] workspace N
            if (std.mem.startsWith(u8, line, "assign ")) {
                const rest = std.mem.trim(u8, line["assign ".len..], " \t");
                if (rest.len > 0 and rest[0] == '[') {
                    const close_bracket = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
                    const crit_str = rest[0 .. close_bracket + 1];
                    var ws_str = std.mem.trim(u8, rest[close_bracket + 1 ..], " \t");
                    if (std.mem.startsWith(u8, ws_str, "workspace ")) {
                        ws_str = std.mem.trim(u8, ws_str["workspace ".len..], " \t");
                    }
                    if (ws_str.len > 0 and ws_str[0] == '~') {
                        ws_str = ws_str[1..];
                    }
                    const crit = criteria_mod.parse(crit_str) orelse continue;
                    try cfg.assign_rules.append(.{
                        .criteria = crit,
                        .workspace = try allocator.dupe(u8, ws_str),
                    });
                }
                continue;
            }

            // exec [--no-startup-id] command
            if (std.mem.startsWith(u8, line, "exec ")) {
                var cmd = std.mem.trim(u8, line[5..], " \t");
                if (std.mem.startsWith(u8, cmd, "--no-startup-id ")) {
                    cmd = std.mem.trim(u8, cmd["--no-startup-id ".len..], " \t");
                }
                try cfg.exec_cmds.append(try allocator.dupe(u8, cmd));
                continue;
            }

            // exec_always [--no-startup-id] command
            if (std.mem.startsWith(u8, line, "exec_always ")) {
                var cmd = std.mem.trim(u8, line["exec_always ".len..], " \t");
                if (std.mem.startsWith(u8, cmd, "--no-startup-id ")) {
                    cmd = std.mem.trim(u8, cmd["--no-startup-id ".len..], " \t");
                }
                try cfg.exec_always_cmds.append(try allocator.dupe(u8, cmd));
                continue;
            }

            // mode "name" {
            if (std.mem.startsWith(u8, line, "mode ")) {
                const rest = std.mem.trim(u8, line[5..], " \t");
                var mode_name: []const u8 = rest;
                if (rest.len > 0 and rest[0] == '"') {
                    const end_quote = std.mem.indexOfScalar(u8, rest[1..], '"') orelse continue;
                    mode_name = rest[1 .. end_quote + 1];
                } else {
                    if (std.mem.endsWith(u8, mode_name, " {")) {
                        mode_name = mode_name[0 .. mode_name.len - 2];
                    } else if (std.mem.endsWith(u8, mode_name, "{")) {
                        mode_name = std.mem.trim(u8, mode_name[0 .. mode_name.len - 1], " \t");
                    }
                }
                const owned_name = try allocator.dupe(u8, mode_name);
                try cfg.modes.put(owned_name, {});
                current_mode = owned_name;
                continue;
            }

            // workspace N output NAME
            if (std.mem.startsWith(u8, line, "workspace ")) {
                const rest = std.mem.trim(u8, line["workspace ".len..], " \t");
                if (std.mem.indexOf(u8, rest, " output ")) |out_pos| {
                    const ws_name = rest[0..out_pos];
                    const out_name = rest[out_pos + " output ".len ..];
                    try cfg.workspace_outputs.append(.{
                        .workspace = try allocator.dupe(u8, ws_name),
                        .output = try allocator.dupe(u8, std.mem.trim(u8, out_name, " \t")),
                    });
                }
                continue;
            }

            // client.focused border bg text [indicator child_border]
            if (std.mem.startsWith(u8, line, "client.focused ")) {
                const rest = std.mem.trim(u8, line["client.focused ".len..], " \t");
                var tok_iter = std.mem.tokenizeScalar(u8, rest, ' ');
                if (tok_iter.next()) |border| {
                    cfg.freeIfOwned(.focused_border, cfg.focused_border);
                    cfg.focused_border = try allocator.dupe(u8, border);
                    cfg.setOwned(.focused_border);
                }
                if (tok_iter.next()) |bg| {
                    cfg.freeIfOwned(.focused_bg, cfg.focused_bg);
                    cfg.focused_bg = try allocator.dupe(u8, bg);
                    cfg.setOwned(.focused_bg);
                }
                if (tok_iter.next()) |text_col| {
                    cfg.freeIfOwned(.focused_text, cfg.focused_text);
                    cfg.focused_text = try allocator.dupe(u8, text_col);
                    cfg.setOwned(.focused_text);
                }
                continue;
            }

            // client.unfocused border bg text [indicator child_border]
            if (std.mem.startsWith(u8, line, "client.unfocused ")) {
                const rest = std.mem.trim(u8, line["client.unfocused ".len..], " \t");
                var tok_iter = std.mem.tokenizeScalar(u8, rest, ' ');
                if (tok_iter.next()) |border| {
                    cfg.freeIfOwned(.unfocused_border, cfg.unfocused_border);
                    cfg.unfocused_border = try allocator.dupe(u8, border);
                    cfg.setOwned(.unfocused_border);
                }
                if (tok_iter.next()) |bg| {
                    cfg.freeIfOwned(.unfocused_bg, cfg.unfocused_bg);
                    cfg.unfocused_bg = try allocator.dupe(u8, bg);
                    cfg.setOwned(.unfocused_bg);
                }
                if (tok_iter.next()) |text_col| {
                    cfg.freeIfOwned(.unfocused_text, cfg.unfocused_text);
                    cfg.unfocused_text = try allocator.dupe(u8, text_col);
                    cfg.setOwned(.unfocused_text);
                }
                continue;
            }

            // client.focused_inactive border bg text [indicator child_border]
            if (std.mem.startsWith(u8, line, "client.focused_inactive ")) {
                const rest = std.mem.trim(u8, line["client.focused_inactive ".len..], " \t");
                var tok_iter = std.mem.tokenizeScalar(u8, rest, ' ');
                if (tok_iter.next()) |border| {
                    cfg.freeIfOwned(.focused_inactive_border, cfg.focused_inactive_border);
                    cfg.focused_inactive_border = try allocator.dupe(u8, border);
                    cfg.setOwned(.focused_inactive_border);
                }
                if (tok_iter.next()) |bg| {
                    cfg.freeIfOwned(.focused_inactive_bg, cfg.focused_inactive_bg);
                    cfg.focused_inactive_bg = try allocator.dupe(u8, bg);
                    cfg.setOwned(.focused_inactive_bg);
                }
                if (tok_iter.next()) |text_col| {
                    cfg.freeIfOwned(.focused_inactive_text, cfg.focused_inactive_text);
                    cfg.focused_inactive_text = try allocator.dupe(u8, text_col);
                    cfg.setOwned(.focused_inactive_text);
                }
                continue;
            }

            // hide_edge_borders none|vertical|horizontal|both|smart
            if (std.mem.startsWith(u8, line, "hide_edge_borders ")) {
                const val = std.mem.trim(u8, line["hide_edge_borders ".len..], " \t");
                if (std.mem.eql(u8, val, "vertical")) cfg.hide_edge_borders = .vertical
                else if (std.mem.eql(u8, val, "horizontal")) cfg.hide_edge_borders = .horizontal
                else if (std.mem.eql(u8, val, "both")) cfg.hide_edge_borders = .both
                else if (std.mem.eql(u8, val, "smart")) cfg.hide_edge_borders = .smart
                else cfg.hide_edge_borders = .none;
                continue;
            }

            // bar {
            if (std.mem.eql(u8, line, "bar {") or std.mem.startsWith(u8, line, "bar {")) {
                in_bar = true;
                cfg.bar.enabled = true;
                continue;
            }

            // Unknown lines: silently skip
        }

        // パース完了後、余分なcapacityを解放
        cfg.keybinds.shrinkAndFree(cfg.keybinds.items.len);
        cfg.window_rules.shrinkAndFree(cfg.window_rules.items.len);
        cfg.assign_rules.shrinkAndFree(cfg.assign_rules.items.len);
        cfg.exec_cmds.shrinkAndFree(cfg.exec_cmds.items.len);
        cfg.exec_always_cmds.shrinkAndFree(cfg.exec_always_cmds.items.len);
        cfg.workspace_outputs.shrinkAndFree(cfg.workspace_outputs.items.len);

        return cfg;
    }

    pub fn getVariable(self: *const Config, name: []const u8) ?[]const u8 {
        return self.variables.get(name);
    }

    pub fn deinit(self: *Config) void {
        // Free variable keys and values
        var var_iter = self.variables.iterator();
        while (var_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();

        // Free keybind strings
        for (self.keybinds.items) |kb| {
            self.allocator.free(kb.key);
            self.allocator.free(kb.command);
            self.allocator.free(kb.mode);
        }
        self.keybinds.deinit();

        // Free window rules commands
        for (self.window_rules.items) |rule| {
            self.allocator.free(rule.command);
        }
        self.window_rules.deinit();

        // Free assign rules workspaces
        for (self.assign_rules.items) |rule| {
            self.allocator.free(rule.workspace);
        }
        self.assign_rules.deinit();

        // Free exec cmds
        for (self.exec_cmds.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.exec_cmds.deinit();

        // Free exec_always cmds
        for (self.exec_always_cmds.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.exec_always_cmds.deinit();

        // Free workspace outputs
        for (self.workspace_outputs.items) |wo| {
            self.allocator.free(wo.workspace);
            self.allocator.free(wo.output);
        }
        self.workspace_outputs.deinit();

        // Free mode names
        var mode_iter = self.modes.keyIterator();
        while (mode_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.modes.deinit();

        // Free owned color and bar strings via bitmask
        self.freeIfOwned(.focused_border, self.focused_border);
        self.freeIfOwned(.focused_bg, self.focused_bg);
        self.freeIfOwned(.focused_text, self.focused_text);
        self.freeIfOwned(.unfocused_border, self.unfocused_border);
        self.freeIfOwned(.unfocused_bg, self.unfocused_bg);
        self.freeIfOwned(.unfocused_text, self.unfocused_text);
        self.freeIfOwned(.focused_inactive_border, self.focused_inactive_border);
        self.freeIfOwned(.focused_inactive_bg, self.focused_inactive_bg);
        self.freeIfOwned(.focused_inactive_text, self.focused_inactive_text);
        self.freeIfOwned(.bar_status_command, self.bar.status_command);
        self.freeIfOwned(.bar_position, self.bar.position);
        self.freeIfOwned(.bar_font, self.bar.font);
        self.freeIfOwned(.bar_bg_color, self.bar.bg_color);
        self.freeIfOwned(.bar_statusline_color, self.bar.statusline_color);
    }
};

/// Expand $variables in a line using the config's variable map.
/// Output is written to buf (max 1023 chars). Returns slice into buf or original line.
fn expandVariables(cfg: *const Config, line: []const u8, buf: *[1024]u8) ![]const u8 {
    // Fast path: no $ in line
    if (std.mem.indexOfScalar(u8, line, '$') == null) {
        return line;
    }

    var out_len: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        if (line[i] == '$') {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) : (j += 1) {}
            const var_name = line[i..j]; // includes '$'
            if (cfg.variables.get(var_name)) |value| {
                if (out_len + value.len > 1023) return error.LineTooLong;
                @memcpy(buf[out_len .. out_len + value.len], value);
                out_len += value.len;
                i = j;
            } else {
                if (out_len >= 1023) return error.LineTooLong;
                buf[out_len] = line[i];
                out_len += 1;
                i += 1;
            }
        } else {
            if (out_len >= 1023) return error.LineTooLong;
            buf[out_len] = line[i];
            out_len += 1;
            i += 1;
        }
    }

    return buf[0..out_len];
}
