//! The system card's pure model: the three groups the gear reaches, their labels, and the one
//! storage vocabulary the click path and the restore path both parse.
//!
//! zx-free on purpose, so `zig build test` proves it (ZX5). sysmenu_state.zig holds the reactive
//! half (the open flag, the handlers, the localStorage calls) and reads its rules from here, the
//! same split ui_state.zig / ui.zig already use for the drawer switcher.

const std = @import("std");
const testing = std.testing;

/// The three groups. `look` leads because it is what the card's whole form exists for: its controls
/// repaint the page that stays visible behind the open card.
pub const SysSection = enum { look, settings, extensions };

pub const SectionInfo = struct { id: SysSection, label: []const u8 };

/// The catalogue. The switcher renders this table, so a section added here grows the control row
/// with no markup edit (WD31).
pub const sections = [_]SectionInfo{
    .{ .id = .look, .label = "Look" },
    .{ .id = .settings, .label = "Settings" },
    .{ .id = .extensions, .label = "Extensions" },
};
pub const sections_slice: []const SectionInfo = &sections;

pub const default_section: SysSection = .look;

/// The localStorage key holding the last section shown, the twin of ui.zig's per-side section keys.
pub const section_key = "st-sys-section";

/// The section id as its stored and attribute spelling. One vocabulary: what a button carries is
/// what localStorage holds is what sectionFromStr parses.
pub fn sectionTag(id: SysSection) []const u8 {
    return @tagName(id);
}

/// A stored or clicked section name back to its id, or null when the value names no section. A junk
/// value therefore leaves the card on its default rather than opening it on nothing.
pub fn sectionFromStr(name: []const u8) ?SysSection {
    for (sections) |s| {
        if (std.mem.eql(u8, @tagName(s.id), name)) return s.id;
    }
    return null;
}

/// The label for one section, for the card heading and for anything naming the current group.
pub fn labelFor(id: SysSection) []const u8 {
    for (sections) |s| {
        if (s.id == id) return s.label;
    }
    return "";
}

/// The switcher's accessible name (WD38): the row is a nav, so it needs one of its own.
pub fn navLabel() []const u8 {
    return "System sections";
}

test "the catalogue covers every section exactly once" {
    var seen = std.EnumSet(SysSection).initEmpty();
    for (sections) |s| {
        try testing.expect(!seen.contains(s.id));
        seen.insert(s.id);
        try testing.expect(s.label.len > 0);
    }
    try testing.expectEqual(@as(usize, @typeInfo(SysSection).@"enum".fields.len), seen.count());
    try testing.expectEqual(@as(usize, 3), sections_slice.len);
}

test "a section round-trips through its stored spelling" {
    for (sections) |s| {
        try testing.expectEqual(s.id, sectionFromStr(sectionTag(s.id)).?);
    }
    try testing.expectEqualStrings("look", sectionTag(.look));
    try testing.expectEqualStrings("extensions", sectionTag(.extensions));
}

test "an unknown stored value names no section" {
    try testing.expectEqual(@as(?SysSection, null), sectionFromStr(""));
    try testing.expectEqual(@as(?SysSection, null), sectionFromStr("Look"));
    try testing.expectEqual(@as(?SysSection, null), sectionFromStr("ai_config"));
    try testing.expectEqual(@as(?SysSection, null), sectionFromStr("looks"));
}

test "every section has a label and the default is the live-preview one" {
    try testing.expectEqualStrings("Look", labelFor(.look));
    try testing.expectEqualStrings("Settings", labelFor(.settings));
    try testing.expectEqualStrings("Extensions", labelFor(.extensions));
    try testing.expectEqual(SysSection.look, default_section);
    try testing.expectEqualStrings("st-sys-section", section_key);
}
