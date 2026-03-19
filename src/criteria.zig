const std = @import("std");
const tree = @import("tree");

pub const Criteria = struct {
    class: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    title: ?[]const u8 = null,
    window_role: ?[]const u8 = null,
    con_mark: ?[]const u8 = null,
    floating: ?bool = null,
    workspace: ?[]const u8 = null,
};

/// Parse "[class=\"Firefox\" title=\"Git*\"]" into Criteria.
/// Returns null if input is malformed.
pub fn parse(input: []const u8) ?Criteria {
    // Must start with '[' and end with ']'
    if (input.len < 2) return null;
    if (input[0] != '[' or input[input.len - 1] != ']') return null;

    var crit = Criteria{};
    var rest = input[1 .. input.len - 1];

    // Parse key="value" pairs
    while (rest.len > 0) {
        // Skip whitespace
        var i: usize = 0;
        while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
        rest = rest[i..];
        if (rest.len == 0) break;

        // Find '='
        const eq_pos = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
        const key = std.mem.trim(u8, rest[0..eq_pos], " \t");
        rest = rest[eq_pos + 1 ..];

        // Value must start with '"'
        if (rest.len == 0 or rest[0] != '"') return null;
        rest = rest[1..]; // skip opening quote

        // Find closing quote (not escaped)
        var close: usize = 0;
        while (close < rest.len and rest[close] != '"') : (close += 1) {}
        if (close >= rest.len) return null; // no closing quote

        const value = rest[0..close];
        rest = rest[close + 1 ..]; // skip closing quote

        // Assign to matching field
        if (std.mem.eql(u8, key, "class")) {
            crit.class = value;
        } else if (std.mem.eql(u8, key, "instance")) {
            crit.instance = value;
        } else if (std.mem.eql(u8, key, "title")) {
            crit.title = value;
        } else if (std.mem.eql(u8, key, "window_role")) {
            crit.window_role = value;
        } else if (std.mem.eql(u8, key, "con_mark")) {
            crit.con_mark = value;
        } else if (std.mem.eql(u8, key, "floating")) {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
                crit.floating = true;
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
                crit.floating = false;
            }
            // unknown value: ignore
        } else if (std.mem.eql(u8, key, "workspace")) {
            crit.workspace = value;
        }
        // Unknown keys: silently ignored
    }

    return crit;
}

/// Glob match with * wildcard only. * matches zero or more characters.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0; // pattern index
    var ti: usize = 0; // text index
    var star_pi: usize = std.math.maxInt(usize); // last star position in pattern
    var star_ti: usize = 0; // text position when last star was encountered

    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            // Record star position and advance pattern
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == text[ti]) {
            // Exact match, advance both
            pi += 1;
            ti += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            // Backtrack: star consumes one more character
            star_ti += 1;
            ti = star_ti;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }

    // Consume trailing stars in pattern
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}

    return pi == pattern.len;
}

/// Check if a container matches criteria.
/// Each non-null criteria field must match. If all match, return true.
pub fn matches(crit: *const Criteria, con: *const tree.Container) bool {
    // class / instance / title / window_role require WindowData
    if (crit.class != null or crit.instance != null or
        crit.title != null or crit.window_role != null)
    {
        const wd = con.window orelse return false;

        if (crit.class) |pat| {
            if (!globMatch(pat, wd.class)) return false;
        }
        if (crit.instance) |pat| {
            if (!globMatch(pat, wd.instance)) return false;
        }
        if (crit.title) |pat| {
            if (!globMatch(pat, wd.title)) return false;
        }
        if (crit.window_role) |pat| {
            if (!globMatch(pat, wd.window_role)) return false;
        }
    }

    if (crit.con_mark) |mark| {
        if (!con.hasMark(mark)) return false;
    }

    if (crit.floating) |want_floating| {
        if (con.is_floating != want_floating) return false;
    }

    // workspace: skip for now (needs tree walking)
    _ = crit.workspace;

    return true;
}
