const std = @import("std");

const Character = @import("./character_store.zig").Character;
const page_gpa = @import("./character_store.zig").page_gpa;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.chars);

/// Sort orders, mirroring the old frontend's character_sort_order <option data-field> list.
pub const SortKey = enum {
    name_asc,
    name_desc,
    newest,
    oldest,
    favs,
    recent,
    most_chats,
    least_chats,
    most_tokens,
    least_tokens,
    random,
};

/// Map the old frontend's (data-field, data-order) pair to a SortKey. Returns null for "search"
/// (hidden) and anything unrecognised.
pub fn sortKeyFromField(field: []const u8, sort_order: []const u8) ?SortKey {
    if (std.mem.eql(u8, field, "name")) {
        if (std.mem.eql(u8, sort_order, "desc")) return .name_desc;
        return .name_asc;
    }
    if (std.mem.eql(u8, field, "create_date")) {
        if (std.mem.eql(u8, sort_order, "asc")) return .oldest;
        return .newest;
    }
    if (std.mem.eql(u8, field, "fav")) return .favs;
    if (std.mem.eql(u8, field, "date_last_chat")) return .recent;
    if (std.mem.eql(u8, field, "chat_size")) {
        if (std.mem.eql(u8, sort_order, "asc")) return .least_chats;
        return .most_chats;
    }
    if (std.mem.eql(u8, field, "data_size")) {
        if (std.mem.eql(u8, sort_order, "asc")) return .least_tokens;
        return .most_tokens;
    }
    if (std.mem.eql(u8, field, "random")) return .random;
    return null;
}

/// A character paired with its index in the source CharacterStore, so the rendered list can route
/// clicks back to the store (which stays the source of truth for selection) even after filtering/
/// reordering.
pub const IndexedChar = struct {
    index: usize,
    char: Character,
};

/// Pure view state for the character list: sort, free-text query, active tag filters, favourites
/// only, and grid vs list presentation. No ziex dependency so it is unit-testable natively; the
/// reactive bump lives in the components/handlers that call `compute` then `regions.bumpShell`.
pub const View = struct {
    /// The list opens on the character you spoke to last: it exists to resume a conversation, and
    /// alphabetical order buries a recent chat behind every name earlier in the alphabet.
    /// character_prefs.zig persists a different pick and falls back here.
    pub const default_sort: SortKey = .recent;

    pub const default_grid: bool = true;

    allocator: Allocator,
    sort: SortKey = default_sort,
    query: []const u8 = "",
    query_owned: ?[]u8 = null,
    tags: std.ArrayList([]const u8) = .empty,
    fav_only: bool = false,
    /// The Cast opens as an avatar grid (rework principle 3: this panel is about WHO, and a face is
    /// the fastest way to find a person). The dense row list stays one toolbar toggle away for
    /// anyone reading it as a table of last-chat times; character_prefs.zig persists the choice.
    grid: bool = default_grid,
    /// Pagination (client-side; the backend returns the whole list). page_size == 0 means "show all".
    page: usize = 0,
    page_size: usize = 0,
    /// Total matching characters (before paging), for computing page count. Set by compute.
    total: usize = 0,
    /// Most recent filter+sort result (owned by this View); null only before the first compute.
    result: ?[]const IndexedChar = null,
    /// Distinct tags across all characters, for rendering the tag-filter chips. Refreshed on compute.
    tags_all: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: Allocator) View {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *View) void {
        if (self.result) |r| self.allocator.free(r);
        if (self.query_owned) |q| self.allocator.free(q);
        for (self.tags.items) |t| self.allocator.free(t);
        self.tags.deinit(self.allocator);
        for (self.tags_all.items) |t| self.allocator.free(t);
        self.tags_all.deinit(self.allocator);
        self.* = undefined;
    }

    /// Whether `tag` is in the active filter set (for chip aria-pressed).
    pub fn isTagActive(self: View, tag: []const u8) bool {
        for (self.tags.items) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
        return false;
    }

    pub fn setSort(self: *View, sort: SortKey) void {
        self.sort = sort;
        log.debug("view sort: {s}", .{@tagName(sort)});
    }

    pub fn setFavOnly(self: *View, fav_only: bool) void {
        self.fav_only = fav_only;
        log.debug("view fav_only: {}", .{fav_only});
    }

    pub fn setGrid(self: *View, grid: bool) void {
        self.grid = grid;
        log.debug("view grid: {}", .{grid});
    }

    pub fn setPage(self: *View, page: usize) void {
        if (self.page_size == 0) {
            self.page = 0;
            return;
        }
        const pc = self.pageCount();
        if (pc == 0) self.page = 0 else if (page >= pc) self.page = pc - 1 else self.page = page;
        log.debug("view page: {d} -> {d}", .{ page, self.page });
    }

    pub fn setPageSize(self: *View, page_size: usize) void {
        self.page_size = page_size;
        self.page = 0;
        log.debug("view page_size: {d}", .{page_size});
    }

    /// Number of pages given the current total; always at least 1.
    pub fn pageCount(self: *const View) usize {
        if (self.page_size == 0) return 1;
        if (self.total == 0) return 1;
        return (self.total + self.page_size - 1) / self.page_size;
    }

    /// 1-based "showing from..to of total" bounds for the current page (0 when empty).
    pub fn pageFrom(self: *const View) usize {
        if (self.page_size == 0 or self.total == 0) return if (self.total == 0) 0 else 1;
        return self.page * self.page_size + 1;
    }

    pub fn pageTo(self: *const View) usize {
        if (self.page_size == 0) return self.total;
        return @min((self.page + 1) * self.page_size, self.total);
    }

    pub fn setQuery(self: *View, query: []const u8) Allocator.Error!void {
        if (self.query_owned) |old| self.allocator.free(old);
        if (query.len == 0) {
            self.query = "";
            self.query_owned = null;
            log.debug("view query: cleared", .{});
            return;
        }
        self.query_owned = try self.allocator.dupe(u8, query);
        self.query = self.query_owned.?;
        log.debug("view query: {d} chars", .{query.len});
    }

    /// Toggle `tag` in the active filter set (add if absent, remove if present).
    pub fn toggleTag(self: *View, tag: []const u8) Allocator.Error!void {
        for (self.tags.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, tag)) {
                self.allocator.free(existing);
                _ = self.tags.orderedRemove(i);
                log.debug("view tag off: {s}", .{tag});
                return;
            }
        }
        try self.tags.append(self.allocator, try self.allocator.dupe(u8, tag));
        log.debug("view tag on: {s}", .{tag});
    }

    /// Recompute `result` and `tags_all` from `chars` (filter then sort, then page). Frees previous first.
    pub fn compute(self: *View, chars: []const Character) Allocator.Error!void {
        if (self.result) |r| self.allocator.free(r);
        self.result = null;
        const full = try apply(self.allocator, self.*, chars);
        self.total = full.len;
        log.debug("view compute: {d} of {d} match", .{ full.len, chars.len });
        // Clamp a stale page (e.g. after a filter narrowed the result) before slicing.
        if (self.page_size > 0 and self.page >= self.pageCount()) {
            self.page = if (self.pageCount() == 0) 0 else self.pageCount() - 1;
        }
        if (self.page_size > 0 and full.len > self.page_size) {
            const start = @min(self.page * self.page_size, full.len);
            const end = @min(start + self.page_size, full.len);
            if (start < end) {
                const slice = try self.allocator.alloc(IndexedChar, end - start);
                for (slice, 0..) |*dst, i| dst.* = full[start + i];
                self.allocator.free(full);
                self.result = slice;
            } else {
                self.allocator.free(full);
                self.result = &.{};
            }
        } else {
            self.result = full;
        }
        for (self.tags_all.items) |t| self.allocator.free(t);
        self.tags_all.clearRetainingCapacity();
        for (chars) |c| {
            for (c.tags) |ct| {
                var seen = false;
                for (self.tags_all.items) |existing| {
                    if (std.mem.eql(u8, existing, ct)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try self.tags_all.append(self.allocator, try self.allocator.dupe(u8, ct));
            }
        }
    }
};

/// Pure filter + sort. Returns an owned slice of IndexedChar (struct copies; the underlying
/// character data is owned by the source store and must not be freed here).
pub fn apply(allocator: Allocator, view: View, chars: []const Character) Allocator.Error![]const IndexedChar {
    var out = std.ArrayList(IndexedChar).empty;
    errdefer out.deinit(allocator);
    for (chars, 0..) |c, i| {
        if (view.fav_only and !c.fav) continue;
        if (view.tags.items.len > 0 and !tagMatch(view.tags.items, c.tags)) continue;
        if (view.query.len > 0 and !searchMatch(view.query, c)) continue;
        try out.append(allocator, .{ .index = i, .char = c });
    }
    std.sort.pdq(IndexedChar, out.items, SortCtx{ .key = view.sort }, SortCtx.less);
    return try out.toOwnedSlice(allocator);
}

fn tagMatch(active: [][]const u8, char_tags: []const []const u8) bool {
    for (active) |t| {
        var found = false;
        for (char_tags) |ct| {
            if (std.mem.eql(u8, t, ct)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn searchMatch(query: []const u8, c: Character) bool {
    if (query.len == 0) return true;
    return containsCi(query, c.name) or containsCi(query, c.description);
}

fn containsCi(needle: []const u8, haystack: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        var ok = true;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn asciiLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

fn hash(a: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (a) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

/// Returns true when `a` should precede `b` under `key`.
fn compareChars(a: IndexedChar, b: IndexedChar, key: SortKey) bool {
    const x = a.char;
    const y = b.char;
    return switch (key) {
        .name_asc => asciiLess(x.name, y.name),
        .name_desc => asciiLess(y.name, x.name),
        .newest => asciiLess(y.create_date, x.create_date),
        .oldest => asciiLess(x.create_date, y.create_date),
        .favs => if (x.fav != y.fav) x.fav else asciiLess(x.name, y.name),
        .recent => y.date_last_chat < x.date_last_chat,
        .most_chats => y.chat_size < x.chat_size,
        .least_chats => x.chat_size < y.chat_size,
        .most_tokens => y.data_size < x.data_size,
        .least_tokens => x.data_size < y.data_size,
        .random => hash(x.avatar) < hash(y.avatar),
    };
}

const SortCtx = struct {
    key: SortKey,
    pub fn less(self: @This(), a: IndexedChar, b: IndexedChar) bool {
        return compareChars(a, b, self.key);
    }
};

pub var global: View = .{ .allocator = page_gpa };

const testing = std.testing;

fn char(name: []const u8, fav: bool, create_date: []const u8, date_last_chat: u64, chat_size: u64, data_size: u64, tags: []const []const u8) Character {
    return .{
        .name = name,
        .avatar = name,
        .description = "",
        .personality = "",
        .first_mes = "",
        .scenario = "",
        .mes_example = "",
        .chat = "",
        .fav = fav,
        .tags = tags,
        .create_date = create_date,
        .date_last_chat = date_last_chat,
        .chat_size = chat_size,
        .data_size = data_size,
    };
}

test "sort by name asc/desc" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("Beta", false, "", 0, 0, 0, &.{}),
        char("alpha", false, "", 0, 0, 0, &.{}),
        char("Charlie", false, "", 0, 0, 0, &.{}),
    };
    const v: View = .{ .allocator = a, .sort = .name_asc };
    const r = try apply(a, v, &chars);
    defer a.free(r);
    try testing.expectEqualStrings("alpha", r[0].char.name);
    try testing.expectEqualStrings("Beta", r[1].char.name);
    try testing.expectEqualStrings("Charlie", r[2].char.name);

    const v2: View = .{ .allocator = a, .sort = .name_desc };
    const r2 = try apply(a, v2, &chars);
    defer a.free(r2);
    try testing.expectEqualStrings("Charlie", r2[0].char.name);
    try testing.expectEqualStrings("alpha", r2[2].char.name);
}

test "fav_only filters and favs sort floats favourites first" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("A", true, "", 0, 0, 0, &.{}),
        char("B", false, "", 0, 0, 0, &.{}),
        char("C", true, "", 0, 0, 0, &.{}),
    };
    const v1: View = .{ .allocator = a, .fav_only = true, .sort = .name_asc };
    const r1 = try apply(a, v1, &chars);
    defer a.free(r1);
    try testing.expectEqual(@as(usize, 2), r1.len);
    try testing.expectEqualStrings("A", r1[0].char.name);
    try testing.expectEqualStrings("C", r1[1].char.name);

    const v2: View = .{ .allocator = a, .fav_only = true, .sort = .favs };
    const r2 = try apply(a, v2, &chars);
    defer a.free(r2);
    try testing.expectEqualStrings("A", r2[0].char.name);
    try testing.expectEqualStrings("C", r2[1].char.name);
}

test "search is case-insensitive over name and description" {
    const a = testing.allocator;
    var chars = [_]Character{
        char("Alice", false, "", 0, 0, 0, &.{}),
        char("Bob", false, "", 0, 0, 0, &.{}),
    };
    chars[1].description = "loves KNIGHTS";
    var v: View = .{ .allocator = a };
    defer v.deinit();
    try v.setQuery("knight");
    const r = try apply(a, v, &chars);
    defer a.free(r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("Bob", r[0].char.name);
}

test "tag filter requires every active tag (AND)" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("A", false, "", 0, 0, 0, &.{ "x", "y" }),
        char("B", false, "", 0, 0, 0, &.{"x"}),
    };
    var v: View = .{ .allocator = a };
    try v.toggleTag("x");
    try v.toggleTag("y");
    const r = try apply(a, v, &chars);
    defer a.free(r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("A", r[0].char.name);
    v.deinit();
}

test "numeric sorts order by chat_size and data_size" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("small", false, "", 0, 10, 0, &.{}),
        char("big", false, "", 0, 100, 0, &.{}),
    };
    var v: View = .{ .allocator = a, .sort = .most_chats };
    const r = try apply(a, v, &chars);
    defer a.free(r);
    try testing.expectEqualStrings("big", r[0].char.name);

    v.sort = .least_chats;
    const r2 = try apply(a, v, &chars);
    defer a.free(r2);
    try testing.expectEqualStrings("small", r2[0].char.name);
}

test "apply preserves the source store index" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("A", false, "", 0, 0, 0, &.{}),
        char("B", false, "", 0, 0, 0, &.{}),
    };
    const v: View = .{ .allocator = a, .sort = .name_desc };
    const r = try apply(a, v, &chars);
    defer a.free(r);
    // B (index 1) sorts first but must keep its store index.
    try testing.expectEqual(@as(usize, 1), r[0].index);
    try testing.expectEqual(@as(usize, 0), r[1].index);
}

test "a default view opens as the avatar grid" {
    // Principle 3 of the rework: the Cast is visual. A default that reverted to rows would put the
    // panel back to a text list without anything in the UI having asked for one.
    const v: View = .{ .allocator = testing.allocator };
    try testing.expect(v.grid);
    try testing.expectEqual(View.default_grid, v.grid);
}

test "a default view sorts by most recent chat" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("stale", false, "", 1000, 0, 0, &.{}),
        char("freshest", false, "", 9000, 0, 0, &.{}),
        char("middling", false, "", 5000, 0, 0, &.{}),
    };
    const v: View = .{ .allocator = a };
    try testing.expectEqual(SortKey.recent, v.sort);
    const r = try apply(a, v, &chars);
    defer a.free(r);
    try testing.expectEqualStrings("freshest", r[0].char.name);
    try testing.expectEqualStrings("middling", r[1].char.name);
    try testing.expectEqualStrings("stale", r[2].char.name);
}

test "sortKeyFromField maps old frontend options" {
    try testing.expectEqual(SortKey.name_desc, sortKeyFromField("name", "desc").?);
    try testing.expectEqual(SortKey.newest, sortKeyFromField("create_date", "desc").?);
    try testing.expectEqual(SortKey.favs, sortKeyFromField("fav", "desc").?);
    try testing.expectEqual(SortKey.most_chats, sortKeyFromField("chat_size", "desc").?);
    try testing.expectEqual(SortKey.least_tokens, sortKeyFromField("data_size", "asc").?);
    try testing.expectEqual(SortKey.random, sortKeyFromField("random", "random").?);
    try testing.expectEqual(@as(?SortKey, null), sortKeyFromField("search", "desc"));
}

test "compute collects distinct tags and reports active state" {
    const a = testing.allocator;
    const chars = [_]Character{
        char("A", false, "", 0, 0, 0, &.{ "x", "y" }),
        char("B", false, "", 0, 0, 0, &.{ "y", "z" }),
        char("C", false, "", 0, 0, 0, &.{}),
    };
    var v: View = .{ .allocator = a };
    try v.compute(&chars);
    defer v.deinit();
    // distinct tags across all characters: x, y, z
    try testing.expectEqual(@as(usize, 3), v.tags_all.items.len);
    try testing.expectEqual(false, v.isTagActive("x"));
    try v.toggleTag("x");
    try testing.expectEqual(true, v.isTagActive("x"));
    try v.toggleTag("x");
    try testing.expectEqual(false, v.isTagActive("x"));
}

test "pagination slices the full result and clamps stale pages" {
    const a = testing.allocator;
    const names = [_][]const u8{ "0", "1", "2", "3", "4" };
    var chars: [5]Character = undefined;
    for (&chars, 0..) |*c, i| c.* = char(names[i], false, "", 0, 0, 0, &.{});
    var v: View = .{ .allocator = a, .page_size = 2, .sort = .name_asc };
    try v.compute(&chars);
    defer v.deinit();
    // 5 chars at size 2 -> 3 pages; page 0 shows 2.
    try testing.expectEqual(@as(usize, 5), v.total);
    try testing.expectEqual(@as(usize, 3), v.pageCount());
    try testing.expectEqual(@as(usize, 2), v.result.?.len);
    try testing.expectEqualStrings("0", v.result.?[0].char.name);
    try testing.expectEqual(@as(usize, 1), v.pageFrom());
    try testing.expectEqual(@as(usize, 2), v.pageTo());

    v.setPage(2);
    try v.compute(&chars);
    try testing.expectEqual(@as(usize, 1), v.result.?.len);
    try testing.expectEqualStrings("4", v.result.?[0].char.name);

    // Stale page past the end is clamped on recompute.
    v.setPage(99);
    try v.compute(&chars);
    try testing.expectEqual(@as(usize, 2), v.page); // clamped to last page
}
