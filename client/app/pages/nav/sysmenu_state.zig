//! PHASE-0 PROTOTYPE, disposable. The system menu's half of the state: whether the popover is open,
//! the background choices it offers, and the two live-preview click paths. Sibling of sysmenu.zx.
//!
//! Both controls apply to the visible page rather than to a saved-then-reloaded setting, which is the
//! whole point of the popover's form (rework section 4): you cannot judge a look through a menu that
//! covers the app.

const std = @import("std");
const zx = @import("zx");

const ui = @import("./ui.zig");
const ui_state = @import("./ui_state.zig");
const regions = @import("../shell/regions.zig");
const appearance = @import("../system/appearance.zig");
const dom_event = @import("../platform/dom_event.zig");

const log = std.log.scoped(.panels);

var open: bool = false;
var bg_choice: usize = 0;

/// The three grounds the popover offers. All sit on the theme's own warm hue, so this is one ramp
/// stepped in lightness, not a second palette. Hex because that is the channel appearance.setVar
/// takes (its other consumer is a colour input, which cannot render oklch).
pub const Swatch = struct { name: []const u8, hex: []const u8 };
pub const swatches = [_]Swatch{
    .{ .name = "Desk", .hex = "#26221d" },
    .{ .name = "Midnight", .hex = "#191612" },
    .{ .name = "Ember", .hex = "#302a22" },
};
pub const swatches_slice: []const Swatch = &swatches;

pub fn isOpen() bool {
    return open;
}

pub fn bgIndex() usize {
    return bg_choice;
}

/// Boot-time open, with no rerender: the ?sysopen flag runs before the first paint.
pub fn setOpen(v: bool) void {
    open = v;
}

/// The gear and its popover ride the same edge the left tab does, so an open Setup dock does not end
/// up with a floating button parked on top of its own controls.
pub fn gearOffset(alloc: std.mem.Allocator) []const u8 {
    const dock: i64 = if (ui.openIdOn(.left) == null) 0 else @intFromFloat(ui.widthFor(.left));
    return std.fmt.allocPrint(alloc, "left:{d}px", .{dock + 12}) catch "left:12px";
}

pub fn onGear(_: zx.client.Event) void {
    open = !open;
    regions.bumpShell();
}

pub fn onClose(_: zx.client.Event) void {
    open = false;
    regions.bumpShell();
}

/// A motion button. ui.selectMotion persists the pick and repaints the #shell class, so the change
/// lands on the visible app while the popover stays open.
pub fn onMotion(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const value = dom_event.datasetUp(target, "motionSet") orelse return;
    defer zx.allocator.free(value);
    const pref = ui_state.motionPrefFromStr(value) orelse return;
    ui.selectMotion(pref);
}

/// A background swatch. appearance.setVar writes the override onto the document root, which is what
/// makes the change visible behind the popover rather than after a reload.
pub fn onSwatch(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const raw = dom_event.datasetUp(target, "bgIndex") orelse return;
    defer zx.allocator.free(raw);
    const idx = std.fmt.parseInt(usize, raw, 10) catch return;
    if (idx >= swatches.len) return;
    bg_choice = idx;
    appearance.setVar("bg", swatches[idx].hex);
    regions.bumpShell();
    log.debug("proto background: {s}", .{swatches[idx].name});
}
