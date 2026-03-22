// Bar management — spawn external bar process
const std = @import("std");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() std.c.pid_t;

/// PID of the spawned bar process (0 if none). Used for cleanup on exit.
var bar_pid: std.posix.pid_t = 0;

/// Spawn the bar process (e.g. i3bar, polybar, lemonbar).
/// The bar is launched as a detached child process with the I3SOCK
/// environment variable set so it can connect to zephwm's IPC.
/// `status_command` is the i3bar-protocol status command (e.g. "i3blocks").
/// `position` is "top" or "bottom".
pub fn spawnBar(status_command: []const u8, position: []const u8) void {
    _ = position; // Bar reads position via IPC GET_BAR_CONFIG at startup

    if (status_command.len == 0) return;

    // Kill previous bar if any
    killBar();

    // Build null-terminated status_command string
    var cmd_buf: [512]u8 = undefined;
    const cmd_len = @min(status_command.len, cmd_buf.len - 1);
    @memcpy(cmd_buf[0..cmd_len], status_command[0..cmd_len]);
    cmd_buf[cmd_len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_len :0]);

    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        // Child process
        _ = setsid();

        // Redirect stderr to /dev/null to prevent tty pollution
        // (stdout is kept — zephwm-bar may use it for status protocol)
        const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch -1;
        if (devnull >= 0) {
            _ = std.posix.dup2(@intCast(devnull), 2) catch {}; // stderr only
            std.posix.close(@intCast(devnull));
        }

        // Close inherited fds > stderr
        var fd: c_int = 3;
        while (fd < 256) : (fd += 1) {
            _ = std.c.close(fd);
        }

        // Launch zephwm-bar with status_command as argument
        const argv = [_:null]?[*:0]const u8{
            "zephwm-bar",
            cmd_z,
        };
        _ = execvp("zephwm-bar", &argv);

        // Fallback: run status_command directly via shell
        const sh_argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd_z,
        };
        _ = execvp("/bin/sh", &sh_argv);
        std.c._exit(1);
    }
    bar_pid = pid;
}

/// Kill the bar process and its children. Called on WM exit and before respawn.
pub fn killBar() void {
    if (bar_pid > 0) {
        // Kill the entire process group (setsid made bar the group leader)
        std.posix.kill(-bar_pid, std.posix.SIG.TERM) catch {};
        std.posix.kill(bar_pid, std.posix.SIG.TERM) catch {};
        bar_pid = 0;
    }
}
