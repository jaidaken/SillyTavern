//! The card/persona macro resolver: `{{char}}`, `{{user}}`, `{{description}}` and friends.
//!
//! Split out of generate.zig so templates.zig can run a macro pass INSIDE the story-string render
//! without a circular import (renderStoryString resolves a field, and the resolved value carries its
//! own macros: a `system` of "You are {{char}}." must still become the character's name). The
//! dependency order is macros <- templates <- generate, a plain DAG.
//!
//! zx-free, so `zig build test` proves it natively (ZX5).

const std = @import("std");

const rng = @import("rng.zig");

const Allocator = std.mem.Allocator;

/// The values the card/persona macros resolve to, and the fields a context template's story string
/// addresses by name. Everything is borrowed; the caller (char_api) keeps the backing strings alive
/// across the assembly call.
///
/// The set is wider than the macro list because a story string reads fields a macro never exposed:
/// `system` (the system prompt), `wi_before`/`wi_after` (world-info blocks, empty until 3b lands),
/// and `anchor_before`/`anchor_after` (the author's-note anchors, which is how 2c reaches the
/// prompt). An absent field is an empty string, which is what makes `{{#if field}}` drop its block.
pub const Ctx = struct {
    char: []const u8 = "",
    user: []const u8 = "",
    persona: []const u8 = "",
    description: []const u8 = "",
    personality: []const u8 = "",
    scenario: []const u8 = "",
    mes_example: []const u8 = "",
    system: []const u8 = "",
    /// The global system prompt content, for `{{original}}` inside a card's system_prompt override
    /// (stock substituteParams `{ original: sysprompt.content }`, script.js:4661).
    original: []const u8 = "",
    wi_before: []const u8 = "",
    wi_after: []const u8 = "",
    anchor_before: []const u8 = "",
    anchor_after: []const u8 = "",
    /// Named world-info outlets for `{{outlet::name}}` (stock macros.js:615), keyed by outletName.
    outlets: []const Outlet = &.{},
    /// The open chat's file id, for `{{pick}}`'s deterministic seed (stock getChatIdHash, macros.js:262:
    /// chat_metadata.main_chat ?? the current chat id). Empty until a caller feeds it.
    chat_id: []const u8 = "",
    /// Entropy for the genuinely-random `{{roll}}`/`{{random}}`. Null draws deterministically (0.0),
    /// mirroring the world-info engine's null-rng fallback (world_info_engine.zig:414).
    rng: ?std.Random = null,

    fn outletByName(self: Ctx, name: []const u8) ?[]const u8 {
        for (self.outlets) |o| {
            if (std.mem.eql(u8, o.name, name)) return o.content;
        }
        return null;
    }
};

/// One named outlet's joined content. Lives here because Ctx owns the field the story string reads.
pub const Outlet = struct {
    name: []const u8,
    content: []const u8,
};

/// The resolvable macro name -> value, or null for a name this narrow resolver does not know (the
/// caller keeps the literal untouched, so an unknown `{{macro}}` survives rather than blanking).
/// Deliberately NOT the STscript engine: the pure card/persona set plus `{{newline}}`. The impure
/// `{{roll}}`/`{{random}}`/`{{pick}}` are handled directly in substituteMacros, not here, because
/// they parse args and need the Ctx entropy/chat id rather than a name-to-value lookup.
///
/// The story-string spellings are the classic client's camelCase (`wiBefore`), and the aliases
/// `loreBefore`/`loreAfter` are accepted because the stock templates offer both (script.js:4680).
pub fn resolve(name: []const u8, ctx: Ctx) ?[]const u8 {
    // {{//comment}} is stripped (empty), matching stock (macros.js:606); cards routinely carry
    // `{{// author note}}` and the old resolver left it LITERAL in the prompt.
    if (std.mem.startsWith(u8, name, "//")) return "";
    if (std.mem.eql(u8, name, "char")) return ctx.char;
    if (std.mem.eql(u8, name, "user")) return ctx.user;
    if (std.mem.eql(u8, name, "persona")) return ctx.persona;
    if (std.mem.eql(u8, name, "description")) return ctx.description;
    if (std.mem.eql(u8, name, "personality")) return ctx.personality;
    if (std.mem.eql(u8, name, "scenario")) return ctx.scenario;
    if (std.mem.eql(u8, name, "mesExamples")) return ctx.mes_example;
    if (std.mem.eql(u8, name, "system")) return ctx.system;
    if (std.mem.eql(u8, name, "original")) return ctx.original;
    if (std.mem.eql(u8, name, "wiBefore")) return ctx.wi_before;
    if (std.mem.eql(u8, name, "wiAfter")) return ctx.wi_after;
    if (std.mem.eql(u8, name, "loreBefore")) return ctx.wi_before;
    if (std.mem.eql(u8, name, "loreAfter")) return ctx.wi_after;
    if (std.mem.eql(u8, name, "anchorBefore")) return ctx.anchor_before;
    if (std.mem.eql(u8, name, "anchorAfter")) return ctx.anchor_after;
    if (std.mem.eql(u8, name, "newline")) return "\n";
    return null;
}

/// Substitutes every known `{{macro}}` in `text` in one pass. An unknown macro is left verbatim, an
/// unterminated `{{` is copied through, and a `name:args` form resolves on the bare name (args are
/// ignored this phase). Owned result.
///
/// One pass, not a fixpoint: a resolved value is copied out verbatim, so a card whose description is
/// literally "{{description}}" cannot recurse. templates.zig gets its nested pass by calling this
/// again on the rendered output, which is bounded the same way.
pub fn substituteMacros(alloc: Allocator, text: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            if (std.mem.indexOfPos(u8, text, i + 2, "}}")) |close| {
                const raw = text[i + 2 .. close];
                // stock computes {{pick}}'s offset post-earlier-macro-expansion; single-pass uses the
                // original-text offset, see section-file IMPURE MACROS. Isolated for a later swap.
                const pick_offset = i;
                if (try tryImpureMacro(alloc, &out, raw, text, pick_offset, ctx)) {
                    i = close + 2;
                    continue;
                }
                const inner = std.mem.trim(u8, text[i + 2 .. close], " \t");
                if (outletKey(inner)) |key| {
                    // Stock renders '' for a key no outlet feeds (macros.js:615 getOutletPrompt).
                    try out.appendSlice(alloc, ctx.outletByName(key) orelse "");
                    i = close + 2;
                    continue;
                }
                const bare = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, inner, ':')) |c| inner[0..c] else inner, " \t");
                if (resolve(bare, ctx)) |val| {
                    try out.appendSlice(alloc, val);
                } else {
                    try out.appendSlice(alloc, text[i .. close + 2]);
                }
                i = close + 2;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The `{{outlet::name}}` key, or null when `inner` is not a named-outlet macro. Stock's regex
/// (macros.js:615, /{{outlet::(.+?)}}/) needs the double colon and a nonempty key; anything else
/// falls through to the generic resolver.
fn outletKey(inner: []const u8) ?[]const u8 {
    const prefix = "outlet::";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    const key = std.mem.trim(u8, inner[prefix.len..], " \t");
    return if (key.len == 0) null else key;
}

/// Handles a `{{roll}}`/`{{random}}`/`{{pick}}` at `raw` (the text between `{{` and `}}`), appending
/// its result and returning true. Returns false when `raw` is not one of these, so the caller falls
/// through to the card/outlet resolver. `text`+`offset` seed `{{pick}}`; `ctx.rng` drives the random
/// pair (stock getDiceRollMacro/getRandomReplaceMacro/getPickReplaceMacro, macros.js:438-519).
fn tryImpureMacro(alloc: Allocator, out: *std.ArrayList(u8), raw: []const u8, text: []const u8, offset: usize, ctx: Ctx) Allocator.Error!bool {
    if (matchRoll(raw)) |formula_raw| {
        try appendRoll(alloc, out, formula_raw, ctx);
        return true;
    }
    if (matchListMacro(raw, "random")) |list_string| {
        const count = listItemCount(list_string);
        const r: f64 = if (ctx.rng) |rr| rr.float(f64) else 0.0;
        const idx: usize = @intFromFloat(@floor(r * @as(f64, @floatFromInt(count))));
        try appendListItem(alloc, out, list_string, if (idx >= count) count - 1 else idx);
        return true;
    }
    if (matchListMacro(raw, "pick")) |list_string| {
        const count = listItemCount(list_string);
        const idx = rng.pickIndex(ctx.chat_id, text, offset, count);
        try appendListItem(alloc, out, list_string, if (idx >= count) count - 1 else idx);
        return true;
    }
    return false;
}

/// The formula of a `{{roll<sep>F}}`, or null. Separator is one space or colon (stock `[ : ]`), the
/// capture is `[^}]+`. Untrimmed; appendRoll trims like stock's `matchValue.trim()`.
fn matchRoll(raw: []const u8) ?[]const u8 {
    if (raw.len < 5) return null;
    if (!std.ascii.eqlIgnoreCase(raw[0..4], "roll")) return null;
    if (raw[4] != ' ' and raw[4] != ':') return null;
    const cap = raw[5..];
    if (cap.len == 0 or std.mem.indexOfScalar(u8, cap, '}') != null) return null;
    return cap;
}

/// The list string of a `{{<keyword><sep>LIST}}`, or null. Separator is optional single whitespace,
/// then `:` then optional `:` (stock `\s?::?`); the capture is `[^}]+`.
fn matchListMacro(raw: []const u8, keyword: []const u8) ?[]const u8 {
    if (raw.len < keyword.len) return null;
    if (!std.ascii.eqlIgnoreCase(raw[0..keyword.len], keyword)) return null;
    var p = keyword.len;
    if (p < raw.len and std.ascii.isWhitespace(raw[p])) p += 1;
    if (p >= raw.len or raw[p] != ':') return null;
    p += 1;
    if (p < raw.len and raw[p] == ':') p += 1;
    const cap = raw[p..];
    if (cap.len == 0 or std.mem.indexOfScalar(u8, cap, '}') != null) return null;
    return cap;
}

const Dice = struct { num_dice: u64, num_sides: u64, modifier: i64 };

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isDigitsOnly(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

/// Parses a droll formula (droll.js:58, `^([1-9]\d*)?d([1-9]\d*)([+-]\d+)?$`, case-insensitive `d`),
/// with the digits-only shortcut that becomes `1dF` (getDiceRollMacro). Null on any invalid formula.
fn parseDice(formula: []const u8) ?Dice {
    if (isDigitsOnly(formula)) {
        if (formula[0] == '0') return null;
        const sides = std.fmt.parseInt(u64, formula, 10) catch return null;
        return .{ .num_dice = 1, .num_sides = sides, .modifier = 0 };
    }
    var p: usize = 0;
    var num_dice: u64 = 1;
    if (formula.len > 0 and formula[0] >= '1' and formula[0] <= '9') {
        var e = p + 1;
        while (e < formula.len and isDigit(formula[e])) e += 1;
        num_dice = std.fmt.parseInt(u64, formula[p..e], 10) catch return null;
        p = e;
    }
    if (p >= formula.len or (formula[p] != 'd' and formula[p] != 'D')) return null;
    p += 1;
    if (p >= formula.len or !(formula[p] >= '1' and formula[p] <= '9')) return null;
    var e2 = p + 1;
    while (e2 < formula.len and isDigit(formula[e2])) e2 += 1;
    const sides = std.fmt.parseInt(u64, formula[p..e2], 10) catch return null;
    p = e2;
    var modifier: i64 = 0;
    if (p < formula.len and (formula[p] == '+' or formula[p] == '-')) {
        const neg = formula[p] == '-';
        p += 1;
        if (p >= formula.len or !isDigit(formula[p])) return null;
        var e3 = p + 1;
        while (e3 < formula.len and isDigit(formula[e3])) e3 += 1;
        const m = std.fmt.parseInt(i64, formula[p..e3], 10) catch return null;
        modifier = if (neg) -m else m;
        p = e3;
    }
    if (p != formula.len) return null;
    return .{ .num_dice = num_dice, .num_sides = sides, .modifier = modifier };
}

/// Rolls the formula and appends `String(total)`; an invalid formula appends nothing (stock returns '').
fn appendRoll(alloc: Allocator, out: *std.ArrayList(u8), formula_raw: []const u8, ctx: Ctx) Allocator.Error!void {
    const formula = std.mem.trim(u8, formula_raw, &std.ascii.whitespace);
    const dice = parseDice(formula) orelse return;
    var total: i64 = 0;
    var k: u64 = 0;
    while (k < dice.num_dice) : (k += 1) {
        const r: f64 = if (ctx.rng) |rr| rr.float(f64) else 0.0;
        total += 1 + @as(i64, @intFromFloat(@floor(r * @as(f64, @floatFromInt(dice.num_sides)))));
    }
    total += dice.modifier;
    try appendDecI64(alloc, out, total);
}

fn appendDecI64(alloc: Allocator, out: *std.ArrayList(u8), val: i64) Allocator.Error!void {
    if (val == 0) {
        try out.append(alloc, '0');
        return;
    }
    if (val < 0) try out.append(alloc, '-');
    var mag: u64 = if (val < 0) @as(u64, @intCast(-(val + 1))) + 1 else @intCast(val);
    var digits: [20]u8 = undefined;
    var k: usize = 0;
    while (mag > 0) : (mag /= 10) {
        digits[k] = @intCast('0' + mag % 10);
        k += 1;
    }
    while (k > 0) {
        k -= 1;
        try out.append(alloc, digits[k]);
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| {
        n += 1;
        at = found + needle.len;
    }
    return n;
}

/// The number of items a list string splits into: `::` present -> count on `::`; else on unescaped
/// commas (a `\,` is a literal comma, not a separator). Stock split always yields >= 1.
fn listItemCount(s: []const u8) usize {
    if (std.mem.indexOf(u8, s, "::") != null) return countOccurrences(s, "::") + 1;
    var n: usize = 1;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == ',') {
            i += 2;
            continue;
        }
        if (s[i] == ',') n += 1;
        i += 1;
    }
    return n;
}

/// Appends the `idx`-th list item. `::` mode is verbatim (no trim/unescape); comma mode trims each
/// item and turns `\,` back into `,`, matching getRandomReplaceMacro/getPickReplaceMacro.
fn appendListItem(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8, idx: usize) Allocator.Error!void {
    if (std.mem.indexOf(u8, s, "::") != null) {
        try out.appendSlice(alloc, doubleColonItem(s, idx));
        return;
    }
    var start: usize = 0;
    var n: usize = 0;
    var i: usize = 0;
    var found_start: usize = 0;
    var found_end: usize = s.len;
    while (i <= s.len) {
        if (i < s.len and s[i] == '\\' and i + 1 < s.len and s[i + 1] == ',') {
            i += 2;
            continue;
        }
        if (i == s.len or s[i] == ',') {
            if (n == idx) {
                found_start = start;
                found_end = i;
                break;
            }
            n += 1;
            if (i == s.len) break;
            start = i + 1;
        }
        i += 1;
    }
    const trimmed = std.mem.trim(u8, s[found_start..found_end], &std.ascii.whitespace);
    var j: usize = 0;
    while (j < trimmed.len) {
        if (trimmed[j] == '\\' and j + 1 < trimmed.len and trimmed[j + 1] == ',') {
            try out.append(alloc, ',');
            j += 2;
        } else {
            try out.append(alloc, trimmed[j]);
            j += 1;
        }
    }
}

fn doubleColonItem(s: []const u8, idx: usize) []const u8 {
    var start: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, s, start, "::")) |pos| {
        if (n == idx) return s[start..pos];
        n += 1;
        start = pos + 2;
    }
    return s[start..];
}

const testing = std.testing;

test "substituteMacros resolves the card and persona set every occurrence" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .persona = "a diver", .description = "d", .personality = "warm", .scenario = "a wreck", .mes_example = "ex" };
    const out = try substituteMacros(testing.allocator, "{{char}} to {{user}} ({{persona}}); {{char}} waits.{{newline}}end", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita to Jamie (a diver); Rita waits.\nend", out);
}

test "substituteMacros keeps an unknown macro and a dangling brace verbatim" {
    const ctx = Ctx{ .char = "Rita" };
    const out = try substituteMacros(testing.allocator, "{{char}} {{time}} {{unknown}} {{oops", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita {{time}} {{unknown}} {{oops", out);
}

test "an impure macro with no valid separator stays verbatim" {
    const ctx = Ctx{ .chat_id = "c" };
    const out = try substituteMacros(testing.allocator, "{{roll:}} {{pick}} {{random}} {{pickle}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{{roll:}} {{pick}} {{random}} {{pickle}}", out);
}

test "substituteMacros resolves the story-string field names and their lore aliases" {
    const ctx = Ctx{ .system = "Be terse.", .wi_before = "WB", .wi_after = "WA", .anchor_before = "AB", .anchor_after = "AA" };
    const out = try substituteMacros(testing.allocator, "{{system}}|{{wiBefore}}|{{wiAfter}}|{{loreBefore}}|{{loreAfter}}|{{anchorBefore}}|{{anchorAfter}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Be terse.|WB|WA|WB|WA|AB|AA", out);
}

test "substituteMacros resolves {{original}} to the global system prompt" {
    const ctx = Ctx{ .original = "GLOBAL", .char = "Rita" };
    const out = try substituteMacros(testing.allocator, "Card says {{original}} for {{char}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Card says GLOBAL for Rita", out);
}

test "substituteMacros routes outlet macros per name and blanks an unfed key" {
    const outlets = [_]Outlet{
        .{ .name = "judge", .content = "J1\nJ2" },
        .{ .name = "narrator", .content = "N" },
    };
    const ctx = Ctx{ .char = "Rita", .outlets = &outlets };
    const out = try substituteMacros(testing.allocator, "a {{outlet::judge}} b {{outlet::narrator}} c {{outlet::nobody}} d", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a J1\nJ2 b N c  d", out);
}

test "a bare or empty-keyed outlet macro stays verbatim like any unknown macro" {
    const outlets = [_]Outlet{.{ .name = "judge", .content = "J" }};
    const ctx = Ctx{ .outlets = &outlets };
    const out = try substituteMacros(testing.allocator, "{{outlet}}|{{outlet::}}|{{outlet:judge}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{{outlet}}|{{outlet::}}|{{outlet:judge}}", out);
}

test "substituteMacros does not recurse into a resolved value" {
    const ctx = Ctx{ .char = "Rita", .description = "{{char}}" };
    const out = try substituteMacros(testing.allocator, "{{description}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{{char}}", out);
}

test "substituteMacros cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const out = try substituteMacros(alloc, "{{char}} meets {{user}}{{newline}}", c);
            alloc.free(out);
        }
    }.run, .{ctx});
}

test "substituteMacros never panics or leaks on arbitrary bytes" {
    var prng = std.Random.DefaultPrng.init(0xacc05);
    const rand = prng.random();
    var buf: [96]u8 = undefined;
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    for (0..5000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        const out = try substituteMacros(testing.allocator, buf[0..len], ctx);
        testing.allocator.free(out);
    }
}

fn rollTotal(text: []const u8, r: std.Random) !i64 {
    const out = try substituteMacros(testing.allocator, text, .{ .rng = r });
    defer testing.allocator.free(out);
    return std.fmt.parseInt(i64, out, 10);
}

test "roll stays within the droll range across many seeded draws" {
    var prng = std.Random.DefaultPrng.init(0xd101);
    const rand = prng.random();
    for (0..3000) |_| {
        try testing.expect((try rollTotal("{{roll:2d6+1}}", rand)) >= 3);
        try testing.expect((try rollTotal("{{roll:2d6+1}}", rand)) <= 13);
        const d100 = try rollTotal("{{roll:100}}", rand);
        try testing.expect(d100 >= 1 and d100 <= 100);
        const dneg = try rollTotal("{{roll:3d4-2}}", rand);
        try testing.expect(dneg >= 1 and dneg <= 10);
    }
}

test "roll accepts the digits-only shortcut and a bare d form" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    const one = try rollTotal("{{roll 1}}", rand);
    try testing.expectEqual(@as(i64, 1), one);
    const bare_d = try rollTotal("{{roll:d1}}", rand);
    try testing.expectEqual(@as(i64, 1), bare_d);
}

test "an invalid roll formula resolves to empty" {
    const cases = [_][]const u8{ "{{roll:abc}}", "{{roll:0}}", "{{roll:2d}}", "{{roll:d0}}", "{{roll:1.5}}" };
    var prng = std.Random.DefaultPrng.init(1);
    for (cases) |c| {
        const out = try substituteMacros(testing.allocator, c, .{ .rng = prng.random() });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("", out);
    }
}

test "random always yields a member of the split list" {
    var prng = std.Random.DefaultPrng.init(0x4a4de);
    const rand = prng.random();
    for (0..3000) |_| {
        const out = try substituteMacros(testing.allocator, "{{random::red::green::blue}}", .{ .rng = rand });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.eql(u8, out, "red") or std.mem.eql(u8, out, "green") or std.mem.eql(u8, out, "blue"));
    }
    for (0..3000) |_| {
        const out = try substituteMacros(testing.allocator, "{{random: x, y, z}}", .{ .rng = rand });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.eql(u8, out, "x") or std.mem.eql(u8, out, "y") or std.mem.eql(u8, out, "z"));
    }
}

test "pick reproduces the stock golden item end to end" {
    const a = try substituteMacros(testing.allocator, "You see {{pick::red::green::blue}} ahead.", .{ .chat_id = "Chat_2024-01-15@10h30m" });
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("You see red ahead.", a);

    const b = try substituteMacros(testing.allocator, "{{pick: sword, shield, bow, staff}}", .{ .chat_id = "default" });
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("shield", b);

    const c = try substituteMacros(testing.allocator, "single {{pick::only}}", .{ .chat_id = "Chat_2024-01-15@10h30m" });
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("single only", c);
}

test "pick is stable for the same chat, content and offset" {
    const first = try substituteMacros(testing.allocator, "a {{pick::x::y::z}} b", .{ .chat_id = "room-7" });
    defer testing.allocator.free(first);
    const second = try substituteMacros(testing.allocator, "a {{pick::x::y::z}} b", .{ .chat_id = "room-7" });
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "list split counts items on double colon and unescaped commas" {
    try testing.expectEqual(@as(usize, 3), listItemCount("a::b::c"));
    try testing.expectEqual(@as(usize, 3), listItemCount("a,b,c"));
    try testing.expectEqual(@as(usize, 2), listItemCount("a\\,b,c"));
    try testing.expectEqual(@as(usize, 1), listItemCount("only"));
}

fn itemAt(s: []const u8, idx: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try appendListItem(testing.allocator, &out, s, idx);
    return out.toOwnedSlice(testing.allocator);
}

test "comma items are trimmed and unescaped, double-colon items are verbatim" {
    const esc0 = try itemAt("a\\,b, c ", 0);
    defer testing.allocator.free(esc0);
    try testing.expectEqualStrings("a,b", esc0);
    const esc1 = try itemAt("a\\,b, c ", 1);
    defer testing.allocator.free(esc1);
    try testing.expectEqualStrings("c", esc1);

    const dc = try itemAt("a:: b ::c", 1);
    defer testing.allocator.free(dc);
    try testing.expectEqualStrings(" b ", dc);
}

test "the impure macros clean up on every allocation failure" {
    var prng = std.Random.DefaultPrng.init(99);
    const ctx = Ctx{ .chat_id = "room-7", .rng = prng.random() };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const out = try substituteMacros(alloc, "roll {{roll:2d6+1}} rand {{random: a\\,b, c}} pick {{pick::x::y::z}} done", c);
            alloc.free(out);
        }
    }.run, .{ctx});
}
