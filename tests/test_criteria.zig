const std = @import("std");
const criteria = @import("criteria");
const tree = @import("tree");

test "parse simple class criteria" {
    const crit = criteria.parse("[class=\"Firefox\"]") orelse {
        return error.ParseFailed;
    };
    try std.testing.expectEqualStrings("Firefox", crit.class.?);
    try std.testing.expect(crit.instance == null);
    try std.testing.expect(crit.title == null);
}

test "parse multiple criteria (class + title)" {
    const crit = criteria.parse("[class=\"Firefox\" title=\"GitHub*\"]") orelse {
        return error.ParseFailed;
    };
    try std.testing.expectEqualStrings("Firefox", crit.class.?);
    try std.testing.expectEqualStrings("GitHub*", crit.title.?);
    try std.testing.expect(crit.instance == null);
}

test "glob match exact" {
    try std.testing.expect(criteria.globMatch("Firefox", "Firefox"));
    try std.testing.expect(!criteria.globMatch("Firefox", "Chromium"));
    try std.testing.expect(!criteria.globMatch("Firefox", "firefox")); // case sensitive
}

test "glob match wildcard" {
    // prefix wildcard
    try std.testing.expect(criteria.globMatch("Fire*", "Firefox"));
    try std.testing.expect(criteria.globMatch("Fire*", "Fire"));
    try std.testing.expect(criteria.globMatch("Fire*", "Firefox2extra")); // * matches any suffix
    // suffix wildcard
    try std.testing.expect(criteria.globMatch("*fox", "Firefox"));
    try std.testing.expect(!criteria.globMatch("*fox", "Firebird"));
    // match-all
    try std.testing.expect(criteria.globMatch("*", "anything"));
    try std.testing.expect(criteria.globMatch("*", ""));
    // infix wildcard
    try std.testing.expect(criteria.globMatch("Git*Hub", "GitHub"));
    try std.testing.expect(criteria.globMatch("Git*Hub", "Git-Hub"));
    try std.testing.expect(!criteria.globMatch("Git*Hub", "GitLab"));
    // multiple wildcards
    try std.testing.expect(criteria.globMatch("*fox*", "Firefox Browser"));
    // empty pattern matches only empty string
    try std.testing.expect(criteria.globMatch("", ""));
    try std.testing.expect(!criteria.globMatch("", "x"));
}

test "criteria matches container with matching class" {
    var con = tree.Container{ .type = .window };
    con.window = tree.WindowData{
        .id = 1,
        .class = "Firefox",
        .instance = "Navigator",
        .title = "GitHub",
        .window_role = "",
    };
    const crit = criteria.parse("[class=\"Firefox\"]").?;
    try std.testing.expect(criteria.matches(&crit, &con));
}

test "criteria doesn't match container with wrong class" {
    var con = tree.Container{ .type = .window };
    con.window = tree.WindowData{
        .id = 2,
        .class = "Chromium",
        .instance = "chromium",
        .title = "New Tab",
        .window_role = "",
    };
    const crit = criteria.parse("[class=\"Firefox\"]").?;
    try std.testing.expect(!criteria.matches(&crit, &con));
}

test "criteria matches with title glob" {
    var con = tree.Container{ .type = .window };
    con.window = tree.WindowData{
        .id = 3,
        .class = "Firefox",
        .instance = "Navigator",
        .title = "GitHub - Pull Requests",
        .window_role = "",
    };
    const crit = criteria.parse("[title=\"GitHub*\"]").?;
    try std.testing.expect(criteria.matches(&crit, &con));

    const crit2 = criteria.parse("[title=\"*Pull*\"]").?;
    try std.testing.expect(criteria.matches(&crit2, &con));

    const crit3 = criteria.parse("[title=\"GitLab*\"]").?;
    try std.testing.expect(!criteria.matches(&crit3, &con));
}

test "criteria matches with mark" {
    var con = tree.Container{ .type = .window };
    con.window = tree.WindowData{
        .id = 4,
        .class = "Alacritty",
        .instance = "alacritty",
        .title = "Terminal",
        .window_role = "",
    };
    try con.addMark("terminal");

    const crit = criteria.parse("[con_mark=\"terminal\"]").?;
    try std.testing.expect(criteria.matches(&crit, &con));

    const crit_bad = criteria.parse("[con_mark=\"browser\"]").?;
    try std.testing.expect(!criteria.matches(&crit_bad, &con));
}

test "parse invalid - no brackets returns null" {
    try std.testing.expect(criteria.parse("class=\"Firefox\"") == null);
    try std.testing.expect(criteria.parse("[class=\"Firefox\"") == null);
    try std.testing.expect(criteria.parse("class=\"Firefox\"]") == null);
}

test "parse invalid - no quotes returns null" {
    try std.testing.expect(criteria.parse("[class=Firefox]") == null);
}

test "empty [] is valid and matches everything" {
    const crit = criteria.parse("[]") orelse {
        return error.ParseFailed;
    };
    try std.testing.expect(crit.class == null);
    try std.testing.expect(crit.title == null);
    try std.testing.expect(crit.instance == null);
    try std.testing.expect(crit.con_mark == null);
    try std.testing.expect(crit.floating == null);

    // Should match any container (window or non-window)
    var con = tree.Container{ .type = .workspace };
    try std.testing.expect(criteria.matches(&crit, &con));

    var win_con = tree.Container{ .type = .window };
    win_con.window = tree.WindowData{
        .id = 5,
        .class = "AnyClass",
        .instance = "any",
        .title = "Any Title",
        .window_role = "",
    };
    try std.testing.expect(criteria.matches(&crit, &win_con));
}
