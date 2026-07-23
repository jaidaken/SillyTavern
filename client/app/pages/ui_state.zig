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
    // P1-B
    notifications,
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
    // P1-B
    .{ .id = .notifications, .dom_id = "d-notifications", .icon = "bell", .title = "Notifications", .side = .right },
};

pub const min_width: f32 = 240;
pub const max_width: f32 = 620;
pub const default_width: f32 = 340;

/// Motion policy. `system` honours the OS prefers-reduced-motion (the default); `on`/`off` override
/// it from the in-app setting.
pub const MotionPref = enum { system, on, off };

/// The panel open on each side, and the width of each dock. A plain value: ui.zig holds the single
/// reactive instance; a mutation calls regions.bumpShell to re-render the Shell region only, not the
/// whole page.
///
/// The two sides are INDEPENDENT (hidden-launcher rework, section 2): opening one never closes the
/// other, because the app grid already carries a left, a centre and a right column, so two open docks
/// only narrow the reading column. `last` is which side opened most recently, which is the side
/// Escape closes.
pub const PanelState = struct {
    left: ?PanelId = null,
    right: ?PanelId = null,
    last: ?Side = null,
    left_w: f32 = default_width,
    right_w: f32 = default_width,

    pub fn openId(self: PanelState, side: Side) ?PanelId {
        return if (side == .left) self.left else self.right;
    }

    pub fn isActive(self: PanelState, id: PanelId) bool {
        if (self.left) |l| {
            if (l == id) return true;
        }
        if (self.right) |r| {
            if (r == id) return true;
        }
        return false;
    }

    pub fn anyOpen(self: PanelState) bool {
        return self.left != null or self.right != null;
    }

    /// The left panel when there is one, else the right. Kept for callers that only need "something
    /// is open"; per-side reads should use openOn.
    pub fn activePanel(self: PanelState) ?Panel {
        if (self.openOn(.left)) |p| return p;
        return self.openOn(.right);
    }

    /// The panel currently open on `side`, if any.
    pub fn openOn(self: PanelState, side: Side) ?Panel {
        const id = self.openId(side) orelse return null;
        return panelFor(id);
    }

    /// The open panel that presents as a top-bar drawer rather than a dock. With the icon row gone
    /// nothing opens a drawer any more, so this reads null in the reworked shell.
    pub fn activeDrawer(self: PanelState) ?Panel {
        inline for (.{ Side.left, Side.right }) |side| {
            if (self.openOn(side)) |p| {
                if (p.kind == .drawer) return p;
            }
        }
        return null;
    }

    pub fn widthFor(self: PanelState, side: Side) f32 {
        return if (side == .left) self.left_w else self.right_w;
    }

    /// Open `id` on its own side, or close that side if `id` already holds it. The other side is
    /// untouched.
    pub fn toggle(self: *PanelState, id: PanelId) void {
        const p = panelFor(id) orelse return;
        const open_here = self.openId(p.side) != null and self.openId(p.side).? == id;
        const next: ?PanelId = if (open_here) null else id;
        if (p.side == .left) self.left = next else self.right = next;
        if (next == null) {
            log.debug("close: {s}", .{@tagName(id)});
        } else {
            self.last = p.side;
            log.debug("open: {s}", .{@tagName(id)});
        }
    }

    pub fn closeSide(self: *PanelState, side: Side) void {
        if (self.openId(side)) |prev| log.debug("close: {s}", .{@tagName(prev)});
        if (side == .left) self.left = null else self.right = null;
    }

    /// Escape closes the side that opened most recently, not both.
    pub fn closeLast(self: *PanelState) void {
        const side = self.last orelse (if (self.left != null) Side.left else Side.right);
        self.closeSide(side);
        self.last = if (self.left != null) .left else if (self.right != null) .right else null;
    }

    pub fn close(self: *PanelState) void {
        self.closeSide(.left);
        self.closeSide(.right);
        self.last = null;
    }

    pub fn setWidth(self: *PanelState, side: Side, w: f32) void {
        const c = std.math.clamp(w, min_width, max_width);
        if (side == .left) self.left_w = c else self.right_w = c;
        log.debug("width {s}: {d}", .{ @tagName(side), c });
    }
};

/// The catalogue entry for an id.
pub fn panelFor(id: PanelId) ?Panel {
    for (panels) |p| {
        if (p.id == id) return p;
    }
    return null;
}

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

// ---- the dock width custom properties ---------------------------------------------------------
// A dock's width is published to the document root as one custom property per side, and BOTH the
// panel and its edge tab read that property. One value, two readers: a resize drag writes the
// property once per pointer move and the panel and the tab move together with no re-render, where a
// render-time pixel value froze the tab until the drag ended.

/// The property carrying a side's dock width. Named here so the writer and the two readers below
/// cannot drift apart.
pub fn dockVar(side: Side) []const u8 {
    return if (side == .left) "--dock-w-left" else "--dock-w-right";
}

/// The panel's own inline width. The fallback covers the server render, which runs before any Zig
/// has published a value.
pub fn dockWidthStyle(side: Side) []const u8 {
    return if (side == .left)
        std.fmt.comptimePrint("width:var(--dock-w-left,{d}px)", .{@as(u32, @intFromFloat(default_width))})
    else
        std.fmt.comptimePrint("width:var(--dock-w-right,{d}px)", .{@as(u32, @intFromFloat(default_width))});
}

/// The edge tab's offset from its own screen edge: zero while the side is closed, the dock's live
/// width while it is open, since the tab rides the panel's inner edge.
pub fn tabOffsetStyle(side: Side) []const u8 {
    return if (side == .left) "left:var(--dock-w-left,0px)" else "right:var(--dock-w-right,0px)";
}

/// The value written to the property, e.g. "340px". Rounded, because a subpixel dock edge leaves a
/// seam between the panel border and the tab.
pub fn dockWidthValue(buf: []u8, w: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}px", .{@as(i64, @intFromFloat(@round(w)))}) catch "0px";
}

const testing = std.testing;

test "each side's dock property is read by both its panel width and its tab offset" {
    // The drag writes dockVar; the panel and the tab read it. A rename that reached only one of the
    // three would leave the tab frozen at its old edge, which is the defect this shape exists to kill.
    try testing.expectEqualStrings("--dock-w-left", dockVar(.left));
    try testing.expectEqualStrings("--dock-w-right", dockVar(.right));
    try testing.expectEqualStrings("width:var(--dock-w-left,340px)", dockWidthStyle(.left));
    try testing.expectEqualStrings("width:var(--dock-w-right,340px)", dockWidthStyle(.right));
    try testing.expectEqualStrings("left:var(--dock-w-left,0px)", tabOffsetStyle(.left));
    try testing.expectEqualStrings("right:var(--dock-w-right,0px)", tabOffsetStyle(.right));
    inline for (.{ Side.left, Side.right }) |side| {
        try testing.expect(std.mem.indexOf(u8, dockWidthStyle(side), dockVar(side)) != null);
        try testing.expect(std.mem.indexOf(u8, tabOffsetStyle(side), dockVar(side)) != null);
    }
}

test "a dock width becomes a rounded pixel property value" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("340px", dockWidthValue(&buf, default_width));
    try testing.expectEqualStrings("341px", dockWidthValue(&buf, 340.6));
    try testing.expectEqualStrings("0px", dockWidthValue(&buf, 0));
}

test "toggle opens then closes, and the two sides are independent" {
    var s: PanelState = .{};
    try testing.expect(s.activePanel() == null);
    s.toggle(.ai_config);
    try testing.expect(s.isActive(.ai_config));
    try testing.expect(s.openOn(.left).?.id == .ai_config);
    try testing.expect(s.openOn(.right) == null);
    // The right dock opens alongside it; neither closes the other.
    s.toggle(.characters);
    try testing.expect(s.isActive(.characters));
    try testing.expect(s.isActive(.ai_config));
    try testing.expect(s.openOn(.right).?.id == .characters);
    try testing.expect(s.openOn(.left).?.id == .ai_config);
    // Toggling an open panel closes its own side only.
    s.toggle(.characters);
    try testing.expect(s.openOn(.right) == null);
    try testing.expect(s.openOn(.left).?.id == .ai_config);
    s.close();
    try testing.expect(!s.anyOpen());
}

test "each panel opens on its catalogue side, and Escape closes the last one opened" {
    var s: PanelState = .{};
    // A same-side panel replaces the one already there.
    s.toggle(.ai_config);
    s.toggle(.world_info);
    try testing.expect(s.openOn(.left).?.id == .world_info);
    try testing.expect(!s.isActive(.ai_config));
    // persona and characters both live on the right.
    s.toggle(.persona);
    try testing.expect(s.openOn(.right).?.id == .persona);
    s.toggle(.characters);
    try testing.expect(s.openOn(.right).?.id == .characters);
    try testing.expect(!s.isActive(.persona));
    // The right side opened last, so it is the one Escape takes.
    s.closeLast();
    try testing.expect(s.openOn(.right) == null);
    try testing.expect(s.openOn(.left).?.id == .world_info);
    s.closeLast();
    try testing.expect(!s.anyOpen());
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
