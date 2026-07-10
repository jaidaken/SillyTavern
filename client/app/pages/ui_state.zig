//! Pure UI state model: the panel catalogue and the open/width state, with no ziex dependency so it
//! is unit-testable in the native `zig build test`. ui.zig wraps this with the reactive `rerender`
//! calls and the DOM event handlers; everything that can be pure logic lives here.

const std = @import("std");

pub const PanelId = enum {
    ai_config,
    connections,
    formatting,
    world_info,
    settings,
    backgrounds,
    extensions,
    persona,
    characters,
};

pub const Side = enum { left, right };

/// How a panel presents. A dock is a full-height side panel that reflows the chat; a dropdown is a
/// small menu that drops from the top bar and overlays the content (like the original's wand menu).
pub const PanelKind = enum { dock, dropdown };

pub const Panel = struct {
    id: PanelId,
    /// The drawer button's element id ("d-<panel>"), read back in ui.onDrawer.
    dom_id: []const u8,
    /// CSS class selecting the button's ::before mask icon.
    icon: []const u8,
    title: []const u8,
    side: Side,
    kind: PanelKind = .dock,
};

pub const panels = [_]Panel{
    .{ .id = .ai_config, .dom_id = "d-ai_config", .icon = "i-sliders", .title = "AI Response Configuration", .side = .left },
    .{ .id = .connections, .dom_id = "d-connections", .icon = "i-plug", .title = "API Connections", .side = .left },
    .{ .id = .formatting, .dom_id = "d-formatting", .icon = "i-font", .title = "AI Response Formatting", .side = .left },
    .{ .id = .world_info, .dom_id = "d-world_info", .icon = "i-book", .title = "World Info", .side = .left },
    .{ .id = .settings, .dom_id = "d-settings", .icon = "i-cog", .title = "User Settings", .side = .left },
    .{ .id = .backgrounds, .dom_id = "d-backgrounds", .icon = "i-image", .title = "Backgrounds", .side = .left },
    .{ .id = .extensions, .dom_id = "d-extensions", .icon = "i-cubes", .title = "Extensions", .side = .right, .kind = .dropdown },
    .{ .id = .persona, .dom_id = "d-persona", .icon = "i-user", .title = "Persona Management", .side = .right },
    .{ .id = .characters, .dom_id = "d-characters", .icon = "i-card", .title = "Character Management", .side = .right },
};

pub const min_width: f32 = 240;
pub const max_width: f32 = 620;
pub const default_width: f32 = 340;

/// Which side panel is open (at most one), and the width of each dock. A plain value: ui.zig holds
/// the single reactive instance and rerenders after each mutation.
pub const PanelState = struct {
    active: ?PanelId = null,
    left_w: f32 = default_width,
    right_w: f32 = default_width,

    pub fn isActive(self: PanelState, id: PanelId) bool {
        return self.active != null and self.active.? == id;
    }

    pub fn activePanel(self: PanelState) ?Panel {
        const a = self.active orelse return null;
        for (panels) |p| {
            if (p.id == a) return p;
        }
        return null;
    }

    /// The dock currently open on `side`, if any. Dropdown-kind panels never dock, so they are
    /// excluded here and surface through activeDropdown instead.
    pub fn openOn(self: PanelState, side: Side) ?Panel {
        const p = self.activePanel() orelse return null;
        return if (p.kind == .dock and p.side == side) p else null;
    }

    /// The active panel when it presents as a top-bar dropdown rather than a dock.
    pub fn activeDropdown(self: PanelState) ?Panel {
        const p = self.activePanel() orelse return null;
        return if (p.kind == .dropdown) p else null;
    }

    pub fn widthFor(self: PanelState, side: Side) f32 {
        return if (side == .left) self.left_w else self.right_w;
    }

    /// Open `id`, or close it if it is already the open panel. At most one panel is open at a time.
    pub fn toggle(self: *PanelState, id: PanelId) void {
        self.active = if (self.isActive(id)) null else id;
    }

    pub fn close(self: *PanelState) void {
        self.active = null;
    }

    pub fn setWidth(self: *PanelState, side: Side, w: f32) void {
        const c = std.math.clamp(w, min_width, max_width);
        if (side == .left) self.left_w = c else self.right_w = c;
    }
};

/// Maps "d-<panel>" (a drawer button id) to its PanelId. Returns null for anything unrecognised.
pub fn panelIdFromDomId(id: []const u8) ?PanelId {
    if (!std.mem.startsWith(u8, id, "d-")) return null;
    const name = id[2..];
    inline for (@typeInfo(PanelId).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return @field(PanelId, f.name);
    }
    return null;
}

pub fn sideClass(side: Side) []const u8 {
    return if (side == .left) "panel panel-left" else "panel panel-right";
}

pub fn sideStr(side: Side) []const u8 {
    return if (side == .left) "left" else "right";
}

/// Inline width for a dock, e.g. "width:340px". Falls back to the default width on OOM.
pub fn widthStyle(alloc: std.mem.Allocator, w: f32) []const u8 {
    return std.fmt.allocPrint(alloc, "width:{d}px", .{w}) catch "width:340px";
}

/// Drawer button class: the icon class, plus "is-open" when its panel is active. Falls back to the
/// bare icon on OOM.
pub fn drawerClass(alloc: std.mem.Allocator, is_open: bool, icon: []const u8) []const u8 {
    if (!is_open) return icon;
    return std.fmt.allocPrint(alloc, "{s} is-open", .{icon}) catch icon;
}

const testing = std.testing;

test "toggle opens then closes, and is exclusive across sides" {
    var s: PanelState = .{};
    try testing.expect(s.activePanel() == null);
    s.toggle(.settings);
    try testing.expect(s.isActive(.settings));
    try testing.expect(s.openOn(.left).?.id == .settings);
    try testing.expect(s.openOn(.right) == null);
    // A different panel replaces the open one.
    s.toggle(.characters);
    try testing.expect(s.isActive(.characters));
    try testing.expect(!s.isActive(.settings));
    try testing.expect(s.openOn(.right).?.id == .characters);
    try testing.expect(s.openOn(.left) == null);
    // Toggling the open panel closes it.
    s.toggle(.characters);
    try testing.expect(s.activePanel() == null);
}

test "a dropdown-kind panel surfaces through activeDropdown, never as a dock" {
    var s: PanelState = .{};
    s.toggle(.extensions);
    try testing.expect(s.isActive(.extensions));
    // Extensions is a dropdown, so it never docks on either side.
    try testing.expect(s.openOn(.left) == null);
    try testing.expect(s.openOn(.right) == null);
    try testing.expect(s.activeDropdown().?.id == .extensions);
    // A dock-kind panel does not surface as a dropdown.
    s.toggle(.settings);
    try testing.expect(s.activeDropdown() == null);
    try testing.expect(s.openOn(.left).?.id == .settings);
}

test "width clamps to the allowed range" {
    var s: PanelState = .{};
    s.setWidth(.left, 10);
    try testing.expectEqual(min_width, s.widthFor(.left));
    s.setWidth(.left, 9999);
    try testing.expectEqual(max_width, s.widthFor(.left));
    s.setWidth(.left, 400);
    try testing.expectEqual(@as(f32, 400), s.widthFor(.left));
    // The other side is independent.
    try testing.expectEqual(default_width, s.widthFor(.right));
}

test "every panel id has a matching data entry with a d- dom id that round-trips" {
    inline for (@typeInfo(PanelId).@"enum".fields) |f| {
        const id = @field(PanelId, f.name);
        var found = false;
        for (panels) |p| {
            if (p.id == id) {
                found = true;
                try testing.expect(std.mem.startsWith(u8, p.dom_id, "d-"));
                try testing.expectEqualStrings(f.name, p.dom_id[2..]);
                try testing.expectEqual(id, panelIdFromDomId(p.dom_id).?);
            }
        }
        try testing.expect(found);
    }
}

test "panelIdFromDomId rejects unknown or unprefixed ids" {
    try testing.expect(panelIdFromDomId("d-nonesuch") == null);
    try testing.expect(panelIdFromDomId("settings") == null);
    try testing.expect(panelIdFromDomId("") == null);
    try testing.expectEqual(PanelId.settings, panelIdFromDomId("d-settings").?);
}
