//! The filter bar's suggestion logic: which tags a typed fragment offers, and where the keyboard
//! highlight sits. Pure Zig with no ziex import, so `zig build test` proves it natively (ZX5);
//! filter_bar.zx owns the markup, the DOM reads and the re-render calls.
//!
//! The field does two jobs at once: the text narrows the list by name, and a picked suggestion adds
//! a tag filter. Everything here answers the second half, and it answers it with the SAME substring
//! test the row search uses (character_view.containsCi), so the field never offers a tag on a
//! fragment its own matching would reject.

const std = @import("std");
const cv = @import("./character_view.zig");

const Allocator = std.mem.Allocator;

/// How many suggestions the field offers at once. The list drops under a field inside a dock that
/// is ~300px wide, so a longer one covers the characters the user is reading while they type.
pub const max_suggestions: usize = 6;

/// Which way a key moves the highlight.
pub const Move = enum { down, up };

/// Tags matching `query` that are not already active filters, in `all` order, capped at
/// `max_suggestions`. An empty query offers nothing: until the user has typed something, every tag
/// matches, and a list of every tag is the wall this bar exists to replace.
///
/// The returned SLICE is owned by the caller. The strings inside it are BORROWED from `all`, which
/// the next `View.compute` frees, so a caller that outlives one render copies what it keeps.
pub fn suggest(
    allocator: Allocator,
    all: []const []const u8,
    active: []const []const u8,
    query: []const u8,
) Allocator.Error![]const []const u8 {
    if (query.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (all) |tag| {
        if (out.items.len >= max_suggestions) break;
        if (!cv.containsCi(query, tag)) continue;
        if (has(active, tag)) continue;
        try out.append(allocator, tag);
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return &.{};
    }
    return try out.toOwnedSlice(allocator);
}

fn has(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

/// Where the highlight lands after an arrow key. `null` means nothing is highlighted, which is the
/// state the field opens in and returns to at either end of the list: with no highlight, Enter does
/// nothing and the typed text is simply the name filter, which is what a user who never wanted a
/// tag expects (WAI-ARIA combobox, aria-activedescendant absent).
pub fn moveHighlight(current: ?usize, count: usize, dir: Move) ?usize {
    if (count == 0) return null;
    const last = count - 1;
    return switch (dir) {
        .down => if (current) |i| (if (i >= last) null else i + 1) else 0,
        .up => if (current) |i| (if (i == 0) null else i - 1) else last,
    };
}

/// The highlight after the list changed under it. Typing narrows the suggestions, so an index taken
/// against the longer list would point past the end and Enter would add nothing.
pub fn clampHighlight(current: ?usize, count: usize) ?usize {
    const i = current orelse return null;
    if (count == 0) return null;
    return if (i < count) i else count - 1;
}

const testing = std.testing;

test "suggest matches case-insensitively and skips the tags already filtering" {
    const all = [_][]const u8{ "Harbor", "night", "nightmare", "day" };
    const active = [_][]const u8{"nightmare"};
    const r = try suggest(testing.allocator, &all, &active, "NIGH");
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("night", r[0]);
}

test "suggest offers nothing for an empty query" {
    const all = [_][]const u8{ "harbor", "night" };
    const r = try suggest(testing.allocator, &all, &.{}, "");
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "suggest caps the list at max_suggestions" {
    var names: [max_suggestions + 3][12]u8 = undefined;
    var all: [max_suggestions + 3][]const u8 = undefined;
    for (&names, 0..) |*buf, i| all[i] = std.fmt.bufPrint(buf, "tag-{d}", .{i}) catch unreachable;
    const r = try suggest(testing.allocator, &all, &.{}, "tag");
    defer testing.allocator.free(r);
    try testing.expectEqual(max_suggestions, r.len);
    try testing.expectEqualStrings("tag-0", r[0]);
}

test "suggest returns the source order, not a sorted one" {
    const all = [_][]const u8{ "zeta-run", "alpha-run" };
    const r = try suggest(testing.allocator, &all, &.{}, "run");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("zeta-run", r[0]);
    try testing.expectEqualStrings("alpha-run", r[1]);
}

test "moveHighlight walks the list and falls off both ends to no highlight" {
    try testing.expectEqual(@as(?usize, 0), moveHighlight(null, 3, .down));
    try testing.expectEqual(@as(?usize, 1), moveHighlight(0, 3, .down));
    try testing.expectEqual(@as(?usize, null), moveHighlight(2, 3, .down));
    try testing.expectEqual(@as(?usize, 2), moveHighlight(null, 3, .up));
    try testing.expectEqual(@as(?usize, 0), moveHighlight(1, 3, .up));
    try testing.expectEqual(@as(?usize, null), moveHighlight(0, 3, .up));
    try testing.expectEqual(@as(?usize, null), moveHighlight(null, 0, .down));
}

test "clampHighlight pulls a stale index back inside a narrowed list" {
    try testing.expectEqual(@as(?usize, 1), clampHighlight(4, 2));
    try testing.expectEqual(@as(?usize, 1), clampHighlight(1, 2));
    try testing.expectEqual(@as(?usize, null), clampHighlight(3, 0));
    try testing.expectEqual(@as(?usize, null), clampHighlight(null, 5));
}

fn suggestScenario(gpa: Allocator) !void {
    const all = [_][]const u8{ "harbor", "night", "nightmare" };
    const active = [_][]const u8{"harbor"};
    const r = try suggest(gpa, &all, &active, "n");
    defer gpa.free(r);
    try testing.expectEqual(@as(usize, 2), r.len);
}

test "suggest releases everything on any allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, suggestScenario, .{});
}
