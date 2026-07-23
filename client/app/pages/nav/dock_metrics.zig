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
    const style = rootStyle() orelse return;
    defer style.deinit();
    writeOn(style, side, px);
}
