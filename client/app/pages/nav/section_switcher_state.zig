//! The section switcher's zx-facing half: the one click handler behind every section control and
//! the small view reads the markup makes. The catalogue, the family rules and the per-side memory
//! are pure and live in ui_state.zig, where `zig build test` proves them (ZX5).

const std = @import("std");
const zx = @import("zx");

const ui = @import("./ui.zig");
const ui_state = @import("./ui_state.zig");
const dom_event = @import("../platform/dom_event.zig");

const log = std.log.scoped(.panels);

pub const Section = ui_state.Section;

pub fn sections(side: ui.Side) []const Section {
    return ui.sectionsFor(side);
}

pub fn navLabel(side: ui.Side) []const u8 {
    return ui.sectionNavLabel(side);
}

/// The section id as its stored/attribute name, which is the same spelling localStorage holds, so
/// the click path and the restore path parse one vocabulary.
pub fn sectionTag(id: ui.PanelId) []const u8 {
    return @tagName(id);
}

/// aria-current for one control: which panel is SHOWING, not which is remembered. A side displaying
/// a panel outside its family (the card editor, opened from a character) marks no section current
/// rather than lighting a control whose body is not on screen.
pub fn currentStr(side: ui.Side, id: ui.PanelId) []const u8 {
    const open = ui.openIdOn(side) orelse return "false";
    return if (open == id) "true" else "false";
}

/// A section control's click. Which section and which side both ride on the button as data, so one
/// handler drives all eight controls; ziex reports currentTarget as the delegation root, so the
/// element is resolved by walking up from the target (ZX11).
pub fn onSection(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const side_str = dom_event.datasetUp(target, "side") orelse return;
    defer zx.allocator.free(side_str);
    const name = dom_event.datasetUp(target, "section") orelse return;
    defer zx.allocator.free(name);
    const side: ui.Side = if (std.mem.eql(u8, side_str, "left")) .left else .right;
    const id = ui_state.sectionFromStr(side, name) orelse {
        log.warn("unknown section on the {s} side: {s}", .{ ui.sideStr(side), name });
        return;
    };
    ui.selectSection(side, id);
}
