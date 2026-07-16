//! Reactive glue over the pure ui_state model: holds the single global PanelState, re-renders the
//! Shell region after each mutation (regions.bumpShell, so a panel toggle never rebuilds MessageLog
//! or Composer), and reads the clicked drawer button from the DOM event. The state model and all
//! pure helpers live in ui_state.zig so they are natively testable; this file only adds the
//! ziex-facing parts, which are covered by client/verify.sh in a browser.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;
const ui_state = @import("./ui_state.zig");
const regions = @import("./regions.zig");
const dom_event = @import("./dom_event.zig");

const log = std.log.scoped(.panels);

pub const PanelId = ui_state.PanelId;
pub const Side = ui_state.Side;
pub const Panel = ui_state.Panel;
pub const MotionPref = ui_state.MotionPref;
pub const panels = ui_state.panels;
pub const min_width = ui_state.min_width;
pub const max_width = ui_state.max_width;

/// The single reactive UI state: which panel is open with its dock widths, plus the motion pref.
/// ui.zig holds the one instance; ui_state.zig owns the pure model and helpers.
const Ui = struct {
    panels: ui_state.PanelState = .{},
    motion: ui_state.MotionPref = .system,
};
var ui: Ui = .{};

// Read-only views the components use during render; no rerender, so they are safe to call anywhere.
pub fn isActive(id: PanelId) bool {
    return ui.panels.isActive(id);
}
pub fn activePanel() ?Panel {
    return ui.panels.activePanel();
}
pub fn openOn(side: Side) ?Panel {
    return ui.panels.openOn(side);
}
pub fn activeDrawer() ?Panel {
    return ui.panels.activeDrawer();
}
pub fn widthFor(side: Side) f32 {
    return ui.panels.widthFor(side);
}
pub fn motionClass() []const u8 {
    return ui_state.motionClass(ui.motion);
}

// Mutations re-render only the Shell region so it reflects the new state.
pub fn toggle(id: PanelId) void {
    ui.panels.toggle(id);
    regions.bumpShell();
}
pub fn close() void {
    ui.panels.close();
    regions.bumpShell();
}
pub fn setWidth(side: Side, w: f32) void {
    ui.panels.setWidth(side, w);
    regions.bumpShell();
}

pub fn widthStyle(alloc: std.mem.Allocator, side: Side) []const u8 {
    return ui_state.widthStyle(alloc, ui.panels.widthFor(side));
}
pub fn sideStr(side: Side) []const u8 {
    return ui_state.sideStr(side);
}

/// Drawer button click. Reads the clicked button's element id and toggles its panel. One handler
/// drives every button; which panel it is comes from the id, not a per-button function.
pub fn onDrawer(ev: zx.client.Event) void {
    // `ref` is void on the server render build; the check is comptime, so that path is pruned there.
    if (zx.platform.role != .client) return;
    // target, not currentTarget: ziex calls this after native dispatch ends, when currentTarget is
    // already null. The button is empty (icon is a ::before pseudo), so target is always the button.
    const button = ev.getEvent().ref.get(js.Object, "target") catch return;
    const id = button.getAlloc(js.String, zx.allocator, "id") catch return;
    defer zx.allocator.free(id);
    if (ui_state.panelIdFromDomId(id)) |panel_id| toggle(panel_id);
}

pub fn onClose(_: zx.client.Event) void {
    close();
}

/// A click anywhere dismisses the open panel, unless it landed inside the panel itself or on the
/// drawer buttons (whose own handler is toggling that panel on this very click). ziex dispatches a
/// delegated event to EVERY ancestor handler on the path, so this fires alongside the button
/// handlers, and the membership test is what stops a drawer button from closing what it just
/// opened. Bound on the three hydrated region roots (Shell, MessageLog, Composer): the SSR page root
/// carries no client handler, so a handler there would never fire. Owner of the behaviour the glue's
/// document listener used to hold.
pub fn onPageClick(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (ui.panels.active == null) return;
    const target = dom_event.plainTarget(ev) orelse return;
    // A control inside the panel (a dropdown option) rerenders itself away on this same click, and
    // this handler runs after it, so the membership tests below would walk a detached node and read
    // an inside click as an outside one. A click the panel already consumed never dismisses it.
    if (!dom_event.isConnected(target)) return;
    if (dom_event.hasAncestorId(target, "panel-view")) return;
    if (dom_event.hasAncestorClass(target, "drawers")) return;
    close();
}

/// Escape closes the open panel: the keyboard equivalent of clicking outside it, so the dismiss is
/// not mouse-only (WD37).
pub fn onPageKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (ui.panels.active == null) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    close();
}

/// Keyboard resize on a focused panel separator (WCAG 2.1.1, the pointer gesture's twin): arrows
/// step the dock 16px wider or narrower, Home returns it to the default. Which arrow widens depends
/// on the side the dock is docked to, so the separator always moves with the key.
pub fn onResizeKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    const target = dom_event.plainTarget(ev) orelse return;
    const side_str = dom_event.datasetUp(target, "side") orelse return;
    defer zx.allocator.free(side_str);
    const side: Side = if (std.mem.eql(u8, side_str, "left")) .left else .right;

    const step: f32 = 16;
    // A left dock grows to the right; a right dock grows to the left.
    const grow: f32 = if (side == .left) step else -step;
    const current = widthFor(side);
    if (std.mem.eql(u8, key, "ArrowRight")) {
        setWidth(side, current + grow);
    } else if (std.mem.eql(u8, key, "ArrowLeft")) {
        setWidth(side, current - grow);
    } else if (std.mem.eql(u8, key, "ArrowUp")) {
        setWidth(side, current + step);
    } else if (std.mem.eql(u8, key, "ArrowDown")) {
        setWidth(side, current - step);
    } else if (std.mem.eql(u8, key, "Home")) {
        setWidth(side, ui_state.default_width);
    } else {
        return;
    }
    // The keys resized the dock; they must not also scroll the panel behind it.
    ev.preventDefault();
    log.debug("panel {s} resized by key: {s}", .{ ui_state.sideStr(side), key });
}

/// Called from the resize glue with the new pixel width for a side. Clamps and re-renders the Shell
/// region, which re-publishes aria-valuenow on the separator from the clamped state.
pub export fn __st_set_panel_width(is_left: u32, width: f64) callconv(.c) void {
    setWidth(if (is_left != 0) .left else .right, @floatCast(width));
}

/// The motion preference. `set` is the boot path (the value already came from storage); `select` is
/// the click path, which persists it. Zig owns both the stored value and the #shell class the CSS
/// switches on, so the glue holds no motion state at all.
pub fn setMotion(pref: MotionPref) void {
    ui.motion = pref;
    regions.bumpShell();
}

pub fn motionPref() MotionPref {
    return ui.motion;
}

pub fn selectMotion(pref: MotionPref) void {
    storeMotion(pref);
    setMotion(pref);
}

fn storeMotion(pref: MotionPref) void {
    if (zx.platform.role != .client) return;
    const ls = js.global.get(js.Object, "localStorage") catch return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string("st-motion"), js.string(@tagName(pref)) }) catch {
        log.warn("localStorage write refused: st-motion", .{});
    };
}

/// The persisted motion preference, read once at boot. Falls back to `system` when nothing is
/// stored or the stored value is junk.
pub fn storedMotion() MotionPref {
    if (zx.platform.role != .client) return .system;
    const ls = js.global.get(js.Object, "localStorage") catch return .system;
    defer ls.deinit();
    const raw = ls.callAlloc(?js.String, zx.allocator, "getItem", .{js.string("st-motion")}) catch return .system;
    const value = raw orelse return .system;
    defer zx.allocator.free(value);
    return ui_state.motionPrefFromStr(value) orelse .system;
}
