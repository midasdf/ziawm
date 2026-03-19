// Bar management — stub for future ziawm-bar auto-spawn
const std = @import("std");

/// Spawn the bar process. For now just a placeholder.
/// Full implementation will fork+exec ziawm-bar with IPC socket path.
pub fn spawnBar(status_command: []const u8, position: []const u8) !void {
    _ = status_command;
    _ = position;
    // TODO: fork + exec ziawm-bar
    // For now, bars are launched externally
}
