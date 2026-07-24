//! Pure model for the command palette: the jump-target catalogue, the query filter, the highlight
//! index and the open flag. zx-free, so `zig build test` proves it (ZX5). palette_state.zig holds
//! the DOM, focus and region plumbing; palette.zx holds the markup and the activation, which is the
//! only part that needs ui.zig.
//!
//! The section targets are DERIVED at comptime from ui_state's two per-side tables rather than
//! restated, so a section added there appears in the palette with no edit here (WD31). Only the
//! search aliases and the non-section entries are written out.
//!
//! The open flag lives here rather than in the zx half for the same reason dropdown_nav.zig holds
//! the menu's: ui.zig owns the page-level Escape and cannot import a .zx, so a flag parked there
//! would be unreadable to the guard that has to stand down while the palette is up.

const std = @import("std");
const ui_state = @import("./ui_state.zig");
const nav = @import("./dropdown_nav.zig");

pub const Kind = enum {
    /// Show a family section in its side's drawer, exactly as its switcher control would.
    section,
    /// Open the system popover (the gear's card), which is where the app's own settings live.
    system,
};

pub const Target = struct {
    kind: Kind,
    /// The family word the row prints above its label. "Setup" / "Cast" come from ui_state, so the
    /// palette says the same word the tab and the switcher say.
    group: []const u8,
    label: []const u8,
    /// Search-only aliases: matched, never rendered. They carry the words a user actually types
    /// ("sampler", "temperature") for a section whose control reads "AI".
    keywords: []const u8 = "",
    side: ui_state.Side = .left,
    panel: ui_state.PanelId = .ai_config,
};

/// What a user might type looking for a section, beyond its own label. Anything not listed searches
/// on its label and family word alone, which is why this is an open switch rather than exhaustive:
/// a section added to ui_state still reaches the palette, just without aliases.
fn keywordsFor(id: ui_state.PanelId) []const u8 {
    return switch (id) {
        .ai_config => "sampler samplers temperature preset response generation model",
        .formatting => "format font instruct template context macro prose",
        .world_info => "lore book entries worldbook memory",
        .connections => "api connect endpoint backend key server model",
        .characters => "character card avatar cards roster",
        .persona => "persona you user profile",
        .groups => "group party multi cast",
        .chat_manager => "chat chats conversation history log",
        else => "",
    };
}

/// The entries that are not one of the eight family sections. The system popover is one destination,
/// not three: its groups live inside one card with no per-group anchor to jump at, so the palette
/// takes you to the card and its aliases carry the words those groups are named by.
const extras = [_]Target{
    .{
        .kind = .system,
        .group = "App",
        .label = "System menu",
        .keywords = "settings preferences background backgrounds theme motion appearance extensions user",
    },
};

pub const all = build: {
    var list: [ui_state.setup_sections.len + ui_state.cast_sections.len + extras.len]Target = undefined;
    var n: usize = 0;
    for ([_]ui_state.Side{ .left, .right }) |side| {
        for (ui_state.sectionsFor(side)) |sec| {
            list[n] = .{
                .kind = .section,
                .group = ui_state.familyLabel(side),
                .label = sec.label,
                .keywords = keywordsFor(sec.id),
                .side = side,
                .panel = sec.id,
            };
            n += 1;
        }
    }
    for (extras) |t| {
        list[n] = t;
        n += 1;
    }
    break :build list;
};

/// Every target, in catalogue order. The unfiltered list the palette shows on open.
pub const all_slice: []const Target = &all;

comptime {
    // The visible list holds catalogue INDICES as u8 to keep the filter allocation-free. Growing the
    // catalogue past 256 entries would silently truncate them, so it fails the build instead.
    std.debug.assert(all.len <= std.math.maxInt(u8) + 1);
}

// ---- query + selection state -------------------------------------------------------------------

/// The longest query the box holds. A jump target is a handful of words, so a longer string can only
/// be a paste; the tail is dropped rather than the input refused, which keeps typing responsive.
pub const max_query = 64;

var open_flag: bool = false;
var query_buf: [max_query]u8 = undefined;
var query_len: usize = 0;
/// Indices into `all`, in catalogue order, for the targets the current query keeps.
var visible_buf: [all.len]u8 = undefined;
var visible_len: usize = 0;
var active_i: usize = 0;

pub fn isOpen() bool {
    return open_flag;
}

/// Open on a blank query with every target listed and the first one highlighted, so Enter always has
/// somewhere to go the moment the box appears.
pub fn open() void {
    open_flag = true;
    query_len = 0;
    active_i = 0;
    recompute();
}

pub fn close() void {
    open_flag = false;
    query_len = 0;
    active_i = 0;
    recompute();
}

pub fn query() []const u8 {
    return query_buf[0..query_len];
}

/// Take a new query, keeping the highlight on the same TARGET where the narrowed list still holds
/// it. Typing another letter must not silently move Enter onto a different destination, which is
/// what resetting to the top on every keystroke would do.
pub fn setQuery(q: []const u8) void {
    const held: ?u8 = if (active_i < visible_len) visible_buf[active_i] else null;
    const n = @min(q.len, query_buf.len);
    @memcpy(query_buf[0..n], q[0..n]);
    query_len = n;
    recompute();
    active_i = 0;
    if (held) |idx| {
        for (visible_buf[0..visible_len], 0..) |v, i| {
            if (v == idx) {
                active_i = i;
                break;
            }
        }
    }
}

fn recompute() void {
    visible_len = 0;
    const q = query();
    for (all_slice, 0..) |t, i| {
        if (!matches(t, q)) continue;
        visible_buf[visible_len] = @intCast(i);
        visible_len += 1;
    }
    if (active_i >= visible_len) active_i = 0;
}

/// The catalogue indices the query keeps, in catalogue order. The markup iterates this.
pub fn visible() []const u8 {
    return visible_buf[0..visible_len];
}

pub fn visibleCount() usize {
    return visible_len;
}

/// Which visible row Enter takes. Meaningless when nothing matches, which the caller reads off
/// visibleCount rather than from a sentinel here.
pub fn activeIndex() usize {
    return active_i;
}

pub fn isActiveRow(row: usize) bool {
    return visible_len > 0 and row == active_i;
}

pub const Nav = nav.Nav;

/// Move the highlight, wrapping at both ends (dropdown_nav owns the index math, so the palette and
/// the listbox dropdown step identically).
pub fn moveActive(dir: Nav) void {
    active_i = nav.move(active_i, visible_len, dir);
}

/// The target Enter would activate, or null when the query matches nothing.
pub fn activeTarget() ?Target {
    if (visible_len == 0) return null;
    return all[visible_buf[active_i]];
}

/// The target a visible row shows. Out-of-range reads as null rather than trapping: a click can
/// arrive on a row the render behind it has already dropped.
pub fn targetAtRow(row: usize) ?Target {
    if (row >= visible_len) return null;
    return all[visible_buf[row]];
}

/// Point the highlight at a visible row (the mouse path). Out-of-range leaves it where it was.
pub fn setActiveRow(row: usize) void {
    if (row < visible_len) active_i = row;
}

// ---- matching -----------------------------------------------------------------------------------

/// ASCII case-insensitive substring test. std.ascii has eqlIgnoreCase but no indexOf twin in 0.16,
/// and folding a copy would need an allocator this module deliberately does not take.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fieldHas(t: Target, token: []const u8) bool {
    return containsIgnoreCase(t.label, token) or
        containsIgnoreCase(t.group, token) or
        containsIgnoreCase(t.keywords, token);
}

/// True when EVERY whitespace-separated token of the query appears somewhere in the target's label,
/// family word or aliases. All-tokens rather than any-token, so "cast chat" narrows to one row
/// instead of widening to both families; an empty query keeps everything.
pub fn matches(t: Target, q: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, q, " \t");
    while (it.next()) |token| {
        if (!fieldHas(t, token)) return false;
    }
    return true;
}

// ---- tests ---------------------------------------------------------------------------------------

const testing = std.testing;

test "the catalogue carries every family section plus the extras, each on its own side" {
    try testing.expectEqual(ui_state.setup_sections.len + ui_state.cast_sections.len + extras.len, all.len);
    var sections: usize = 0;
    for (all_slice) |t| {
        try testing.expect(t.label.len > 0);
        try testing.expect(t.group.len > 0);
        if (t.kind != .section) continue;
        sections += 1;
        // A target that named a panel from the other flank would open a dock with no body.
        const p = ui_state.panelFor(t.panel) orelse return error.TargetHasNoPanel;
        try testing.expectEqual(t.side, p.side);
        try testing.expect(ui_state.inFamily(t.side, t.panel));
        try testing.expectEqualStrings(ui_state.familyLabel(t.side), t.group);
    }
    try testing.expectEqual(ui_state.setup_sections.len + ui_state.cast_sections.len, sections);
}

test "every family section is reachable and no panel is listed twice" {
    inline for (.{ ui_state.Side.left, ui_state.Side.right }) |side| {
        for (ui_state.sectionsFor(side)) |sec| {
            var seen: usize = 0;
            for (all_slice) |t| {
                if (t.kind == .section and t.panel == sec.id) seen += 1;
            }
            try testing.expectEqual(@as(usize, 1), seen);
        }
    }
}

test "case-insensitive substring matching, including the empty needle" {
    try testing.expect(containsIgnoreCase("Characters", "char"));
    try testing.expect(containsIgnoreCase("Characters", "CHAR"));
    try testing.expect(containsIgnoreCase("Characters", "ters"));
    try testing.expect(containsIgnoreCase("Characters", ""));
    try testing.expect(!containsIgnoreCase("Characters", "z"));
    try testing.expect(!containsIgnoreCase("AI", "aim"));
}

test "a query keeps a target when every token hits its label, family or aliases" {
    const t = Target{ .kind = .section, .group = "Setup", .label = "World", .keywords = "lore book", .side = .left, .panel = .world_info };
    try testing.expect(matches(t, ""));
    try testing.expect(matches(t, "wor"));
    try testing.expect(matches(t, "LORE"));
    try testing.expect(matches(t, "setup"));
    // All tokens, not any: the second token has to land too.
    try testing.expect(matches(t, "setup lore"));
    try testing.expect(!matches(t, "setup nonesuch"));
    try testing.expect(!matches(t, "persona"));
}

test "opening lists everything with the first row highlighted" {
    close();
    try testing.expect(!isOpen());
    open();
    try testing.expect(isOpen());
    try testing.expectEqual(all.len, visibleCount());
    try testing.expectEqual(@as(usize, 0), activeIndex());
    try testing.expect(activeTarget() != null);
    close();
    try testing.expect(!isOpen());
}

test "a query narrows the list and a no-match query leaves nothing to activate" {
    open();
    setQuery("chat");
    try testing.expect(visibleCount() > 0);
    try testing.expect(visibleCount() < all.len);
    for (visible()) |i| {
        try testing.expect(matches(all[i], "chat"));
    }
    setQuery("zzzznope");
    try testing.expectEqual(@as(usize, 0), visibleCount());
    try testing.expect(activeTarget() == null);
    try testing.expect(targetAtRow(0) == null);
    // Clearing restores the full list.
    setQuery("");
    try testing.expectEqual(all.len, visibleCount());
    close();
}

test "the highlight follows its target through a narrowing query" {
    open();
    // Land on a row that survives the next keystroke, then prove Enter still points at it.
    setQuery("c");
    var picked: ?Target = null;
    for (visible(), 0..) |idx, row| {
        if (containsIgnoreCase(all[idx].label, "chats")) {
            setActiveRow(row);
            picked = all[idx];
            break;
        }
    }
    try testing.expect(picked != null);
    setQuery("ch");
    try testing.expectEqualStrings(picked.?.label, activeTarget().?.label);
    close();
}

test "arrow movement wraps and an empty list stays put" {
    open();
    const n = visibleCount();
    try testing.expect(n > 1);
    moveActive(.down);
    try testing.expectEqual(@as(usize, 1), activeIndex());
    moveActive(.up);
    try testing.expectEqual(@as(usize, 0), activeIndex());
    moveActive(.up);
    try testing.expectEqual(n - 1, activeIndex());
    moveActive(.home);
    try testing.expectEqual(@as(usize, 0), activeIndex());
    moveActive(.end);
    try testing.expectEqual(n - 1, activeIndex());
    setQuery("zzzznope");
    moveActive(.down);
    try testing.expectEqual(@as(usize, 0), activeIndex());
    close();
}

test "an over-long query is truncated rather than refused" {
    open();
    const long = "w" ** (max_query + 40);
    setQuery(long);
    try testing.expectEqual(max_query, query().len);
    close();
    try testing.expectEqual(@as(usize, 0), query().len);
}

test "closing clears the query so the next open starts blank" {
    open();
    setQuery("chat");
    close();
    open();
    try testing.expectEqual(@as(usize, 0), query().len);
    try testing.expectEqual(all.len, visibleCount());
    close();
}
