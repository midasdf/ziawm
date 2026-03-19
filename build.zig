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

    // --- zephwm (main WM) ---
    const zephwm_exe = b.addExecutable(.{
        .name = "zephwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zephwm_exe.linkSystemLibrary("xcb");
    zephwm_exe.linkSystemLibrary("xcb-keysyms");
    zephwm_exe.linkSystemLibrary("xcb-randr");
    zephwm_exe.linkSystemLibrary("xcb-xkb");
    zephwm_exe.linkSystemLibrary("xkbcommon");
    zephwm_exe.linkSystemLibrary("xkbcommon-x11");
    zephwm_exe.linkLibC();
    b.installArtifact(zephwm_exe);

    // --- zephwm-msg ---
    const msg_exe = b.addExecutable(.{
        .name = "zephwm-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zephwm-msg/main.zig"),
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

    // --- zephwm-bar ---
    const bar_exe = b.addExecutable(.{
        .name = "zephwm-bar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zephwm-bar/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });
    bar_exe.linkSystemLibrary("xcb");
    bar_exe.linkSystemLibrary("X11");
    bar_exe.linkSystemLibrary("X11-xcb");
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
    // Note: layout.zig uses @import("tree.zig") file-based import.
    // For tests, we map "tree.zig" to tree_mod so the same type identity is used.
    const layout_mod = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree.zig", .module = tree_mod },
        },
    });

    // Criteria module (pure Zig, depends on tree)
    // Same approach: map "tree.zig" to tree_mod for type identity.
    const criteria_mod = b.createModule(.{
        .root_source_file = b.path("src/criteria.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree.zig", .module = tree_mod },
        },
    });

    // Command module (pure Zig, depends on criteria)
    const command_mod = b.createModule(.{
        .root_source_file = b.path("src/command.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "criteria.zig", .module = criteria_mod },
        },
    });

    // Config module (pure Zig, depends on criteria which depends on tree)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "criteria", .module = criteria_mod },
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

    // config tests
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = config_mod },
            },
        }),
    });
    const run_config_tests = b.addRunArtifact(config_tests);
    test_step.dependOn(&run_config_tests.step);

    // command tests
    const command_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_command.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "command", .module = command_mod },
            },
        }),
    });
    const run_command_tests = b.addRunArtifact(command_tests);
    test_step.dependOn(&run_command_tests.step);

    // ipc tests
    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_ipc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    test_step.dependOn(&run_ipc_tests.step);

    // Run steps
    const run_zephwm = b.addRunArtifact(zephwm_exe);
    run_zephwm.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zephwm");
    run_step.dependOn(&run_zephwm.step);
}
