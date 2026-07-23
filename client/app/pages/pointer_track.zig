//! Ambient pointer tracking: the client half of the edge-tab reveal.
//!
//! The door reports a pointer position once per animation frame through __st_pointer_move
//! (patch-door D11), which is a listener of its own rather than the gated delegation path: delegated
//! pointermove stores a jsz slot per dispatch and never reclaims it (the reason for door D6), while
//! this crosses four numbers and allocates nothing. Nothing is rendered to sense the pointer, so no
//! element takes a click for the reveal's sake.
//!
//! The zone arithmetic lives in reveal_zone.zig (natively tested); this file owns the DOM
//! measurement and the re-render on a crossing.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const reveal_zone = @import("./reveal_zone.zig");
const ui_state = @import("./ui_state.zig");
const regions = @import("./regions.zig");

var left_in: bool = false;
var right_in: bool = false;

/// True while the pointer sits in that side's flank. Read during render; never mutates.
pub fn revealed(side: ui_state.Side) bool {
    return if (side == .left) left_in else right_in;
}

fn rectEdge(sel: []const u8, comptime edge: []const u8) ?f64 {
    if (zx.platform.role != .client) return null;
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    const el = (doc.call(?js.Object, "querySelector", .{js.string(sel)}) catch null) orelse return null;
    defer el.deinit();
    const rect = el.call(js.Object, "getBoundingClientRect", .{}) catch return null;
    defer rect.deinit();
    return rect.get(f64, edge) catch null;
}

/// The chrome is measured on every pointer frame, never cached: the composer's top edge moves each
/// time a multi-line message grows the input, and a cache keyed on viewport size would keep the old
/// bound through that growth and let the band drift from the visible layout. The door already
/// coalesces pointermove to one call per animation frame, so this is at most one rect read per frame
/// and only while the pointer is moving.
fn zoneNow(w: f64, h: f64) reveal_zone.Zone {
    return reveal_zone.zoneFor(w, h, rectEdge("#topbar", "bottom"), rectEdge("#composer", "top"));
}

/// One coalesced pointer position from the door. (-1, -1) means the pointer left the window, which
/// falls in neither band and fades whichever tab was showing.
pub export fn __st_pointer_move(x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    if (zx.platform.role != .client) return;
    if (w <= 0 or h <= 0) return;
    const z = zoneNow(w, h);
    const l = z.contains(.left, x, y);
    const r = z.contains(.right, x, y);
    // Only a crossing costs a render; a pointer moving inside one band changes nothing.
    if (l == left_in and r == right_in) return;
    left_in = l;
    right_in = r;
    regions.bumpShell();
}
