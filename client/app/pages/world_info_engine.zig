//! World-info activation engine (3b-B): which entries fire for a send, and the text each prompt
//! slot receives. Pure and zx-free, proven under `zig build test`; generate.zig runs it inside
//! `buildPromptBudgeted` and char_api supplies the store-owned candidate entries.
//!
//! Semantics follow the classic client (public/scripts/world-info.js, checked 2026-07-17):
//! candidate PRIORITY (probability + budget) is the caller's list order (chat lore, then character,
//! then global; each book by `order` descending, sortFn :89 + the character_first default strategy);
//! the JOINED text follows stock's descending-sort-then-distribute (:5082): unshift for every bucket
//! but outlets (order-ascending, ties reversed), push for outlets (order-descending, ties kept).
//! Matching is case-insensitive ASCII substring over the newest `scan_depth`
//! message texts (probe#3: "ASCII substring"); recursion re-scans activated content when enabled
//! (stock world_info_recursive, default off). The budget cap bounds the WI slice ONLY (probe#3
//! delta 2): an entry that would reach the cap is dropped and activation stops, so the
//! lowest-priority entries are what a tight budget sheds.

const std = @import("std");

const wi = @import("./world_info.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.wi);

pub const Entry = wi.Entry;

/// Activation inputs. `entries` must already be in priority order (WorldInfoStore.collectActive).
/// A null `rng` skips the probability roll entirely (every roll passes); the send path always
/// supplies one, tests pass a seeded PRNG.
pub const Params = struct {
    entries: []const Entry = &.{},
    scan_depth: usize = 2,
    budget_chars: usize = std.math.maxInt(usize),
    recursive: bool = false,
    rng: ?std.Random = null,
    /// Stock world_info_case_sensitive: the default a null per-entry caseSensitive falls back to.
    case_sensitive: bool = false,
    /// Stock world_info_match_whole_words: default for a null per-entry matchWholeWords.
    match_whole_words: bool = false,
};

/// One merged at-depth injection: every activated atDepth entry at this depth AND role, joined.
/// role: 0 system, 1 user, 2 assistant (stock groups by depth+role, world-info.js:5115).
pub const DepthGroup = struct { depth: i64, role: i64 = 0, content: []const u8 };

/// One named outlet: every activated outlet entry with this outletName, joined. Feeds the
/// {{outlet::name}} macro (stock world-info.js:5127); a nameless outlet entry is skipped as stock.
pub const OutletGroup = struct { name: []const u8, content: []const u8 };

/// The activated text per prompt slot. All slices live in the arena; free with `deinit`.
pub const Activation = struct {
    arena: std.heap.ArenaAllocator,
    before: []const u8 = "",
    after: []const u8 = "",
    an_top: []const u8 = "",
    an_bottom: []const u8 = "",
    em_top: []const []const u8 = &.{},
    em_bottom: []const []const u8 = &.{},
    at_depth: []const DepthGroup = &.{},
    outlets: []const OutletGroup = &.{},

    pub fn deinit(self: *Activation) void {
        self.arena.deinit();
    }
};

/// Runs the scan-activate-budget loop over `history` (message texts, OLDEST first; the engine
/// scans the newest `scan_depth` of them) and buckets the survivors by position. Owned result.
pub fn activate(gpa: Allocator, params: Params, history: []const []const u8) Allocator.Error!Activation {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const scan_n = @min(params.scan_depth, history.len);
    const scan_texts = history[history.len - scan_n ..];

    const State = enum(u8) { idle, active, failed };
    const flags = try a.alloc(State, params.entries.len);
    @memset(flags, .idle);

    var recurse: std.ArrayList([]const u8) = .empty;
    // Activation order = stock's allActivatedEntries Map insertion order (pass by pass, candidate
    // order within a pass). sortFn is stable, so equal-order ties keep THIS order, not candidate order.
    var activated: std.ArrayList(usize) = .empty;
    var used_chars: usize = 0;
    var overflow = false;

    var scanning = params.entries.len > 0;
    while (scanning) {
        scanning = false;
        var newly: std.ArrayList(usize) = .empty;
        for (params.entries, 0..) |e, i| {
            if (flags[i] != .idle) continue;
            if (e.disable) continue;
            if (e.constant) {
                try newly.append(a, i);
                continue;
            }
            if (e.keys.len == 0) continue;
            const cs = e.case_sensitive orelse params.case_sensitive;
            const ww = e.match_whole_words orelse params.match_whole_words;
            // Per-entry scanDepth (stock buffer.get :281): null falls back to the global window; a
            // depth <= 0 scans no chat (only the recursion buffer). Clamp to the window we hold.
            const e_scan = blk: {
                const d = e.scan_depth orelse break :blk scan_texts;
                const eff: usize = if (d <= 0) 0 else @min(@as(usize, @intCast(d)), history.len);
                break :blk history[history.len - eff ..];
            };
            if (!matchAnyKey(e.keys, e_scan, recurse.items, cs, ww)) continue;
            if (e.selective and e.keysecondary.len > 0 and !selectiveOk(e, e_scan, recurse.items, cs, ww)) continue;
            try newly.append(a, i);
        }
        var activated_this_pass = false;
        for (newly.items) |i| {
            if (overflow) break;
            const e = params.entries[i];
            if (e.use_probability and e.probability < 100) {
                const roll: f64 = if (params.rng) |rng| rng.float(f64) * 100.0 else 0.0;
                if (roll > @as(f64, @floatFromInt(e.probability))) {
                    flags[i] = .failed;
                    continue;
                }
            }
            // Stock reaching the budget exactly also overflows (world-info.js:4940, `>=`).
            if (used_chars +| e.content.len +| 1 >= params.budget_chars) {
                overflow = true;
                log.debug("wi budget {d} reached, activation stopped", .{params.budget_chars});
                break;
            }
            used_chars += e.content.len + 1;
            flags[i] = .active;
            try activated.append(a, i);
            activated_this_pass = true;
            if (params.recursive and e.content.len > 0) try recurse.append(a, e.content);
        }
        if (params.recursive and !overflow and activated_this_pass) scanning = true;
    }

    // Stock sorts activated entries order-DESCENDING (stable sortFn :89) then distributes with
    // unshift (all buckets + atDepth content) or push (outlets), :5082; mirror both to land ties right.
    const idx = activated;
    std.mem.sort(usize, idx.items, params.entries, orderDesc);

    var before: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var an_top: std.ArrayList([]const u8) = .empty;
    var an_bottom: std.ArrayList([]const u8) = .empty;
    var em_top: std.ArrayList([]const u8) = .empty;
    var em_bottom: std.ArrayList([]const u8) = .empty;
    var outlets: std.ArrayList(struct { name: []const u8, buf: std.ArrayList([]const u8) }) = .empty;
    var groups: std.ArrayList(struct { depth: i64, role: i64, buf: std.ArrayList([]const u8) }) = .empty;

    for (idx.items) |i| {
        const e = params.entries[i];
        if (e.content.len == 0) continue;
        switch (e.position) {
            .before => try before.insert(a, 0, e.content),
            .after => try after.insert(a, 0, e.content),
            .an_top => try an_top.insert(a, 0, e.content),
            .an_bottom => try an_bottom.insert(a, 0, e.content),
            .em_top => try em_top.insert(a, 0, e.content),
            .em_bottom => try em_bottom.insert(a, 0, e.content),
            .at_depth => {
                const depth = @max(0, e.depth);
                const g = for (groups.items) |*g| {
                    if (g.depth == depth and g.role == e.role) break g;
                } else blk: {
                    try groups.append(a, .{ .depth = depth, .role = e.role, .buf = .empty });
                    break :blk &groups.items[groups.items.len - 1];
                };
                try g.buf.insert(a, 0, e.content); // unshift, :5117
            },
            .outlet => {
                if (e.outlet_name.len == 0) {
                    // Stock skips a nameless outlet entry with a warn (world-info.js:5128).
                    log.warn("wi entry {d} has the outlet position but no outlet name, skipped", .{e.uid});
                    continue;
                }
                const g = for (outlets.items) |*g| {
                    if (std.mem.eql(u8, g.name, e.outlet_name)) break g;
                } else blk: {
                    try outlets.append(a, .{ .name = e.outlet_name, .buf = .empty });
                    break :blk &outlets.items[outlets.items.len - 1];
                };
                try g.buf.append(a, e.content); // push, :5133
            },
        }
    }

    const out_groups = try a.alloc(DepthGroup, groups.items.len);
    for (groups.items, 0..) |g, i| out_groups[i] = .{ .depth = g.depth, .role = g.role, .content = try std.mem.join(a, "\n", g.buf.items) };
    const out_outlets = try a.alloc(OutletGroup, outlets.items.len);
    for (outlets.items, 0..) |g, i| out_outlets[i] = .{ .name = g.name, .content = try std.mem.join(a, "\n", g.buf.items) };

    return .{
        .arena = arena,
        .before = try std.mem.join(a, "\n", before.items),
        .after = try std.mem.join(a, "\n", after.items),
        .an_top = try std.mem.join(a, "\n", an_top.items),
        .an_bottom = try std.mem.join(a, "\n", an_bottom.items),
        .em_top = em_top.items,
        .em_bottom = em_bottom.items,
        .at_depth = out_groups,
        .outlets = out_outlets,
    };
}

// Order-only so std.mem.sort (stable) keeps equal-order entries in activation order, as stock's
// stable sortFn keeps its Map insertion order.
fn orderDesc(entries: []const Entry, lhs: usize, rhs: usize) bool {
    return entries[lhs].order > entries[rhs].order;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn hasWhitespace(s: []const u8) bool {
    for (s) |c| if (std.ascii.isWhitespace(c)) return true;
    return false;
}

/// Case-folded substring search from `start`; a case-sensitive match is an exact byte search.
fn foldIndex(hay: []const u8, needle: []const u8, cs: bool, start: usize) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    if (cs) return std.mem.indexOfPos(u8, hay, start, needle);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Stock matchKeys (world-info.js:338): caseSensitive lowercases both sides, matchWholeWords bounds
/// a single-word key with (?:^|\W)(key)(?:$|\W); a multi-word key falls back to plain containment.
fn textMatches(hay: []const u8, needle: []const u8, cs: bool, ww: bool) bool {
    if (needle.len == 0) return false;
    if (ww and !hasWhitespace(needle)) {
        var start: usize = 0;
        while (foldIndex(hay, needle, cs, start)) |i| {
            const before_ok = i == 0 or !isWordChar(hay[i - 1]);
            const after = i + needle.len;
            const after_ok = after == hay.len or !isWordChar(hay[after]);
            if (before_ok and after_ok) return true;
            start = i + 1;
        }
        return false;
    }
    return foldIndex(hay, needle, cs, 0) != null;
}

fn matchText(needle: []const u8, texts: []const []const u8, cs: bool, ww: bool) bool {
    for (texts) |t| {
        if (textMatches(t, needle, cs, ww)) return true;
    }
    return false;
}

fn matchKey(raw: []const u8, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    const key = std.mem.trim(u8, raw, " \t\r\n");
    if (key.len == 0) return false;
    return matchText(key, scan, cs, ww) or matchText(key, recurse, cs, ww);
}

fn matchAnyKey(keys: []const []const u8, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    for (keys) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) return true;
    }
    return false;
}

/// The four stock selective logics over the secondary keys (world-info.js:4829). An empty
/// secondary key matches nothing, which fails and_all and never satisfies and_any, as stock.
fn selectiveOk(e: Entry, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    var any = false;
    var all = true;
    for (e.keysecondary) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) any = true else all = false;
    }
    return switch (e.selective_logic) {
        .and_any => any,
        .not_all => !all,
        .not_any => !any,
        .and_all => all,
    };
}

const testing = std.testing;

fn te(uid: i64, keys: []const []const u8, content: []const u8) Entry {
    return .{
        .uid_key = "",
        .uid = uid,
        .keys = keys,
        .keysecondary = &.{},
        .selective_logic = .and_any,
        .content = content,
        .comment = "",
        .constant = false,
        .selective = false,
        .disable = false,
        .order = 100,
        .position = .before,
        .depth = 4,
        .probability = 100,
        .use_probability = true,
        .outlet_name = "",
    };
}

test "a matching key activates its entry and a non-matching key does not" {
    const entries = [_]Entry{
        te(0, &.{ "dragon", "wyrm" }, "ALPHA"),
        te(1, &.{"zebra"}, "NEVER"),
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"The DRAGON sleeps."});
    defer act.deinit();
    try testing.expectEqualStrings("ALPHA", act.before);
    try testing.expect(std.mem.indexOf(u8, act.before, "NEVER") == null);
}

test "matching is case-insensitive ascii substring and trims key whitespace" {
    const entries = [_]Entry{te(0, &.{" GateKey "}, "A")};
    var hit = try activate(testing.allocator, .{ .entries = &entries }, &.{"found the gatekey today"});
    defer hit.deinit();
    try testing.expectEqualStrings("A", hit.before);
    var miss = try activate(testing.allocator, .{ .entries = &entries }, &.{"found the gate key today"});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
}

test "scan depth bounds the window from the newest message" {
    const entries = [_]Entry{te(0, &.{"lighthouse"}, "A")};
    const history = [_][]const u8{ "the lighthouse looms", "hello", "more talk" };
    var out_of_window = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 2 }, &history);
    defer out_of_window.deinit();
    try testing.expectEqualStrings("", out_of_window.before);
    var in_window = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 3 }, &history);
    defer in_window.deinit();
    try testing.expectEqualStrings("A", in_window.before);
    var depth_zero = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 0 }, &history);
    defer depth_zero.deinit();
    try testing.expectEqualStrings("", depth_zero.before);
}

test "a constant entry fires with no key match and a disabled one never fires" {
    var constant = te(0, &.{}, "ALWAYS");
    constant.constant = true;
    var disabled = te(1, &.{"hello"}, "OFF");
    disabled.disable = true;
    var disabled_constant = te(2, &.{}, "OFF2");
    disabled_constant.constant = true;
    disabled_constant.disable = true;
    const entries = [_]Entry{ constant, disabled, disabled_constant };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"hello"});
    defer act.deinit();
    try testing.expectEqualStrings("ALWAYS", act.before);
}

test "the four selective logics gate on the secondary keys" {
    const Case = struct { logic: wi.Logic, expect_hit: bool };
    // Scan text carries "red" but not "blue"; secondary = [red, blue] -> any=true, all=false.
    const cases = [_]Case{
        .{ .logic = .and_any, .expect_hit = true },
        .{ .logic = .not_all, .expect_hit = true },
        .{ .logic = .not_any, .expect_hit = false },
        .{ .logic = .and_all, .expect_hit = false },
    };
    for (cases) |c| {
        var e = te(0, &.{"dragon"}, "S");
        e.selective = true;
        e.keysecondary = &.{ "red", "blue" };
        e.selective_logic = c.logic;
        const entries = [_]Entry{e};
        var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"a red dragon"});
        defer act.deinit();
        try testing.expectEqualStrings(if (c.expect_hit) "S" else "", act.before);
    }
}

test "recursion activates an entry keyed only by another entry's content, gated by the flag" {
    const entries = [_]Entry{
        te(0, &.{"dragon"}, "the ember hoard"),
        te(1, &.{"ember"}, "SECOND"),
    };
    var on = try activate(testing.allocator, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
    defer on.deinit();
    // Both share the default order, so the tie reverses (stock's unshift): the later-activated SECOND
    // sits ahead of the entry that seeded it.
    try testing.expectEqualStrings("SECOND\nthe ember hoard", on.before);
    var off = try activate(testing.allocator, .{ .entries = &entries, .recursive = false }, &.{"a dragon"});
    defer off.deinit();
    try testing.expectEqualStrings("the ember hoard", off.before);
}

test "the budget cap drops the lowest-priority entries first and stops activation" {
    // Priority = list order; join order = entry order ascending. keep2(order 50) joins before
    // keep1(order 90) yet outranks nothing: the third candidate is what the cap sheds.
    var keep1 = te(0, &.{}, "AAAAAAAAAA");
    keep1.constant = true;
    keep1.order = 90;
    var keep2 = te(1, &.{}, "BBBBBBBBBB");
    keep2.constant = true;
    keep2.order = 50;
    var drop = te(2, &.{}, "CCCCCCCCCC");
    drop.constant = true;
    drop.order = 10;
    const entries = [_]Entry{ keep1, keep2, drop };
    var act = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 25 }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("BBBBBBBBBB\nAAAAAAAAAA", act.before);
    var roomy = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 1000 }, &.{});
    defer roomy.deinit();
    try testing.expectEqualStrings("CCCCCCCCCC\nBBBBBBBBBB\nAAAAAAAAAA", roomy.before);
}

test "reaching the budget exactly overflows, one char under it does not" {
    var e = te(0, &.{}, "12345");
    e.constant = true;
    const entries = [_]Entry{e};
    var exact = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 6 }, &.{});
    defer exact.deinit();
    try testing.expectEqualStrings("", exact.before);
    var under = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 7 }, &.{});
    defer under.deinit();
    try testing.expectEqualStrings("12345", under.before);
}

test "probability entries roll the caller's rng with a fixed seed, once each" {
    var gated = te(0, &.{}, "MAYBE");
    gated.constant = true;
    gated.probability = 50;
    var sure = te(1, &.{}, "SURE");
    sure.constant = true;
    sure.probability = 50;
    sure.use_probability = false;
    const entries = [_]Entry{ gated, sure };

    // The engine consumes one float roll for the gated entry; mirror it to know the verdict.
    var mirror = std.Random.DefaultPrng.init(0x5eed);
    const expect_gated = mirror.random().float(f64) * 100.0 <= 50.0;

    var prng = std.Random.DefaultPrng.init(0x5eed);
    var act = try activate(testing.allocator, .{ .entries = &entries, .rng = prng.random() }, &.{});
    defer act.deinit();
    // Both entries share the default order, so the tie reverses to SURE (uid1) then MAYBE (uid0).
    const want = if (expect_gated) "SURE\nMAYBE" else "SURE";
    try testing.expectEqualStrings(want, act.before);

    var no_rng = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer no_rng.deinit();
    try testing.expectEqualStrings("SURE\nMAYBE", no_rng.before);
}

test "every position lands in its own slot and at_depth groups merge per depth" {
    const mk = struct {
        fn e(uid: i64, pos: wi.Position, depth: i64, order: i64, content: []const u8) Entry {
            var x = te(uid, &.{}, content);
            x.constant = true;
            x.position = pos;
            x.depth = depth;
            x.order = order;
            return x;
        }
    };
    var named_out = mk.e(9, .outlet, 4, 100, "OUT");
    named_out.outlet_name = "gate";
    const entries = [_]Entry{
        mk.e(0, .before, 4, 100, "B"),
        mk.e(1, .after, 4, 100, "A"),
        mk.e(2, .an_top, 4, 100, "NT"),
        mk.e(3, .an_bottom, 4, 100, "NB"),
        mk.e(4, .em_top, 4, 100, "ET"),
        mk.e(5, .em_bottom, 4, 100, "EB"),
        mk.e(6, .at_depth, 2, 200, "D2-late"),
        mk.e(7, .at_depth, 2, 100, "D2-early"),
        mk.e(8, .at_depth, 0, 100, "D0"),
        named_out,
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("B", act.before);
    try testing.expectEqualStrings("A", act.after);
    try testing.expectEqualStrings("NT", act.an_top);
    try testing.expectEqualStrings("NB", act.an_bottom);
    try testing.expectEqual(@as(usize, 1), act.em_top.len);
    try testing.expectEqualStrings("ET", act.em_top[0]);
    try testing.expectEqualStrings("EB", act.em_bottom[0]);
    try testing.expectEqual(@as(usize, 2), act.at_depth.len);
    try testing.expectEqual(@as(i64, 2), act.at_depth[0].depth);
    try testing.expectEqualStrings("D2-early\nD2-late", act.at_depth[0].content);
    try testing.expectEqual(@as(i64, 0), act.at_depth[1].depth);
    try testing.expectEqualStrings("D0", act.at_depth[1].content);
    try testing.expectEqual(@as(usize, 1), act.outlets.len);
    try testing.expectEqualStrings("gate", act.outlets[0].name);
    try testing.expectEqualStrings("OUT", act.outlets[0].content);
}

test "outlet entries group per name via push, and a nameless one is skipped" {
    const mk = struct {
        fn e(uid: i64, name: []const u8, order: i64, content: []const u8) Entry {
            var x = te(uid, &.{}, content);
            x.constant = true;
            x.position = .outlet;
            x.outlet_name = name;
            x.order = order;
            return x;
        }
    };
    const entries = [_]Entry{
        mk.e(0, "judge", 200, "J-LATE"),
        mk.e(1, "narrator", 100, "N"),
        mk.e(2, "judge", 100, "J-EARLY"),
        mk.e(3, "", 100, "NAMELESS"),
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    // Groups keyed in descending-scan first-seen order (judge's order-200 entry leads), and outlet
    // content is push (:5133), so within judge the descending scan keeps J-LATE ahead of J-EARLY.
    try testing.expectEqual(@as(usize, 2), act.outlets.len);
    try testing.expectEqualStrings("judge", act.outlets[0].name);
    try testing.expectEqualStrings("J-LATE\nJ-EARLY", act.outlets[0].content);
    try testing.expectEqualStrings("narrator", act.outlets[1].name);
    try testing.expectEqualStrings("N", act.outlets[1].content);
    try testing.expectEqualStrings("", act.before);
}

test "an entry without keys and without constant never fires" {
    const entries = [_]Entry{te(0, &.{}, "GHOST")};
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"anything"});
    defer act.deinit();
    try testing.expectEqualStrings("", act.before);
}

test "caseSensitive gates on exact case per entry and via the global default" {
    var sens = te(0, &.{"GLADE"}, "S");
    sens.case_sensitive = true;
    var fold = te(1, &.{"GLADE"}, "F");
    fold.case_sensitive = false;
    const entries = [_]Entry{ sens, fold };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"the glade"});
    defer act.deinit();
    // The case-sensitive "GLADE" misses lowercase "glade"; the folding entry matches.
    try testing.expectEqualStrings("F", act.before);

    // A null per-entry value falls back to the global (params.case_sensitive).
    const g_entries = [_]Entry{te(2, &.{"GLADE"}, "G")};
    var g = try activate(testing.allocator, .{ .entries = &g_entries, .case_sensitive = true }, &.{"the glade"});
    defer g.deinit();
    try testing.expectEqualStrings("", g.before);
}

test "matchWholeWords bounds a single-word key, a multi-word key stays substring" {
    var whole = te(0, &.{"cat"}, "W");
    whole.match_whole_words = true;
    const one = [_]Entry{whole};
    var miss = try activate(testing.allocator, .{ .entries = &one }, &.{"concatenate"});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
    var hit = try activate(testing.allocator, .{ .entries = &one }, &.{"the cat sat"});
    defer hit.deinit();
    try testing.expectEqualStrings("W", hit.before);

    // Stock: a multi-word key (keyWords.length > 1) ignores boundaries and plain-contains.
    var multi = te(1, &.{"safe haven"}, "M");
    multi.match_whole_words = true;
    const two = [_]Entry{multi};
    var m = try activate(testing.allocator, .{ .entries = &two }, &.{"a safe havenland"});
    defer m.deinit();
    try testing.expectEqualStrings("M", m.before);
}

test "per-entry scanDepth bounds an entry's own key window" {
    var shallow = te(0, &.{"old"}, "S");
    shallow.scan_depth = 1;
    var deep = te(1, &.{"old"}, "D");
    deep.scan_depth = 2;
    const entries = [_]Entry{ shallow, deep };
    // Oldest-first history; "old" appears only in the older message.
    var act = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 5 }, &.{ "mentions old", "newest" });
    defer act.deinit();
    // The scanDepth-1 entry sees only "newest" (no match); the scanDepth-2 entry sees both.
    try testing.expectEqualStrings("D", act.before);
}

test "atDepth entries at one depth split into separate groups by role" {
    var sys = te(0, &.{}, "SYS");
    sys.constant = true;
    sys.position = .at_depth;
    sys.depth = 3;
    sys.role = 0;
    var usr = te(1, &.{}, "USR");
    usr.constant = true;
    usr.position = .at_depth;
    usr.depth = 3;
    usr.role = 1;
    const entries = [_]Entry{ sys, usr };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    try testing.expectEqual(@as(usize, 2), act.at_depth.len);
    var saw_sys = false;
    var saw_usr = false;
    for (act.at_depth) |grp| {
        if (grp.role == 0) {
            saw_sys = true;
            try testing.expectEqualStrings("SYS", grp.content);
        }
        if (grp.role == 1) {
            saw_usr = true;
            try testing.expectEqualStrings("USR", grp.content);
        }
    }
    try testing.expect(saw_sys and saw_usr);
}

test "activate cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var recurse_a = te(0, &.{"dragon"}, "the ember hoard");
            recurse_a.position = .at_depth;
            var b = te(1, &.{"ember"}, "SECOND");
            b.position = .em_top;
            var c = te(2, &.{}, "CONST");
            c.constant = true;
            var d = te(3, &.{}, "OUT");
            d.constant = true;
            d.position = .outlet;
            d.outlet_name = "gate";
            const entries = [_]Entry{ recurse_a, b, c, d };
            var act = try activate(alloc, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
            act.deinit();
        }
    }.run, .{});
}

test "activate never panics on arbitrary scan bytes" {
    var prng = std.Random.DefaultPrng.init(0xacc07);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    const entries = [_]Entry{ te(0, &.{"a"}, "X"), te(1, &.{"\x01"}, "Y") };
    for (0..2000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        var act = try activate(testing.allocator, .{ .entries = &entries }, &.{buf[0..len]});
        act.deinit();
    }
}
