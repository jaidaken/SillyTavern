//! The card/persona macro resolver: `{{char}}`, `{{user}}`, `{{description}}` and friends.
//!
//! Split out of generate.zig so templates.zig can run a macro pass INSIDE the story-string render
//! without a circular import (renderStoryString resolves a field, and the resolved value carries its
//! own macros: a `system` of "You are {{char}}." must still become the character's name). The
//! dependency order is macros <- templates <- generate, a plain DAG.
//!
//! zx-free, so `zig build test` proves it natively (ZX5).

const std = @import("std");

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
/// Deliberately NOT the STscript engine: the pure card/persona set plus `{{newline}}`. Dynamic
/// macros (time/date/roll) are impure and intentionally excluded this phase.
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

const testing = std.testing;

test "substituteMacros resolves the card and persona set every occurrence" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .persona = "a diver", .description = "d", .personality = "warm", .scenario = "a wreck", .mes_example = "ex" };
    const out = try substituteMacros(testing.allocator, "{{char}} to {{user}} ({{persona}}); {{char}} waits.{{newline}}end", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita to Jamie (a diver); Rita waits.\nend", out);
}

test "substituteMacros keeps an unknown macro and a dangling brace verbatim" {
    const ctx = Ctx{ .char = "Rita" };
    const out = try substituteMacros(testing.allocator, "{{char}} {{roll:2}} {{unknown}} {{oops", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita {{roll:2}} {{unknown}} {{oops", out);
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
