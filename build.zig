const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared modules
    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- ziawm (main WM) ---
    const ziawm_exe = b.addExecutable(.{
        .name = "ziawm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ziawm_exe.linkSystemLibrary("xcb");
    ziawm_exe.linkSystemLibrary("xcb-keysyms");
    ziawm_exe.linkSystemLibrary("xcb-randr");
    ziawm_exe.linkSystemLibrary("xcb-xkb");
    ziawm_exe.linkSystemLibrary("xkbcommon");
    ziawm_exe.linkSystemLibrary("xkbcommon-x11");
    ziawm_exe.linkLibC();
    b.installArtifact(ziawm_exe);

    // --- ziawm-msg ---
    const msg_exe = b.addExecutable(.{
        .name = "ziawm-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ziawm-msg/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });
    msg_exe.linkSystemLibrary("xcb");
    msg_exe.linkLibC();
    b.installArtifact(msg_exe);

    // --- ziawm-bar ---
    const bar_exe = b.addExecutable(.{
        .name = "ziawm-bar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ziawm-bar/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });
    bar_exe.linkSystemLibrary("xcb");
    bar_exe.linkSystemLibrary("xft");
    bar_exe.linkSystemLibrary("fontconfig");
    bar_exe.linkLibC();
    b.installArtifact(bar_exe);

    // Shared tree module (pure Zig, no xcb dependency)
    const tree_mod = b.createModule(.{
        .root_source_file = b.path("src/tree.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared layout module (pure Zig, no xcb dependency)
    const layout_mod = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree", .module = tree_mod },
        },
    });

    // Criteria module (pure Zig, depends on tree)
    const criteria_mod = b.createModule(.{
        .root_source_file = b.path("src/criteria.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree", .module = tree_mod },
        },
    });

    // --- Test step ---
    const test_step = b.step("test", "Run tests");

    // tree tests
    const tree_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_tree.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree", .module = tree_mod },
            },
        }),
    });
    const run_tree_tests = b.addRunArtifact(tree_tests);
    test_step.dependOn(&run_tree_tests.step);

    // criteria tests
    const criteria_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_criteria.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree", .module = tree_mod },
                .{ .name = "criteria", .module = criteria_mod },
            },
        }),
    });
    const run_criteria_tests = b.addRunArtifact(criteria_tests);
    test_step.dependOn(&run_criteria_tests.step);

    // layout tests
    const layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_layout.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tree", .module = tree_mod },
                .{ .name = "layout", .module = layout_mod },
            },
        }),
    });
    const run_layout_tests = b.addRunArtifact(layout_tests);
    test_step.dependOn(&run_layout_tests.step);

    // Run steps
    const run_ziawm = b.addRunArtifact(ziawm_exe);
    run_ziawm.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run ziawm");
    run_step.dependOn(&run_ziawm.step);
}
