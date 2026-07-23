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
const dropdown_nav = @import("./dropdown_nav.zig");
const notifications = @import("./notifications.zig");
const dock_metrics = @import("./dock_metrics.zig");

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

/// Republish both dock widths to the CSS custom properties the panel and its tab position off. A
/// closed side publishes zero, so its tab sits back on the screen edge.
fn syncDocks() void {
    for ([_]Side{ .left, .right }) |side| {
        dock_metrics.publish(side, if (ui.panels.openId(side) == null) 0 else ui.panels.widthFor(side));
    }
}

// Mutations re-render only the Shell region so it reflects the new state.
pub fn toggle(id: PanelId) void {
    ui.panels.toggle(id);
    // Opening the notifications drawer IS the read receipt, so the badge clears as the list is shown.
    // Closing it must not, or a toast arriving while the drawer is open would be marked read unseen.
    if (id == .notifications and ui.panels.isActive(.notifications)) notifications.markAllRead();
    syncDocks();
    regions.bumpShell();
}
pub fn close() void {
    ui.panels.close();
    syncDocks();
    regions.bumpShell();
}
pub fn closeSide(side: Side) void {
    ui.panels.closeSide(side);
    syncDocks();
    regions.bumpShell();
}
pub fn openIdOn(side: Side) ?PanelId {
    return ui.panels.openId(side);
}
pub fn anyOpen() bool {
    return ui.panels.anyOpen();
}
/// Boot-time open with no rerender: the prototype's ?openleft / ?openright flags run before the
/// first paint, so the state has to be in place rather than bumped into place afterwards.
pub fn openQuiet(id: PanelId) void {
    ui.panels.toggle(id);
    syncDocks();
}
pub fn setWidth(side: Side, w: f32) void {
    ui.panels.setWidth(side, w);
    syncDocks();
    regions.bumpShell();
}

pub fn dockWidthStyle(side: Side) []const u8 {
    return ui_state.dockWidthStyle(side);
}
pub fn tabOffsetStyle(side: Side) []const u8 {
    return ui_state.tabOffsetStyle(side);
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

/// The panel head's close button. Both sides can be open, so the click has to say WHICH side it
/// closes; the button carries data-side and the read walks up from the click target.
pub fn onClose(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return close();
    defer target.deinit();
    const side_str = dom_event.datasetUp(target, "side") orelse return close();
    defer zx.allocator.free(side_str);
    if (side_str.len == 0) return close();
    closeSide(if (std.mem.eql(u8, side_str, "left")) .left else .right);
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
    // PROTOTYPE: click-outside dismiss is off (rework section 2). Both docks persist while you type,
    // so only the edge tab and the panel head's close button dismiss one.
    _ = ev;
}

/// Escape closes the open panel: the keyboard equivalent of clicking outside it, so the dismiss is
/// not mouse-only (WD37). An open dropdown menu owns Escape first (the innermost dismissable wins,
/// per the WAI-ARIA layering convention), so this stands down while one is open rather than tearing
/// the whole dock down under it. The check lives here, not in each panel: dropdown.onKey stops a key
/// it consumes, but a panel root that never called onKey would still leave a menu open, and the dock
/// must survive that too. dropdown_nav.zig holds the state because ui.zig cannot import dropdown.zx.
pub fn onPageKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (!ui.panels.anyOpen()) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    if (dropdown_nav.isOpenAny()) return;
    // Escape takes the side that opened most recently, not both at once.
    ui.panels.closeLast();
    regions.bumpShell();
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

// ---- the panel dock drag (ziex, client-only; door delegates pointer via patch-door D5) ---------
// setPointerCapture keeps the drag alive when the cursor leaves the separator (plain delegation
// cannot), so the gesture is Zig, not glue. onResizeKey above is the keyboard twin.

const PanelDrag = struct { start_x: f64, start_w: f64, left: bool, last: ?f64, root_style: js.Object, handle: js.Object };
var panel_drag: ?PanelDrag = null;

/// A left dock widens as the separator moves right; a right dock does the opposite. Clamped to the
/// allowed range and rounded, matching the keyboard path's bounds.
fn panelWidthAt(drag: PanelDrag, cx: f64) f64 {
    const dx = cx - drag.start_x;
    const raw = if (drag.left) drag.start_w + dx else drag.start_w - dx;
    return @round(std.math.clamp(raw, @as(f64, min_width), @as(f64, max_width)));
}

/// Pointerdown on the .panel-resize separator inside #panel-view: capture start geometry + which
/// side, take pointer capture, suppress selection. The panel element is measured here and then
/// released; the gesture itself writes the dock width property, not the panel.
pub fn onResizeDown(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const handle = (target.call(?js.Object, "closest", .{js.string(".panel-resize")}) catch return) orelse return;
    const panel = (handle.call(?js.Object, "closest", .{js.string("#panel-view")}) catch null) orelse {
        handle.deinit();
        return;
    };
    defer panel.deinit();
    ev.preventDefault();
    const side_str = dom_event.datasetUp(handle, "side") orelse {
        handle.deinit();
        return;
    };
    defer zx.allocator.free(side_str);
    const root_style = dock_metrics.rootStyle() orelse {
        handle.deinit();
        return;
    };
    panel_drag = .{
        .start_x = dom_event.eventNum(ev, "clientX") orelse 0,
        .start_w = dom_event.rectWidth(panel) orelse 0,
        .left = std.mem.eql(u8, side_str, "left"),
        .last = null,
        .root_style = root_style,
        .handle = handle,
    };
    dom_event.addClass(handle, "is-dragging");
    if (dom_event.eventNum(ev, "pointerId")) |pid| handle.call(void, "setPointerCapture", .{pid}) catch {};
    dom_event.setBodyUserSelect(true);
    dom_event.setPtrDrag(true);
}

/// Pointermove: write the new dock width to its custom property (no rerender until release). The
/// panel sizes off that property and the edge tab offsets off it, so both track the pointer from one
/// write; a render-time pixel value would leave the tab parked at its old edge until the drag ended.
pub fn onResizeMove(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const drag = panel_drag orelse return;
    const cx = dom_event.eventNum(ev, "clientX") orelse return;
    const w = panelWidthAt(drag, cx);
    panel_drag.?.last = w;
    dock_metrics.writeOn(drag.root_style, if (drag.left) .left else .right, @floatCast(w));
}

pub fn onResizeUp(ev: zx.client.Event) void {
    endPanelDrag(ev);
}

pub fn onResizeCancel(ev: zx.client.Event) void {
    endPanelDrag(ev);
}

/// Pointerup/cancel: hand the final width to setWidth (clamps, republishes the property, rerenders),
/// and clear the drag state. The property already holds the dragged value, so the commit changes
/// nothing visible and the release cannot jump.
fn endPanelDrag(_: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const drag = panel_drag orelse return;
    panel_drag = null;
    defer drag.root_style.deinit();
    defer drag.handle.deinit();
    dom_event.removeClass(drag.handle, "is-dragging");
    dom_event.setBodyUserSelect(false);
    dom_event.setPtrDrag(false);
    if (drag.last) |w| {
        setWidth(if (drag.left) .left else .right, @floatCast(w));
        log.debug("panel width set: {d}", .{@as(i64, @intFromFloat(w))});
    }
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
