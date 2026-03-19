const std = @import("std");
const ipc = @import("ipc");

pub fn main() !void {
    std.debug.print("ziawm-bar v0.1.0\n", .{});

    // TODO: Full bar implementation
    // 1. Connect to IPC socket (GET_BAR_CONFIG)
    // 2. Create xcb window for bar
    // 3. Subscribe to workspace events
    // 4. Spawn status_command, read i3bar protocol
    // 5. Render workspace buttons + status text
    // 6. Handle clicks

    // For now, users should use external bars (polybar, i3blocks+lemonbar)
    // that communicate via the i3-compatible IPC protocol.
}
