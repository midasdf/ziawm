const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ContainerType = enum { root, output, workspace, split_con, window };
pub const Layout = enum { hsplit, vsplit, tabbed, stacked };
pub const FullscreenMode = enum { none, window, global };

/// Screen geometry. i32 for x/y to support negative positions (multi-monitor).
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const WindowData = struct {
    id: u32,
    frame_id: u32 = 0,
    class: []const u8 = "",
    instance: []const u8 = "",
    title: []const u8 = "",
    window_role: []const u8 = "",
    window_type: []const u8 = "",
    transient_for: ?u32 = null,
    urgency: bool = false,
    /// Counter for WM-initiated unmaps. Incremented when the WM calls xcb_unmap_window,
    /// decremented when UnmapNotify arrives. If > 0, the unmap was WM-initiated and
    /// should be ignored (not treated as client destroy).
    pending_unmap: u16 = 0,
    /// Whether the WM considers this window to be in a mapped state.
    /// Used to avoid redundant unmap calls and counter drift.
    mapped: bool = true,
};

pub const WorkspaceData = struct {
    name: []const u8,
    num: ?i32 = null,
    output_name: []const u8 = "",
    urgent: bool = false,
};

pub const ChildList = struct {
    first: ?*Container = null,
    last: ?*Container = null,
    count: usize = 0,

    /// Append a node to the end of the list. Node must already have parent set.
    pub fn append(self: *ChildList, node: *Container) void {
        if (self.last) |last| {
            last.next = node;
            node.prev = last;
            node.next = null;
            self.last = node;
        } else {
            node.prev = null;
            node.next = null;
            self.first = node;
            self.last = node;
        }
        self.count += 1;
    }

    /// Prepend a node to the front of the list. Node must already have parent set.
    pub fn prepend(self: *ChildList, node: *Container) void {
        if (self.first) |first| {
            first.prev = node;
            node.next = first;
            node.prev = null;
            self.first = node;
        } else {
            node.prev = null;
            node.next = null;
            self.first = node;
            self.last = node;
        }
        self.count += 1;
    }

    /// Insert `node` before `ref` in the list. `ref` must be in this list.
    /// Node must already have parent set.
    pub fn insertBefore(self: *ChildList, node: *Container, ref: *Container) void {
        node.next = ref;
        node.prev = ref.prev;
        if (ref.prev) |prev| {
            prev.next = node;
        } else {
            self.first = node;
        }
        ref.prev = node;
        self.count += 1;
    }

    /// Remove a node from the list without freeing it.
    pub fn remove(self: *ChildList, node: *Container) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.first = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.last = node.prev;
        }
        node.prev = null;
        node.next = null;
        self.count -= 1;
    }

    /// O(1) count of elements.
    pub fn len(self: *const ChildList) usize {
        return self.count;
    }
};

pub const Container = struct {
    type: ContainerType,
    layout: Layout = .hsplit,
    parent: ?*Container = null,
    prev: ?*Container = null,
    next: ?*Container = null,
    children: ChildList = .{},
    rect: Rect = .{},
    window_rect: Rect = .{},
    window: ?WindowData = null,
    workspace: ?WorkspaceData = null,
    percent: f32 = 0.0,
    is_floating: bool = false,
    is_fullscreen: FullscreenMode = .none,
    is_focused: bool = false,
    is_scratchpad: bool = false,
    is_sticky: bool = false,
    dirty: bool = true,
    marks: [4]?[]const u8 = .{null} ** 4,
    mark_count: u8 = 0,

    /// Allocate and initialise a new container of the given type.
    pub fn create(alloc: Allocator, con_type: ContainerType) !*Container {
        const con = try alloc.create(Container);
        con.* = .{ .type = con_type };
        return con;
    }

    /// Free an allocator-owned string, but skip default empty string literals ("").
    fn freeOwnedString(alloc: Allocator, s: []const u8) void {
        if (s.len == 0) return;
        alloc.free(s);
    }

    /// Recursively destroy this container and all its children.
    /// This frees all allocator-owned strings (WindowData, WorkspaceData).
    /// Callers must NOT free strings separately before calling destroy().
    /// The container pointer is freed by the allocator; do not use it after this call.
    pub fn destroy(self: *Container, alloc: Allocator) void {
        // Destroy children depth-first before freeing self.
        var cur = self.children.first;
        while (cur) |child| {
            const next = child.next;
            child.destroy(alloc);
            cur = next;
        }
        // Free allocator-owned WindowData strings
        if (self.window) |wd| {
            freeOwnedString(alloc, wd.class);
            freeOwnedString(alloc, wd.instance);
            freeOwnedString(alloc, wd.title);
            freeOwnedString(alloc, wd.window_role);
            freeOwnedString(alloc, wd.window_type);
        }
        // Free allocator-owned workspace/output name strings
        if (self.workspace) |wsd| {
            freeOwnedString(alloc, wsd.name);
            freeOwnedString(alloc, wsd.output_name);
        }
        // Free allocator-owned mark strings
        for (self.marks[0..self.mark_count]) |mark_opt| {
            if (mark_opt) |mark| {
                freeOwnedString(alloc, mark);
            }
        }
        alloc.destroy(self);
    }

    /// Remove this container from its parent's child list.
    /// The container is NOT freed. Caller owns the memory.
    pub fn unlink(self: *Container) void {
        if (self.parent) |par| {
            par.children.remove(self);
            self.parent = null;
        }
    }

    /// Append `child` as the last child of this container.
    pub fn appendChild(self: *Container, child: *Container) void {
        child.parent = self;
        self.children.append(child);
    }

    /// Insert `child` before `ref` in this container's child list.
    /// `ref` must be a direct child of `self`.
    pub fn insertBefore(self: *Container, child: *Container, ref: *Container) void {
        child.parent = self;
        self.children.insertBefore(child, ref);
    }

    /// Move `child` to the head of this container's child list.
    /// `child` must be a direct child of `self`.
    pub fn promoteChild(self: *Container, child: *Container) void {
        if (self.children.first == child) return; // already at head
        self.children.remove(child);
        self.children.prepend(child);
    }

    /// Count tiling (non-floating) children.
    pub fn tilingChildCount(self: *const Container) usize {
        var count: usize = 0;
        var cur = self.children.first;
        while (cur) |child| : (cur = child.next) {
            if (!child.is_floating) count += 1;
        }
        return count;
    }

    /// Return the first direct child that has `is_focused == true`, or null.
    pub fn focusedChild(self: *const Container) ?*Container {
        var cur = self.children.first;
        while (cur) |child| : (cur = child.next) {
            if (child.is_focused) return child;
        }
        return null;
    }

    /// Add a mark string (caller-owned). Duplicate marks are rejected.
    /// Returns `error.MarksCapacityExceeded` if the marks array is full.
    /// Returns `error.DuplicateMark` if the mark already exists.
    pub fn addMark(self: *Container, mark: []const u8) !void {
        // Check duplicate
        for (self.marks[0..self.mark_count]) |existing| {
            if (existing) |m| {
                if (std.mem.eql(u8, m, mark)) return error.DuplicateMark;
            }
        }
        if (self.mark_count >= 4) return error.MarksCapacityExceeded;
        self.marks[self.mark_count] = mark;
        self.mark_count += 1;
    }

    /// Remove a mark string and free its memory. No-op if the mark is not present.
    pub fn removeMark(self: *Container, alloc: Allocator, mark: []const u8) void {
        for (self.marks[0..self.mark_count], 0..) |existing, i| {
            if (existing) |m| {
                if (std.mem.eql(u8, m, mark)) {
                    // Free the owned mark string
                    freeOwnedString(alloc, m);
                    // Shift remaining marks down
                    const count = self.mark_count;
                    var j = i;
                    while (j + 1 < count) : (j += 1) {
                        self.marks[j] = self.marks[j + 1];
                    }
                    self.marks[count - 1] = null;
                    self.mark_count -= 1;
                    return;
                }
            }
        }
    }

    /// Return true if this container has the given mark.
    pub fn hasMark(self: *const Container, mark: []const u8) bool {
        for (self.marks[0..self.mark_count]) |existing| {
            if (existing) |m| {
                if (std.mem.eql(u8, m, mark)) return true;
            }
        }
        return false;
    }
};
