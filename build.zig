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

    // --- Test step ---
    // Test entries will be added here as modules are created.
    // For now, just set up the infrastructure.
    const test_step = b.step("test", "Run tests");
    _ = test_step;

    // Run steps
    const run_ziawm = b.addRunArtifact(ziawm_exe);
    run_ziawm.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run ziawm");
    run_step.dependOn(&run_ziawm.step);
}
