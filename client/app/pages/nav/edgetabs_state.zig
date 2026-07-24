//! The edge tabs' half of the state: where the tab sits, whether it shows, and the two click
//! handlers. The pure panel model it drives lives in ui_state.zig (natively tested); this file is
//! the zx-facing sibling of edgetabs.zx.
//!
//! A tab names no panel any more. It opens its side on the section that side last showed (ui_state's
//! per-side memory, restored from localStorage at boot) and the switcher inside the open drawer
//! moves between the family's four; pinning one panel per side is what left the other eleven with no
//! way in.

const std = @import("std");
const zx = @import("zx");

const ui = @import("./ui.zig");
const proto_flags = @import("../system/proto_flags.zig");
const pointer_track = @import("./pointer_track.zig");

/// The tab rides the inner edge of its own dock, so an open panel does not swallow its own handle.
/// It offsets off the side's dock custom property rather than a rendered pixel value, which is what
/// lets it track the panel edge continuously through a resize drag instead of jumping on release.
pub fn tabOffset(side: ui.Side) []const u8 {
    return ui.tabOffsetStyle(side);
}

/// Naming per rework section 5: the app's cast and its setup, not "Settings" and "Chat". One
/// spelling, in ui_state, shared with the switcher's accessible name.
pub fn tabLabel(side: ui.Side) []const u8 {
    return ui.familyLabel(side);
}

pub fn tabExpanded(side: ui.Side) []const u8 {
    return if (ui.openIdOn(side) == null) "false" else "true";
}

/// A closed side's tab is hidden until the pointer enters that side's flank (pointer_track.zig owns
/// the zone); an open side's tab is the standing close affordance. ?showtabs pins both for a still
/// frame, since a headless screenshot moves no pointer.
pub fn tabShown(side: ui.Side) bool {
    return proto_flags.tabsForced() or ui.openIdOn(side) != null or pointer_track.revealed(side);
}

pub fn onSetupTab(_: zx.client.Event) void {
    ui.toggleSide(.left);
}

pub fn onCastTab(_: zx.client.Event) void {
    ui.toggleSide(.right);
}
