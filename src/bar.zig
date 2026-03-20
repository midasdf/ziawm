// Bar management — spawn external bar process
const std = @import("std");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() std.c.pid_t;

/// Spawn the bar process (e.g. i3bar, polybar, lemonbar).
/// The bar is launched as a detached child process with the I3SOCK
/// environment variable set so it can connect to zephwm's IPC.
/// `status_command` is the i3bar-protocol status command (e.g. "i3blocks").
/// `position` is "top" or "bottom".
pub fn spawnBar(status_command: []const u8, position: []const u8) void {
    _ = position; // Bar reads position via IPC GET_BAR_CONFIG at startup

    if (status_command.len == 0) return;

    // Build shell command: exec the status command
    // In i3, the bar itself runs and spawns status_command.
    // Since zephwm-bar is a stub, we just launch status_command directly
    // for use with external bars that read i3bar protocol.
    var cmd_buf: [512]u8 = undefined;
    const cmd_len = @min(status_command.len, cmd_buf.len - 1);
    @memcpy(cmd_buf[0..cmd_len], status_command[0..cmd_len]);
    cmd_buf[cmd_len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_len :0]);

    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        // Child process
        _ = setsid();

        // Close inherited fds > stderr
        var fd: c_int = 3;
        while (fd < 256) : (fd += 1) {
            _ = std.c.close(fd);
        }

        const argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd_z,
        };
        _ = execvp("/bin/sh", &argv);
        std.c._exit(1);
    }
    // Parent: bar runs in background, reaped by SIGCHLD handler
    std.debug.print("zephwm: spawned bar process (pid {d})\n", .{pid});
}
