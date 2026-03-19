// EWMH/ICCCM atom definitions
const std = @import("std");
const xcb = @import("xcb.zig");

pub const Atoms = struct {
    // EWMH
    net_supported: xcb.Atom = xcb.ATOM_NONE,
    net_supporting_wm_check: xcb.Atom = xcb.ATOM_NONE,
    net_wm_name: xcb.Atom = xcb.ATOM_NONE,
    net_wm_state: xcb.Atom = xcb.ATOM_NONE,
    net_wm_state_fullscreen: xcb.Atom = xcb.ATOM_NONE,
    net_wm_state_demands_attention: xcb.Atom = xcb.ATOM_NONE,
    net_wm_state_hidden: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_dialog: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_splash: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_notification: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_normal: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_toolbar: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_menu: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_utility: xcb.Atom = xcb.ATOM_NONE,
    net_wm_window_type_dock: xcb.Atom = xcb.ATOM_NONE,
    net_active_window: xcb.Atom = xcb.ATOM_NONE,
    net_current_desktop: xcb.Atom = xcb.ATOM_NONE,
    net_number_of_desktops: xcb.Atom = xcb.ATOM_NONE,
    net_desktop_names: xcb.Atom = xcb.ATOM_NONE,
    net_wm_desktop: xcb.Atom = xcb.ATOM_NONE,
    net_wm_strut_partial: xcb.Atom = xcb.ATOM_NONE,
    net_client_list: xcb.Atom = xcb.ATOM_NONE,
    net_wm_pid: xcb.Atom = xcb.ATOM_NONE,
    net_close_window: xcb.Atom = xcb.ATOM_NONE,

    // ICCCM
    wm_protocols: xcb.Atom = xcb.ATOM_NONE,
    wm_delete_window: xcb.Atom = xcb.ATOM_NONE,
    wm_take_focus: xcb.Atom = xcb.ATOM_NONE,
    wm_class: xcb.Atom = xcb.ATOM_NONE,
    wm_name: xcb.Atom = xcb.ATOM_NONE,
    wm_normal_hints: xcb.Atom = xcb.ATOM_NONE,
    wm_hints: xcb.Atom = xcb.ATOM_NONE,
    wm_transient_for: xcb.Atom = xcb.ATOM_NONE,
    wm_window_role: xcb.Atom = xcb.ATOM_NONE,
    wm_state: xcb.Atom = xcb.ATOM_NONE,
    wm_change_state: xcb.Atom = xcb.ATOM_NONE,

    // Other
    utf8_string: xcb.Atom = xcb.ATOM_NONE,
    i3_socket_path: xcb.Atom = xcb.ATOM_NONE,

    /// Intern all atoms (blocking). Call once at startup.
    pub fn init(conn: *xcb.Connection) Atoms {
        return .{
            // EWMH
            .net_supported = xcb.getAtom(conn, "_NET_SUPPORTED"),
            .net_supporting_wm_check = xcb.getAtom(conn, "_NET_SUPPORTING_WM_CHECK"),
            .net_wm_name = xcb.getAtom(conn, "_NET_WM_NAME"),
            .net_wm_state = xcb.getAtom(conn, "_NET_WM_STATE"),
            .net_wm_state_fullscreen = xcb.getAtom(conn, "_NET_WM_STATE_FULLSCREEN"),
            .net_wm_state_demands_attention = xcb.getAtom(conn, "_NET_WM_STATE_DEMANDS_ATTENTION"),
            .net_wm_state_hidden = xcb.getAtom(conn, "_NET_WM_STATE_HIDDEN"),
            .net_wm_window_type = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE"),
            .net_wm_window_type_dialog = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_DIALOG"),
            .net_wm_window_type_splash = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_SPLASH"),
            .net_wm_window_type_notification = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_NOTIFICATION"),
            .net_wm_window_type_normal = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_NORMAL"),
            .net_wm_window_type_toolbar = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_TOOLBAR"),
            .net_wm_window_type_menu = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_MENU"),
            .net_wm_window_type_utility = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_UTILITY"),
            .net_wm_window_type_dock = xcb.getAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK"),
            .net_active_window = xcb.getAtom(conn, "_NET_ACTIVE_WINDOW"),
            .net_current_desktop = xcb.getAtom(conn, "_NET_CURRENT_DESKTOP"),
            .net_number_of_desktops = xcb.getAtom(conn, "_NET_NUMBER_OF_DESKTOPS"),
            .net_desktop_names = xcb.getAtom(conn, "_NET_DESKTOP_NAMES"),
            .net_wm_desktop = xcb.getAtom(conn, "_NET_WM_DESKTOP"),
            .net_wm_strut_partial = xcb.getAtom(conn, "_NET_WM_STRUT_PARTIAL"),
            .net_client_list = xcb.getAtom(conn, "_NET_CLIENT_LIST"),
            .net_wm_pid = xcb.getAtom(conn, "_NET_WM_PID"),
            .net_close_window = xcb.getAtom(conn, "_NET_CLOSE_WINDOW"),

            // ICCCM
            .wm_protocols = xcb.getAtom(conn, "WM_PROTOCOLS"),
            .wm_delete_window = xcb.getAtom(conn, "WM_DELETE_WINDOW"),
            .wm_take_focus = xcb.getAtom(conn, "WM_TAKE_FOCUS"),
            .wm_class = xcb.getAtom(conn, "WM_CLASS"),
            .wm_name = xcb.getAtom(conn, "WM_NAME"),
            .wm_normal_hints = xcb.getAtom(conn, "WM_NORMAL_HINTS"),
            .wm_hints = xcb.getAtom(conn, "WM_HINTS"),
            .wm_transient_for = xcb.getAtom(conn, "WM_TRANSIENT_FOR"),
            .wm_window_role = xcb.getAtom(conn, "WM_WINDOW_ROLE"),
            .wm_state = xcb.getAtom(conn, "WM_STATE"),
            .wm_change_state = xcb.getAtom(conn, "WM_CHANGE_STATE"),

            // Other
            .utf8_string = xcb.getAtom(conn, "UTF8_STRING"),
            .i3_socket_path = xcb.getAtom(conn, "I3_SOCKET_PATH"),
        };
    }

    /// Return the list of atoms we advertise as _NET_SUPPORTED.
    pub fn supportedList(self: *const Atoms) [16]xcb.Atom {
        return .{
            self.net_supported,
            self.net_supporting_wm_check,
            self.net_wm_name,
            self.net_wm_state,
            self.net_wm_state_fullscreen,
            self.net_wm_state_demands_attention,
            self.net_wm_state_hidden,
            self.net_wm_window_type,
            self.net_active_window,
            self.net_current_desktop,
            self.net_number_of_desktops,
            self.net_desktop_names,
            self.net_wm_desktop,
            self.net_client_list,
            self.net_wm_pid,
            self.net_close_window,
        };
    }
};
