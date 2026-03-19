// Event dispatch — X11 event handling stubs
const std = @import("std");
const xcb = @import("xcb.zig");
const tree = @import("tree.zig");
const atoms_mod = @import("atoms.zig");

pub const EventContext = struct {
    conn: *xcb.Connection,
    root_window: xcb.Window,
    atoms: atoms_mod.Atoms,
    tree_root: *tree.Container,
    allocator: std.mem.Allocator,
    running: *bool,
    current_mode: []const u8,
    focus_follows_mouse: bool,
};

/// Dispatch an X11 event to the appropriate handler.
pub fn handleEvent(ctx: *EventContext, event: *xcb.GenericEvent) void {
    const response_type = event.response_type & 0x7f; // mask out sent-event bit

    switch (response_type) {
        xcb.MAP_REQUEST => handleMapRequest(ctx, @ptrCast(event)),
        xcb.UNMAP_NOTIFY => handleUnmapNotify(ctx, @ptrCast(event)),
        xcb.DESTROY_NOTIFY => handleDestroyNotify(ctx, @ptrCast(event)),
        xcb.KEY_PRESS => handleKeyPress(ctx, @ptrCast(event)),
        xcb.ENTER_NOTIFY => handleEnterNotify(ctx, @ptrCast(event)),
        xcb.CONFIGURE_REQUEST => handleConfigureRequest(ctx, @ptrCast(event)),
        xcb.PROPERTY_NOTIFY => handlePropertyNotify(ctx, @ptrCast(event)),
        xcb.CLIENT_MESSAGE => handleClientMessage(ctx, @ptrCast(event)),
        xcb.FOCUS_IN => handleFocusIn(ctx, @ptrCast(event)),
        xcb.MAPPING_NOTIFY => handleMappingNotify(ctx, event),
        else => {}, // Ignore unhandled events
    }
}

// --- Handler stubs (implemented in Task 17) ---

fn handleMapRequest(_: *EventContext, _: *xcb.MapRequestEvent) void {
    // TODO: Task 17 — manage new window (reparent, add to tree, apply layout)
}

fn handleUnmapNotify(_: *EventContext, _: *xcb.UnmapNotifyEvent) void {
    // TODO: Task 17 — remove window from tree if managed
}

fn handleDestroyNotify(_: *EventContext, _: *xcb.DestroyNotifyEvent) void {
    // TODO: Task 17 — clean up destroyed window
}

fn handleKeyPress(_: *EventContext, _: *xcb.KeyPressEvent) void {
    // TODO: Task 17 — look up binding, execute command
}

fn handleEnterNotify(_: *EventContext, _: *xcb.EnterNotifyEvent) void {
    // TODO: Task 17 — focus follows mouse
}

fn handleConfigureRequest(_: *EventContext, _: *xcb.ConfigureRequestEvent) void {
    // TODO: Task 17 — forward configure for unmanaged, adjust for managed
}

fn handlePropertyNotify(_: *EventContext, _: *xcb.PropertyNotifyEvent) void {
    // TODO: Task 17 — update title, class, urgency hints
}

fn handleClientMessage(_: *EventContext, _: *xcb.ClientMessageEvent) void {
    // TODO: Task 17 — handle EWMH client messages (_NET_ACTIVE_WINDOW, etc.)
}

fn handleFocusIn(_: *EventContext, _: *xcb.FocusInEvent) void {
    // TODO: Task 17 — validate focus state
}

fn handleMappingNotify(_: *EventContext, _: *xcb.GenericEvent) void {
    // TODO: Task 17 — refresh key mappings
}
