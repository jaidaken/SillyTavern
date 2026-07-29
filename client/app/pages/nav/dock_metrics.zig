//! Publishes a dock's width to the document root as a CSS custom property (ui_state.dockVar).
//!
//! The panel and its edge tab both position off that property, so a resize drag updates ONE value
//! per pointer move and both elements follow at pointer rate with no re-render. Holding the root
//! style object for the duration of a gesture keeps a drag frame down to a single property write.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const ui_state = @import("./ui_state.zig");

/// document.documentElement.style, or null off the client. Caller deinits.
pub fn rootStyle() ?js.Object {
    if (zx.platform.role != .client) return null;
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    const root = doc.get(js.Object, "documentElement") catch return null;
    defer root.deinit();
    return root.get(js.Object, "style") catch null;
}

// Root style is a lifetime singleton: resolve once and keep the handle, so a per-frame slide write is
// a single setProperty, not a fresh document/documentElement/style walk each frame. Never deinit.
var cached_root_style: ?js.Object = null;
fn rootStyleCached() ?js.Object {
    if (cached_root_style) |s| return s;
    const s = rootStyle() orelse return null;
    cached_root_style = s;
    return s;
}

/// Write one side's width through a style object the caller already holds (the drag path).
pub fn writeOn(style: js.Object, side: ui_state.Side, px: f32) void {
    if (zx.platform.role != .client) return;
    var buf: [24]u8 = undefined;
    const value = ui_state.dockWidthValue(&buf, px);
    style.call(void, "setProperty", .{ js.string(ui_state.dockVar(side)), js.string(value) }) catch {};
}

/// Write one side's width, resolving the root style for this call (the state-change path).
pub fn publish(side: ui_state.Side, px: f32) void {
    // ZX2: js.Object is `void` on the server build, so the handle work has to be pruned at comptime.
    if (zx.platform.role != .client) return;
    const style = rootStyleCached() orelse return;
    writeOn(style, side, px);
}

/// Write one side's animated slide offset (px, may be negative) to its --dock-anim property. The panel
/// and its edge tab both transform by this, so the rAF slide moves them as ONE, while --dock-w carries
/// the unanimated width and the tab's resting offset. Zero means fully in place (open) or at the screen
/// edge (closed); a full-width negative (left) or positive (right) is off the edge.
pub fn publishAnim(side: ui_state.Side, px: f32) void {
    if (zx.platform.role != .client) return;
    const style = rootStyleCached() orelse return;
    var buf: [24]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}px", .{@as(i64, @intFromFloat(@round(px)))}) catch "0px";
    const name = if (side == .left) "--dock-anim-left" else "--dock-anim-right";
    style.call(void, "setProperty", .{ js.string(name), js.string(value) }) catch {};
}
