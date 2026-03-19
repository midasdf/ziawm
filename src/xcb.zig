// XCB C bindings — thin wrapper around libxcb
const std = @import("std");

pub const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("xcb/randr.h");
    @cInclude("xcb/xkb.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

// --- xkbcommon wrappers ---
pub const xkb_keysym_from_name = c.xkb_keysym_from_name;
pub const xkb_keysym_get_name = c.xkb_keysym_get_name;
pub const XKB_KEYSYM_NO_FLAGS = c.XKB_KEYSYM_NO_FLAGS;
pub const XKB_KEYSYM_CASE_INSENSITIVE = c.XKB_KEYSYM_CASE_INSENSITIVE;

// --- Core types ---
pub const Connection = c.xcb_connection_t;
pub const Window = c.xcb_window_t;
pub const Atom = c.xcb_atom_t;
pub const Keycode = c.xcb_keycode_t;
pub const Keysym = c.xcb_keysym_t;
pub const Timestamp = c.xcb_timestamp_t;
pub const Colormap = c.xcb_colormap_t;
pub const VisualId = c.xcb_visualid_t;
pub const VoidCookie = c.xcb_void_cookie_t;
pub const GenericEvent = c.xcb_generic_event_t;
pub const GenericError = c.xcb_generic_error_t;
pub const Screen = c.xcb_screen_t;
pub const Setup = c.xcb_setup_t;
pub const ScreenIterator = c.xcb_screen_iterator_t;
pub const KeySymbols = c.xcb_key_symbols_t;
pub const InternAtomCookie = c.xcb_intern_atom_cookie_t;
pub const InternAtomReply = c.xcb_intern_atom_reply_t;
pub const GetPropertyCookie = c.xcb_get_property_cookie_t;
pub const GetPropertyReply = c.xcb_get_property_reply_t;
pub const QueryTreeCookie = c.xcb_query_tree_cookie_t;
pub const QueryTreeReply = c.xcb_query_tree_reply_t;
pub const GetGeometryCookie = c.xcb_get_geometry_cookie_t;
pub const GetGeometryReply = c.xcb_get_geometry_reply_t;
pub const GetWindowAttributesCookie = c.xcb_get_window_attributes_cookie_t;
pub const GetWindowAttributesReply = c.xcb_get_window_attributes_reply_t;

// Event types
pub const MapRequestEvent = c.xcb_map_request_event_t;
pub const UnmapNotifyEvent = c.xcb_unmap_notify_event_t;
pub const DestroyNotifyEvent = c.xcb_destroy_notify_event_t;
pub const KeyPressEvent = c.xcb_key_press_event_t;
pub const ButtonPressEvent = c.xcb_button_press_event_t;
pub const EnterNotifyEvent = c.xcb_enter_notify_event_t;
pub const ConfigureRequestEvent = c.xcb_configure_request_event_t;
pub const PropertyNotifyEvent = c.xcb_property_notify_event_t;
pub const ClientMessageEvent = c.xcb_client_message_event_t;
pub const ConfigureNotifyEvent = c.xcb_configure_notify_event_t;
pub const FocusInEvent = c.xcb_focus_in_event_t;

// RandR types
pub const RandrGetScreenResourcesCookie = c.xcb_randr_get_screen_resources_cookie_t;
pub const RandrGetScreenResourcesReply = c.xcb_randr_get_screen_resources_reply_t;
pub const RandrGetOutputInfoCookie = c.xcb_randr_get_output_info_cookie_t;
pub const RandrGetOutputInfoReply = c.xcb_randr_get_output_info_reply_t;
pub const RandrGetCrtcInfoCookie = c.xcb_randr_get_crtc_info_cookie_t;
pub const RandrGetCrtcInfoReply = c.xcb_randr_get_crtc_info_reply_t;
pub const RandrOutput = c.xcb_randr_output_t;
pub const RandrCrtc = c.xcb_randr_crtc_t;

// --- Constants ---
pub const COPY_FROM_PARENT: u32 = 0; // XCB_COPY_FROM_PARENT
pub const CURRENT_TIME: u32 = 0; // XCB_CURRENT_TIME
pub const NONE: u32 = 0; // XCB_NONE
pub const WINDOW_NONE: Window = 0;

// Event masks
pub const EVENT_MASK_NO_EVENT: u32 = c.XCB_EVENT_MASK_NO_EVENT;
pub const EVENT_MASK_KEY_PRESS: u32 = c.XCB_EVENT_MASK_KEY_PRESS;
pub const EVENT_MASK_KEY_RELEASE: u32 = c.XCB_EVENT_MASK_KEY_RELEASE;
pub const EVENT_MASK_BUTTON_PRESS: u32 = c.XCB_EVENT_MASK_BUTTON_PRESS;
pub const EVENT_MASK_ENTER_WINDOW: u32 = c.XCB_EVENT_MASK_ENTER_WINDOW;
pub const EVENT_MASK_LEAVE_WINDOW: u32 = c.XCB_EVENT_MASK_LEAVE_WINDOW;
pub const EVENT_MASK_STRUCTURE_NOTIFY: u32 = c.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
pub const EVENT_MASK_SUBSTRUCTURE_NOTIFY: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
pub const EVENT_MASK_SUBSTRUCTURE_REDIRECT: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
pub const EVENT_MASK_FOCUS_CHANGE: u32 = c.XCB_EVENT_MASK_FOCUS_CHANGE;
pub const EVENT_MASK_PROPERTY_CHANGE: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;

// Event response types
pub const MAP_REQUEST: u8 = c.XCB_MAP_REQUEST;
pub const UNMAP_NOTIFY: u8 = c.XCB_UNMAP_NOTIFY;
pub const DESTROY_NOTIFY: u8 = c.XCB_DESTROY_NOTIFY;
pub const KEY_PRESS: u8 = c.XCB_KEY_PRESS;
pub const ENTER_NOTIFY: u8 = c.XCB_ENTER_NOTIFY;
pub const CONFIGURE_REQUEST: u8 = c.XCB_CONFIGURE_REQUEST;
pub const PROPERTY_NOTIFY: u8 = c.XCB_PROPERTY_NOTIFY;
pub const CLIENT_MESSAGE: u8 = c.XCB_CLIENT_MESSAGE;
pub const CONFIGURE_NOTIFY: u8 = c.XCB_CONFIGURE_NOTIFY;
pub const FOCUS_IN: u8 = c.XCB_FOCUS_IN;
pub const MAPPING_NOTIFY: u8 = c.XCB_MAPPING_NOTIFY;
pub const BUTTON_PRESS: u8 = c.XCB_BUTTON_PRESS;

// Configure window value masks
pub const CONFIG_WINDOW_X: u16 = c.XCB_CONFIG_WINDOW_X;
pub const CONFIG_WINDOW_Y: u16 = c.XCB_CONFIG_WINDOW_Y;
pub const CONFIG_WINDOW_WIDTH: u16 = c.XCB_CONFIG_WINDOW_WIDTH;
pub const CONFIG_WINDOW_HEIGHT: u16 = c.XCB_CONFIG_WINDOW_HEIGHT;
pub const CONFIG_WINDOW_BORDER_WIDTH: u16 = c.XCB_CONFIG_WINDOW_BORDER_WIDTH;
pub const CONFIG_WINDOW_SIBLING: u16 = c.XCB_CONFIG_WINDOW_SIBLING;
pub const CONFIG_WINDOW_STACK_MODE: u16 = c.XCB_CONFIG_WINDOW_STACK_MODE;

// CW (change window attributes) masks
pub const CW_BACK_PIXEL: u32 = c.XCB_CW_BACK_PIXEL;
pub const CW_BORDER_PIXEL: u32 = c.XCB_CW_BORDER_PIXEL;
pub const CW_EVENT_MASK: u32 = c.XCB_CW_EVENT_MASK;
pub const CW_OVERRIDE_REDIRECT: u32 = c.XCB_CW_OVERRIDE_REDIRECT;

// Property modes
pub const PROP_MODE_REPLACE: u8 = c.XCB_PROP_MODE_REPLACE;
pub const PROP_MODE_PREPEND: u8 = c.XCB_PROP_MODE_PREPEND;
pub const PROP_MODE_APPEND: u8 = c.XCB_PROP_MODE_APPEND;

// Atom constants
pub const ATOM_NONE: Atom = c.XCB_ATOM_NONE;
pub const ATOM_ATOM: Atom = c.XCB_ATOM_ATOM;
pub const ATOM_CARDINAL: Atom = c.XCB_ATOM_CARDINAL;
pub const ATOM_STRING: Atom = c.XCB_ATOM_STRING;
pub const ATOM_WINDOW: Atom = c.XCB_ATOM_WINDOW;
pub const ATOM_WM_NAME: Atom = c.XCB_ATOM_WM_NAME;
pub const ATOM_WM_CLASS: Atom = c.XCB_ATOM_WM_CLASS;
pub const ATOM_WM_TRANSIENT_FOR: Atom = c.XCB_ATOM_WM_TRANSIENT_FOR;
pub const ATOM_WM_HINTS: Atom = c.XCB_ATOM_WM_HINTS;
pub const ATOM_WM_NORMAL_HINTS: Atom = c.XCB_ATOM_WM_NORMAL_HINTS;

// Input focus
pub const INPUT_FOCUS_POINTER_ROOT: u8 = c.XCB_INPUT_FOCUS_POINTER_ROOT;
pub const INPUT_FOCUS_PARENT: u8 = c.XCB_INPUT_FOCUS_PARENT;

// Stack mode
pub const STACK_MODE_ABOVE: u32 = c.XCB_STACK_MODE_ABOVE;
pub const STACK_MODE_BELOW: u32 = c.XCB_STACK_MODE_BELOW;

// Grab mode
pub const GRAB_MODE_ASYNC: u8 = c.XCB_GRAB_MODE_ASYNC;

// Map state
pub const MAP_STATE_VIEWABLE: u8 = c.XCB_MAP_STATE_VIEWABLE;

// Send event destination
pub const SEND_EVENT_DEST_POINTER_WINDOW: u32 = c.XCB_SEND_EVENT_DEST_POINTER_WINDOW;
pub const SEND_EVENT_DEST_ITEM_FOCUS: u32 = c.XCB_SEND_EVENT_DEST_ITEM_FOCUS;

// Mod masks
pub const MOD_MASK_SHIFT: u16 = c.XCB_MOD_MASK_SHIFT;
pub const MOD_MASK_LOCK: u16 = c.XCB_MOD_MASK_LOCK;
pub const MOD_MASK_CONTROL: u16 = c.XCB_MOD_MASK_CONTROL;
pub const MOD_MASK_1: u16 = c.XCB_MOD_MASK_1; // Alt
pub const MOD_MASK_2: u16 = c.XCB_MOD_MASK_2;
pub const MOD_MASK_3: u16 = c.XCB_MOD_MASK_3;
pub const MOD_MASK_4: u16 = c.XCB_MOD_MASK_4; // Super
pub const MOD_MASK_5: u16 = c.XCB_MOD_MASK_5;
pub const MOD_MASK_ANY: u16 = c.XCB_MOD_MASK_ANY;
pub const GRAB_ANY: u8 = c.XCB_GRAB_ANY;
pub const BUTTON_INDEX_ANY: u8 = c.XCB_BUTTON_INDEX_ANY;
pub const BUTTON_INDEX_1: u8 = 1;

// RandR connection status
pub const RANDR_CONNECTION_CONNECTED: u32 = c.XCB_RANDR_CONNECTION_CONNECTED;

// RandR notify masks (for xcb_randr_select_input)
pub const RANDR_NOTIFY_MASK_SCREEN_CHANGE: u16 = c.XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE;
pub const RANDR_NOTIFY_MASK_CRTC_CHANGE: u16 = c.XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE;
pub const RANDR_NOTIFY_MASK_OUTPUT_CHANGE: u16 = c.XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE;

// RandR event types
pub const RandrScreenChangeNotifyEvent = c.xcb_randr_screen_change_notify_event_t;

// --- Core functions ---
pub fn connect(display: ?[*:0]const u8, screen: ?*c_int) ?*Connection {
    return c.xcb_connect(display, screen);
}

pub fn disconnect(conn: *Connection) void {
    c.xcb_disconnect(conn);
}

pub fn flush(conn: *Connection) c_int {
    return c.xcb_flush(conn);
}

pub fn waitForEvent(conn: *Connection) ?*GenericEvent {
    return c.xcb_wait_for_event(conn);
}

pub fn pollForEvent(conn: *Connection) ?*GenericEvent {
    return c.xcb_poll_for_event(conn);
}

pub fn getFd(conn: *Connection) c_int {
    return c.xcb_get_file_descriptor(conn);
}

pub fn connectionHasError(conn: *Connection) c_int {
    return c.xcb_connection_has_error(conn);
}

pub fn getSetup(conn: *Connection) *const Setup {
    return c.xcb_get_setup(conn);
}

pub fn setupRootsIterator(setup: *const Setup) ScreenIterator {
    return c.xcb_setup_roots_iterator(setup);
}

pub fn generateId(conn: *Connection) u32 {
    return c.xcb_generate_id(conn);
}

// --- Window operations ---
pub fn mapWindow(conn: *Connection, window: Window) VoidCookie {
    return c.xcb_map_window(conn, window);
}

pub fn unmapWindow(conn: *Connection, window: Window) VoidCookie {
    return c.xcb_unmap_window(conn, window);
}

pub fn configureWindow(conn: *Connection, window: Window, value_mask: u16, value_list: [*]const u32) VoidCookie {
    return c.xcb_configure_window(conn, window, value_mask, value_list);
}

pub fn changeWindowAttributes(conn: *Connection, window: Window, value_mask: u32, value_list: [*]const u32) VoidCookie {
    return c.xcb_change_window_attributes(conn, window, value_mask, value_list);
}

pub fn changeWindowAttributesChecked(conn: *Connection, window: Window, value_mask: u32, value_list: [*]const u32) VoidCookie {
    return c.xcb_change_window_attributes_checked(conn, window, value_mask, value_list);
}

pub fn requestCheck(conn: *Connection, cookie: VoidCookie) ?*GenericError {
    return c.xcb_request_check(conn, cookie);
}

pub fn changeProperty(conn: *Connection, mode: u8, window: Window, property: Atom, prop_type: Atom, format: u8, data_len: u32, data: ?*const anyopaque) VoidCookie {
    return c.xcb_change_property(conn, mode, window, property, prop_type, format, data_len, data);
}

pub fn getProperty(conn: *Connection, delete: u8, window: Window, property: Atom, prop_type: Atom, long_offset: u32, long_length: u32) GetPropertyCookie {
    return c.xcb_get_property(conn, delete, window, property, prop_type, long_offset, long_length);
}

pub fn getPropertyReply(conn: *Connection, cookie: GetPropertyCookie, err: ?*?*GenericError) ?*GetPropertyReply {
    return c.xcb_get_property_reply(conn, cookie, err);
}

pub fn getPropertyValue(reply: *GetPropertyReply) ?*anyopaque {
    return c.xcb_get_property_value(reply);
}

pub fn getPropertyValueLength(reply: *GetPropertyReply) c_int {
    return c.xcb_get_property_value_length(reply);
}

pub fn setInputFocus(conn: *Connection, revert_to: u8, focus: Window, time: Timestamp) VoidCookie {
    return c.xcb_set_input_focus(conn, revert_to, focus, time);
}

pub fn killClient(conn: *Connection, resource: u32) VoidCookie {
    return c.xcb_kill_client(conn, resource);
}

pub fn sendEvent(conn: *Connection, propagate: u8, destination: Window, event_mask: u32, event: [*]const u8) VoidCookie {
    return c.xcb_send_event(conn, propagate, destination, event_mask, event);
}

pub fn queryTree(conn: *Connection, window: Window) QueryTreeCookie {
    return c.xcb_query_tree(conn, window);
}

pub fn queryTreeReply(conn: *Connection, cookie: QueryTreeCookie, err: ?*?*GenericError) ?*QueryTreeReply {
    return c.xcb_query_tree_reply(conn, cookie, err);
}

pub fn queryTreeChildren(reply: *QueryTreeReply) [*]Window {
    return c.xcb_query_tree_children(reply);
}

pub fn queryTreeChildrenLength(reply: *QueryTreeReply) c_int {
    return c.xcb_query_tree_children_length(reply);
}

pub fn getGeometry(conn: *Connection, drawable: u32) GetGeometryCookie {
    return c.xcb_get_geometry(conn, drawable);
}

pub fn getGeometryReply(conn: *Connection, cookie: GetGeometryCookie, err: ?*?*GenericError) ?*GetGeometryReply {
    return c.xcb_get_geometry_reply(conn, cookie, err);
}

pub fn getWindowAttributes(conn: *Connection, window: Window) GetWindowAttributesCookie {
    return c.xcb_get_window_attributes(conn, window);
}

pub fn getWindowAttributesReply(conn: *Connection, cookie: GetWindowAttributesCookie, err: ?*?*GenericError) ?*GetWindowAttributesReply {
    return c.xcb_get_window_attributes_reply(conn, cookie, err);
}

pub fn createWindow(conn: *Connection, depth: u8, wid: Window, parent: Window, x: i16, y: i16, width: u16, height: u16, border_width: u16, class: u16, visual: VisualId, value_mask: u32, value_list: ?[*]const u32) VoidCookie {
    return c.xcb_create_window(conn, depth, wid, parent, x, y, width, height, border_width, class, visual, value_mask, value_list);
}

// --- Atoms ---
pub fn internAtom(conn: *Connection, only_if_exists: u8, name_len: u16, name: [*]const u8) InternAtomCookie {
    return c.xcb_intern_atom(conn, only_if_exists, name_len, name);
}

pub fn internAtomReply(conn: *Connection, cookie: InternAtomCookie, err: ?*?*GenericError) ?*InternAtomReply {
    return c.xcb_intern_atom_reply(conn, cookie, err);
}

// --- Key grabbing ---
pub fn grabKey(conn: *Connection, owner_events: u8, grab_window: Window, modifiers: u16, key: Keycode, pointer_mode: u8, keyboard_mode: u8) VoidCookie {
    return c.xcb_grab_key(conn, owner_events, grab_window, modifiers, key, pointer_mode, keyboard_mode);
}

pub fn ungrabKey(conn: *Connection, key: Keycode, grab_window: Window, modifiers: u16) VoidCookie {
    return c.xcb_ungrab_key(conn, key, grab_window, modifiers);
}

// --- Button grabbing ---
pub fn grabButton(conn: *Connection, owner_events: u8, grab_window: Window, event_mask: u16, pointer_mode: u8, keyboard_mode: u8, confine_to: Window, cursor: u32, button: u8, modifiers: u16) VoidCookie {
    return c.xcb_grab_button(conn, owner_events, grab_window, event_mask, pointer_mode, keyboard_mode, confine_to, cursor, button, modifiers);
}

pub fn ungrabButton(conn: *Connection, button: u8, grab_window: Window, modifiers: u16) VoidCookie {
    return c.xcb_ungrab_button(conn, button, grab_window, modifiers);
}

// --- Key symbols ---
pub fn keySymbolsAlloc(conn: *Connection) ?*KeySymbols {
    return c.xcb_key_symbols_alloc(conn);
}

pub fn keySymbolsFree(syms: *KeySymbols) void {
    c.xcb_key_symbols_free(syms);
}

pub fn keySymbolsGetKeysym(syms: *KeySymbols, keycode: Keycode, col: c_int) Keysym {
    return c.xcb_key_symbols_get_keysym(syms, keycode, col);
}

pub fn keySymbolsGetKeycode(syms: *KeySymbols, keysym: Keysym) ?*Keycode {
    return c.xcb_key_symbols_get_keycode(syms, keysym);
}

// --- RandR ---
pub fn randrGetScreenResources(conn: *Connection, window: Window) RandrGetScreenResourcesCookie {
    return c.xcb_randr_get_screen_resources(conn, window);
}

pub fn randrGetScreenResourcesReply(conn: *Connection, cookie: RandrGetScreenResourcesCookie, err: ?*?*GenericError) ?*RandrGetScreenResourcesReply {
    return c.xcb_randr_get_screen_resources_reply(conn, cookie, err);
}

pub fn randrGetScreenResourcesOutputs(reply: *RandrGetScreenResourcesReply) [*]RandrOutput {
    return c.xcb_randr_get_screen_resources_outputs(reply);
}

pub fn randrGetScreenResourcesOutputsLength(reply: *RandrGetScreenResourcesReply) c_int {
    return c.xcb_randr_get_screen_resources_outputs_length(reply);
}

pub fn randrGetOutputInfo(conn: *Connection, output: RandrOutput, config_timestamp: Timestamp) RandrGetOutputInfoCookie {
    return c.xcb_randr_get_output_info(conn, output, config_timestamp);
}

pub fn randrGetOutputInfoReply(conn: *Connection, cookie: RandrGetOutputInfoCookie, err: ?*?*GenericError) ?*RandrGetOutputInfoReply {
    return c.xcb_randr_get_output_info_reply(conn, cookie, err);
}

pub fn randrGetCrtcInfo(conn: *Connection, crtc: RandrCrtc, config_timestamp: Timestamp) RandrGetCrtcInfoCookie {
    return c.xcb_randr_get_crtc_info(conn, crtc, config_timestamp);
}

pub fn randrGetCrtcInfoReply(conn: *Connection, cookie: RandrGetCrtcInfoCookie, err: ?*?*GenericError) ?*RandrGetCrtcInfoReply {
    return c.xcb_randr_get_crtc_info_reply(conn, cookie, err);
}

pub fn randrSelectInput(conn: *Connection, window: Window, enable: u16) VoidCookie {
    return c.xcb_randr_select_input(conn, window, enable);
}

pub fn randrGetScreenResourcesCurrent(conn: *Connection, window: Window) c.xcb_randr_get_screen_resources_current_cookie_t {
    return c.xcb_randr_get_screen_resources_current(conn, window);
}

pub fn randrGetScreenResourcesCurrentReply(conn: *Connection, cookie: c.xcb_randr_get_screen_resources_current_cookie_t, err: ?*?*GenericError) ?*c.xcb_randr_get_screen_resources_current_reply_t {
    return c.xcb_randr_get_screen_resources_current_reply(conn, cookie, err);
}

pub fn randrGetOutputInfoName(reply: *RandrGetOutputInfoReply) []const u8 {
    const ptr = c.xcb_randr_get_output_info_name(reply);
    const len: usize = @intCast(c.xcb_randr_get_output_info_name_length(reply));
    if (ptr == null or len == 0) return "";
    const data: [*]const u8 = @ptrCast(ptr.?);
    return data[0..len];
}

/// Query RandR extension base event number. Returns 0 on failure.
pub fn randrQueryExtension(conn: *Connection) u8 {
    const reply = c.xcb_get_extension_data(conn, &c.xcb_randr_id);
    if (reply) |r| {
        if (r.*.present != 0) return r.*.first_event;
    }
    return 0;
}

// --- Helpers ---

/// Get the first screen from the connection.
pub fn getScreen(conn: *Connection) ?*Screen {
    const setup = getSetup(conn);
    const iter = setupRootsIterator(setup);
    if (iter.rem > 0) {
        return iter.data;
    }
    return null;
}

/// Intern an atom by name (blocking). Returns ATOM_NONE on failure.
pub fn getAtom(conn: *Connection, name: []const u8) Atom {
    const cookie = internAtom(conn, 0, @intCast(name.len), name.ptr);
    const reply = internAtomReply(conn, cookie, null) orelse return ATOM_NONE;
    defer std.c.free(reply);
    return reply.atom;
}
