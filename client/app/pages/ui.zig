//! Reactive glue over the pure ui_state model: holds the single global PanelState, rerenders after
//! each mutation (the same pattern store.zig uses), and reads the clicked drawer button from the DOM
//! event. The state model and all pure helpers live in ui_state.zig so they are natively testable;
//! this file only adds the ziex-facing parts, which are covered by client/verify.sh in a browser.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;
const ui_state = @import("./ui_state.zig");

pub const PanelId = ui_state.PanelId;
pub const Side = ui_state.Side;
pub const Panel = ui_state.Panel;
pub const panels = ui_state.panels;
pub const min_width = ui_state.min_width;
pub const max_width = ui_state.max_width;

var state: ui_state.PanelState = .{};

// Read-only views the components use during render; no rerender, so they are safe to call anywhere.
pub fn isActive(id: PanelId) bool {
    return state.isActive(id);
}
pub fn activePanel() ?Panel {
    return state.activePanel();
}
pub fn openOn(side: Side) ?Panel {
    return state.openOn(side);
}
pub fn activeDropdown() ?Panel {
    return state.activeDropdown();
}
pub fn widthFor(side: Side) f32 {
    return state.widthFor(side);
}

// Mutations rerender so the shell reflects the new state.
pub fn toggle(id: PanelId) void {
    state.toggle(id);
    zx.client.rerender();
}
pub fn close() void {
    state.close();
    zx.client.rerender();
}
pub fn setWidth(side: Side, w: f32) void {
    state.setWidth(side, w);
    zx.client.rerender();
}

pub fn widthStyle(alloc: std.mem.Allocator, side: Side) []const u8 {
    return ui_state.widthStyle(alloc, state.widthFor(side));
}
pub fn sideClass(side: Side) []const u8 {
    return ui_state.sideClass(side);
}
pub fn sideStr(side: Side) []const u8 {
    return ui_state.sideStr(side);
}
pub fn drawerClass(alloc: std.mem.Allocator, id: PanelId, icon: []const u8) []const u8 {
    return ui_state.drawerClass(alloc, state.isActive(id), icon);
}

/// Drawer button click. Reads the clicked button's element id and toggles its panel. One handler
/// drives every button; which panel it is comes from the id, not a per-button function.
pub fn onDrawer(ev: zx.client.Event) void {
    // `ref` is void on the server render build; the check is comptime, so that path is pruned there.
    if (zx.platform.role != .client) return;
    const target = ev.getEvent().ref.get(js.Object, "target") catch return;
    const id = target.getAlloc(js.String, zx.allocator, "id") catch return;
    defer zx.allocator.free(id);
    if (ui_state.panelIdFromDomId(id)) |panel_id| toggle(panel_id);
}

pub fn onClose(_: zx.client.Event) void {
    close();
}

/// Called from the resize glue with the new pixel width for a side. Clamps and rerenders.
export fn __st_set_panel_width(is_left: u32, width: f64) callconv(.c) void {
    setWidth(if (is_left != 0) .left else .right, @floatCast(width));
}

/// Called from the glue to dismiss the open panel (used for click-outside on a dropdown).
export fn __st_close_panel() callconv(.c) void {
    close();
}
