//! Pure UI state model: the panel catalogue, the open/width state, and the motion preference, with
//! no ziex dependency so it is unit-testable in the native `zig build test`. ui.zig wraps this with
//! the reactive `rerender` calls and the DOM event handlers; everything pure lives here.

const std = @import("std");

const log = std.log.scoped(.panels);

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
    // C-CARD
    card_editor,
    // w3-chatmgr
    chat_manager,
    // w3-grp
    groups,
};

pub const Side = enum { left, right };

/// How a panel presents, matching the original front end: a dock is a full-height side panel that
/// reflows the chat (AI config on the left, characters on the right); a drawer drops from the top bar
/// and overlays the content (everything else). See the original's #top-settings-holder.
pub const PanelKind = enum { dock, drawer };

pub const Panel = struct {
    id: PanelId,
    /// The drawer button's element id ("d-<panel>"), read back in ui.onDrawer.
    dom_id: []const u8,
    /// Which glyph the button wears, published as data-icon. The stylesheet keys the mask off it.
    /// A name, not a class: appearance is declared in the markup, never computed here.
    icon: []const u8,
    title: []const u8,
    /// Which side a dock sits on. Ignored for drawer-kind panels.
    side: Side,
    kind: PanelKind = .drawer,
};

pub const panels = [_]Panel{
    .{ .id = .ai_config, .dom_id = "d-ai_config", .icon = "sliders", .title = "AI Response Configuration", .side = .left, .kind = .dock },
    .{ .id = .connections, .dom_id = "d-connections", .icon = "plug", .title = "API Connections", .side = .left },
    .{ .id = .formatting, .dom_id = "d-formatting", .icon = "font", .title = "AI Response Formatting", .side = .left },
    .{ .id = .world_info, .dom_id = "d-world_info", .icon = "book", .title = "World Info", .side = .left },
    .{ .id = .settings, .dom_id = "d-settings", .icon = "cog", .title = "User Settings", .side = .left },
    .{ .id = .backgrounds, .dom_id = "d-backgrounds", .icon = "image", .title = "Backgrounds", .side = .left },
    .{ .id = .extensions, .dom_id = "d-extensions", .icon = "cubes", .title = "Extensions", .side = .right },
    .{ .id = .persona, .dom_id = "d-persona", .icon = "user", .title = "Persona Management", .side = .right, .kind = .dock },
    .{ .id = .characters, .dom_id = "d-characters", .icon = "card", .title = "Character Management", .side = .right, .kind = .dock },
    // C-CARD
    .{ .id = .card_editor, .dom_id = "d-card_editor", .icon = "pencil", .title = "Character Card", .side = .left },
    // w3-chatmgr
    .{ .id = .chat_manager, .dom_id = "d-chat_manager", .icon = "chats", .title = "Chat Management", .side = .right },
    // w3-grp
    .{ .id = .groups, .dom_id = "d-groups", .icon = "users", .title = "Group Chats", .side = .right, .kind = .dock },
};

pub const min_width: f32 = 240;
pub const max_width: f32 = 620;
pub const default_width: f32 = 340;

/// Motion policy. `system` honours the OS prefers-reduced-motion (the default); `on`/`off` override
/// it from the in-app setting.
pub const MotionPref = enum { system, on, off };

/// Which side panel or drawer is open (at most one), and the width of each dock. A plain value:
/// ui.zig holds the single reactive instance; a mutation calls regions.bumpShell to re-render the
/// Shell region only, not the whole page.
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

    /// The dock currently open on `side`, if any. Drawer-kind panels never dock, so they are excluded
    /// here and surface through activeDrawer instead.
    pub fn openOn(self: PanelState, side: Side) ?Panel {
        const p = self.activePanel() orelse return null;
        return if (p.kind == .dock and p.side == side) p else null;
    }

    /// The active panel when it presents as a top-bar drawer rather than a dock.
    pub fn activeDrawer(self: PanelState) ?Panel {
        const p = self.activePanel() orelse return null;
        return if (p.kind == .drawer) p else null;
    }

    pub fn widthFor(self: PanelState, side: Side) f32 {
        return if (side == .left) self.left_w else self.right_w;
    }

    /// Open `id`, or close it if it is already the open panel. At most one panel is open at a time.
    pub fn toggle(self: *PanelState, id: PanelId) void {
        self.active = if (self.isActive(id)) null else id;
        if (self.active) |a| {
            log.debug("open: {s}", .{@tagName(a)});
        } else {
            log.debug("close: {s}", .{@tagName(id)});
        }
    }

    pub fn close(self: *PanelState) void {
        if (self.active) |prev| log.debug("close: {s}", .{@tagName(prev)});
        self.active = null;
    }

    pub fn setWidth(self: *PanelState, side: Side, w: f32) void {
        const c = std.math.clamp(w, min_width, max_width);
        if (side == .left) self.left_w = c else self.right_w = c;
        log.debug("width {s}: {d}", .{ @tagName(side), c });
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

/// Maps "system"/"on"/"off" (the value of a data-motion-set button) to a MotionPref.
pub fn motionPrefFromStr(s: []const u8) ?MotionPref {
    inline for (@typeInfo(MotionPref).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @field(MotionPref, f.name);
    }
    return null;
}

/// Class on #shell that drives the CSS motion switch via :root:has(#shell.motion-*). Empty for
/// `system` so the media query governs.
pub fn motionClass(m: MotionPref) []const u8 {
    return switch (m) {
        .system => "",
        .on => "motion-on",
        .off => "motion-off",
    };
}

pub fn sideStr(side: Side) []const u8 {
    return if (side == .left) "left" else "right";
}

/// Inline width for a dock, e.g. "width:340px". Falls back to the default width on OOM.
pub fn widthStyle(alloc: std.mem.Allocator, w: f32) []const u8 {
    return std.fmt.allocPrint(alloc, "width:{d}px", .{w}) catch
        std.fmt.comptimePrint("width:{d}px", .{@as(u32, @intFromFloat(default_width))});
}

const testing = std.testing;

test "toggle opens then closes, and is exclusive across the two docks" {
    var s: PanelState = .{};
    try testing.expect(s.activePanel() == null);
    s.toggle(.ai_config);
    try testing.expect(s.isActive(.ai_config));
    try testing.expect(s.openOn(.left).?.id == .ai_config);
    try testing.expect(s.openOn(.right) == null);
    // The other dock replaces it and sits on the right.
    s.toggle(.characters);
    try testing.expect(s.isActive(.characters));
    try testing.expect(!s.isActive(.ai_config));
    try testing.expect(s.openOn(.right).?.id == .characters);
    try testing.expect(s.openOn(.left) == null);
    // Toggling the open panel closes it.
    s.toggle(.characters);
    try testing.expect(s.activePanel() == null);
}

test "the middle panels are drawers; ai_config docks left, persona and characters dock right" {
    var s: PanelState = .{};
    const drawers = [_]PanelId{ .connections, .formatting, .world_info, .settings, .backgrounds, .extensions };
    for (drawers) |id| {
        s.toggle(id);
        try testing.expect(s.activeDrawer().?.id == id);
        try testing.expect(s.openOn(.left) == null);
        try testing.expect(s.openOn(.right) == null);
        s.close();
    }
    // ai_config docks on the left; persona and characters dock on the right, one at a time.
    s.toggle(.ai_config);
    try testing.expect(s.activeDrawer() == null);
    try testing.expect(s.openOn(.left).?.id == .ai_config);
    s.toggle(.persona);
    try testing.expect(s.activeDrawer() == null);
    try testing.expect(s.openOn(.right).?.id == .persona);
    s.toggle(.characters);
    try testing.expect(s.openOn(.right).?.id == .characters);
    try testing.expect(!s.isActive(.persona));
}

test "width clamps to the allowed range" {
    var s: PanelState = .{};
    s.setWidth(.left, 10);
    try testing.expectEqual(min_width, s.widthFor(.left));
    s.setWidth(.left, 9999);
    try testing.expectEqual(max_width, s.widthFor(.left));
    s.setWidth(.left, 400);
    try testing.expectEqual(@as(f32, 400), s.widthFor(.left));
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

test "motion pref parses and maps to the right #shell class" {
    try testing.expectEqual(MotionPref.system, motionPrefFromStr("system").?);
    try testing.expectEqual(MotionPref.on, motionPrefFromStr("on").?);
    try testing.expectEqual(MotionPref.off, motionPrefFromStr("off").?);
    try testing.expect(motionPrefFromStr("bogus") == null);
    try testing.expectEqualStrings("", motionClass(.system));
    try testing.expectEqualStrings("motion-on", motionClass(.on));
    try testing.expectEqualStrings("motion-off", motionClass(.off));
}
