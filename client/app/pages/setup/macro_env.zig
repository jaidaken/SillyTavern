//! The environment and core-scalar macro resolver: `{{model}}`, `{{maxContext}}`, `{{if}}` and friends.
//!
//! Sibling of macros.zig, which owns the card/persona set. This module owns the STATE/UTILITY macros
//! the classic client reads off the running app (env-macros.js, state-macros.js, instruct-macros.js,
//! core-macros.js): the caller resolves those values once, hands them over in an `Env`, and this file
//! turns a macro body into the string the model would see.
//!
//! Pure: std only, no zx, no DOM, no globals, so `zig build test` proves it natively.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The invisible marker `{{else}}` resolves to (core-macros.js ELSE_MARKER). The classic engine emits
/// it from `{{else}}` and the enclosing `{{if}}` splits its content on it; `resolve` keeps both halves
/// of that contract, so an `{{else}}` resolved before its `{{if}}` still selects the else branch.
pub const ELSE_MARKER = "\x00\x1FELSE\x1F\x00";

/// The already-resolved environment values the macros below read. Everything is borrowed; the caller
/// keeps the backing strings alive across the `resolve` call, and `resolve` never returns a slice into
/// this struct.
///
/// The name lists are lists, not the classic client's pre-joined strings: joining is this module's job
/// (MacroEnvBuilder.js:207 joins with ", "), so a caller only has to collect the names it already has.
pub const Env = struct {
    model: []const u8 = "",
    system_prompt: []const u8 = "",
    group_members: []const []const u8 = &.{},
    group_not_muted: []const []const u8 = &.{},
    not_char: []const []const u8 = &.{},
    input: []const u8 = "",
    max_context: usize = 0,
    max_prompt: usize = 0,
    max_response: usize = 0,
    is_mobile: bool = false,
    last_generation_type: []const u8 = "normal",
};

/// The resolved value of the macro body `inner` (the trimmed text between `{{` and `}}`, arguments
/// included), or null for a body this resolver does not know so the caller can fall through to another
/// resolver and leave an unknown macro literal.
///
/// THE CALLER OWNS THE RETURNED MEMORY and must free it with the same allocator. The result is always a
/// fresh allocation, never a slice into `env` or into `inner`.
///
/// Known bodies: `model`, `systemPrompt`, `group`, `groupNotMuted`, `notChar`, `isMobile`,
/// `lastGenerationType`, `input`, `maxContext`, `maxPrompt`, `maxResponse`, `banned::<text>`,
/// `hasExtension::<name>`, `if::<condition>::<then>::<else>` and `else::<text>`.
///
/// ```
/// const out = (try resolve(alloc, "maxContext", .{ .max_context = 4096 })).?;
/// defer alloc.free(out);
/// try std.testing.expectEqualStrings("4096", out);
/// ```
pub fn resolve(alloc: Allocator, inner: []const u8, env: Env) Allocator.Error!?[]u8 {
    const call = parseCall(std.mem.trim(u8, inner, &std.ascii.whitespace));

    // Banned words reach the backend through a side channel this client does not have, so only the
    // visible output survives the port: the classic handler also returns '' (core-macros.js:439).
    if (std.mem.eql(u8, call.name, "banned")) return try alloc.dupe(u8, "");
    // No extension registry exists here, so every extension is absent, which stock reports as "false"
    // rather than as an error (state-macros.js:54, `String(extension?.enabled ?? false)`).
    if (std.mem.eql(u8, call.name, "hasExtension")) return try alloc.dupe(u8, "false");
    if (std.mem.eql(u8, call.name, "else")) return try alloc.dupe(u8, ELSE_MARKER);
    if (std.mem.eql(u8, call.name, "if")) return try resolveIf(alloc, call.args, env);
    if (!call.has_args) return try scalar(alloc, call.name, env);
    return null;
}

/// The value of a zero-argument macro name, or null when the name is not one. Split out because
/// `{{if}}` resolves a bare macro name used as its condition through the same table (core-macros.js:186,
/// which resolves a condition that names a macro taking no required arguments).
fn scalar(alloc: Allocator, name: []const u8, env: Env) Allocator.Error!?[]u8 {
    if (std.mem.eql(u8, name, "model")) return try alloc.dupe(u8, env.model);
    if (std.mem.eql(u8, name, "systemPrompt")) return try alloc.dupe(u8, env.system_prompt);
    if (std.mem.eql(u8, name, "input")) return try alloc.dupe(u8, env.input);
    if (std.mem.eql(u8, name, "lastGenerationType")) return try alloc.dupe(u8, env.last_generation_type);
    if (std.mem.eql(u8, name, "isMobile")) return try alloc.dupe(u8, if (env.is_mobile) "true" else "false");
    if (std.mem.eql(u8, name, "group")) return try joinNames(alloc, env.group_members);
    if (std.mem.eql(u8, name, "groupNotMuted")) return try joinNames(alloc, env.group_not_muted);
    if (std.mem.eql(u8, name, "notChar")) return try joinNames(alloc, env.not_char);
    if (std.mem.eql(u8, name, "maxContext")) return try std.fmt.allocPrint(alloc, "{d}", .{env.max_context});
    if (std.mem.eql(u8, name, "maxPrompt")) return try std.fmt.allocPrint(alloc, "{d}", .{env.max_prompt});
    if (std.mem.eql(u8, name, "maxResponse")) return try std.fmt.allocPrint(alloc, "{d}", .{env.max_response});
    return null;
}

/// The `{{if::condition::then::else}}` value (core-macros.js:160). The condition is falsy when it is
/// empty or reads as a false boolean, a leading `!` inverts it, and the chosen branch is trimmed and
/// dedented like scoped content. A missing branch is an empty branch, so `{{if::0::yes}}` renders "".
///
/// Branches are returned verbatim apart from the trim: nested macros inside them are the caller's pass
/// to make, which is what keeps the untaken branch unresolved the way delayed argument resolution does.
fn resolveIf(alloc: Allocator, args: []const u8, env: Env) Allocator.Error![]u8 {
    var condition = std.mem.trim(u8, argAt(args, 0) orelse "", &std.ascii.whitespace);
    var inverted = false;
    if (condition.len > 0 and condition[0] == '!') {
        inverted = true;
        condition = std.mem.trim(u8, condition[1..], &std.ascii.whitespace);
    }

    const resolved_condition = try scalar(alloc, condition, env);
    defer if (resolved_condition) |c| alloc.free(c);
    if (resolved_condition) |c| condition = c;

    var falsy = condition.len == 0 or isFalseBoolean(condition);
    if (inverted) falsy = !falsy;

    var then_branch = argAt(args, 1) orelse "";
    var else_branch = argAt(args, 2) orelse "";
    if (std.mem.indexOf(u8, then_branch, ELSE_MARKER)) |at| {
        else_branch = then_branch[at + ELSE_MARKER.len ..];
        then_branch = then_branch[0..at];
    }

    return try trimContent(alloc, if (falsy) else_branch else then_branch);
}

/// A macro body split into its name and the raw text of its arguments. The argument separator is the
/// classic lexer's: one run of whitespace, or `:`, or `::` (MacroLexer.js:76/83/84).
const Call = struct {
    name: []const u8,
    args: []const u8,
    has_args: bool,
};

fn parseCall(inner: []const u8) Call {
    var end: usize = 0;
    while (end < inner.len and inner[end] != ':' and !std.ascii.isWhitespace(inner[end])) end += 1;
    const name = inner[0..end];

    var p = end;
    while (p < inner.len and std.ascii.isWhitespace(inner[p])) p += 1;
    const had_space = p > end;
    if (p < inner.len and inner[p] == ':') {
        p += 1;
        if (p < inner.len and inner[p] == ':') p += 1;
        return .{ .name = name, .args = inner[p..], .has_args = true };
    }
    if (had_space and p < inner.len) return .{ .name = name, .args = inner[p..], .has_args = true };
    return .{ .name = name, .args = "", .has_args = false };
}

/// The `idx`-th `::`-separated argument, or null when the call carries fewer. Verbatim, so a branch
/// keeps its own spacing until trimContent decides what to strip.
fn argAt(args: []const u8, idx: usize) ?[]const u8 {
    if (args.len == 0) return if (idx == 0) "" else null;
    var start: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, args, start, "::")) |pos| {
        if (n == idx) return args[start..pos];
        n += 1;
        start = pos + 2;
    }
    return if (n == idx) args[start..] else null;
}

/// The names joined the way the classic environment builder joins them (MacroEnvBuilder.js:207): a
/// comma and a space between members, an empty string for an empty list.
fn joinNames(alloc: Allocator, names: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

/// Mirrors isFalseBoolean (utils.js:1024): trimmed and lowercased, "off" / "false" / "0" are false.
fn isFalseBoolean(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > 5) return false;
    var buf: [5]u8 = undefined;
    const lowered = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    return std.mem.eql(u8, lowered, "off") or std.mem.eql(u8, lowered, "false") or std.mem.eql(u8, lowered, "0");
}

/// Trims a chosen branch the way the engine trims scoped content (MacroEngine.js:372): the indentation
/// of the first non-empty line is removed from every line, then the whole thing is trimmed.
fn trimContent(alloc: Allocator, content: []const u8) Allocator.Error![]u8 {
    if (content.len == 0) return try alloc.dupe(u8, "");
    const base = baseIndent(content);
    if (base == 0) return try alloc.dupe(u8, std.mem.trim(u8, content, &std.ascii.whitespace));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        const indent = leadingIndent(line);
        if (indent >= base) {
            try out.appendSlice(alloc, line[base..]);
        } else {
            try out.appendSlice(alloc, std.mem.trimStart(u8, line, &std.ascii.whitespace));
        }
    }
    return try alloc.dupe(u8, std.mem.trim(u8, out.items, &std.ascii.whitespace));
}

fn leadingIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

fn baseIndent(content: []const u8) usize {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
        return leadingIndent(line);
    }
    return 0;
}

const testing = std.testing;

fn expectMacro(expected: []const u8, inner: []const u8, env: Env) !void {
    const got = (try resolve(testing.allocator, inner, env)) orelse return error.MacroNotResolved;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "the string scalars resolve to their environment values" {
    const env = Env{
        .model = "claude-4",
        .system_prompt = "Be terse.",
        .input = "what now",
        .last_generation_type = "impersonate",
    };
    try expectMacro("claude-4", "model", env);
    try expectMacro("Be terse.", "systemPrompt", env);
    try expectMacro("what now", "input", env);
    try expectMacro("impersonate", "lastGenerationType", env);
}

test "an unset scalar resolves to an empty string rather than to null" {
    try expectMacro("", "model", .{});
    try expectMacro("", "systemPrompt", .{});
    try expectMacro("", "input", .{});
}

test "the name lists join with a comma and a space and blank when empty" {
    const members = [_][]const u8{ "Rita", "Sam", "Vee" };
    const not_muted = [_][]const u8{ "Rita", "Vee" };
    const others = [_][]const u8{"Jamie"};
    const env = Env{ .group_members = &members, .group_not_muted = &not_muted, .not_char = &others };
    try expectMacro("Rita, Sam, Vee", "group", env);
    try expectMacro("Rita, Vee", "groupNotMuted", env);
    try expectMacro("Jamie", "notChar", env);
    try expectMacro("", "group", .{});
    try expectMacro("", "groupNotMuted", .{});
    try expectMacro("", "notChar", .{});
}

test "isMobile renders the boolean as its lowercase word" {
    try expectMacro("true", "isMobile", .{ .is_mobile = true });
    try expectMacro("false", "isMobile", .{ .is_mobile = false });
}

test "the token limits render as decimal integers" {
    const env = Env{ .max_context = 8192, .max_prompt = 7808, .max_response = 384 };
    try expectMacro("8192", "maxContext", env);
    try expectMacro("7808", "maxPrompt", env);
    try expectMacro("384", "maxResponse", env);
    try expectMacro("0", "maxContext", .{});
}

test "banned renders nothing whatever its argument, including none" {
    try expectMacro("", "banned::delve", .{});
    try expectMacro("", "banned::\"delve\"", .{});
    try expectMacro("", "banned", .{});
}

test "hasExtension reports every extension absent" {
    try expectMacro("false", "hasExtension::Summarize", .{});
    try expectMacro("false", "hasExtension::nosuchthing", .{});
    try expectMacro("false", "hasExtension", .{});
}

test "if returns the then branch for a truthy condition and the else branch otherwise" {
    try expectMacro("yes", "if::something::yes::no", .{});
    try expectMacro("no", "if::::yes::no", .{});
    try expectMacro("no", "if::false::yes::no", .{});
    try expectMacro("no", "if:: OFF ::yes::no", .{});
    try expectMacro("no", "if::0::yes::no", .{});
    try expectMacro("yes", "if::0.0::yes::no", .{});
}

test "a leading bang inverts the if condition" {
    try expectMacro("no", "if::!something::yes::no", .{});
    try expectMacro("yes", "if::! ::yes::no", .{});
    try expectMacro("yes", "if::!false::yes::no", .{});
}

test "if resolves a bare macro name used as its condition" {
    try expectMacro("mobile", "if::isMobile::mobile::desktop", .{ .is_mobile = true });
    try expectMacro("desktop", "if::isMobile::mobile::desktop", .{ .is_mobile = false });
    try expectMacro("named", "if::model::named::unnamed", .{ .model = "claude-4" });
    try expectMacro("unnamed", "if::model::named::unnamed", .{ .model = "" });
}

test "a missing if branch renders as empty" {
    try expectMacro("", "if::yes", .{});
    try expectMacro("", "if::0::then", .{});
    try expectMacro("then", "if::1::then", .{});
    try expectMacro("", "if", .{});
}

test "the chosen if branch is trimmed and dedented" {
    try expectMacro("kept", "if::on::  kept  ::other", .{});
    try expectMacro("# Head\nBody", "if::on::  # Head\n  Body\n::other", .{});
    try expectMacro("# Head\n Body", "if::on::  # Head\n   Body::other", .{});
}

test "an else marker inside the then branch splits the branches" {
    try expectMacro("A", "if::on::A" ++ ELSE_MARKER ++ "B", .{});
    try expectMacro("B", "if::::A" ++ ELSE_MARKER ++ "B", .{});
}

test "else renders the invisible marker with or without an argument" {
    try expectMacro(ELSE_MARKER, "else", .{});
    try expectMacro(ELSE_MARKER, "else::anything", .{});
}

test "a body this resolver does not know returns null" {
    try testing.expectEqual(@as(?[]u8, null), try resolve(testing.allocator, "char", .{}));
    try testing.expectEqual(@as(?[]u8, null), try resolve(testing.allocator, "roll::1d6", .{}));
    try testing.expectEqual(@as(?[]u8, null), try resolve(testing.allocator, "model::extra", .{}));
    try testing.expectEqual(@as(?[]u8, null), try resolve(testing.allocator, "", .{}));
}

test "a single colon and a space separate arguments like the classic lexer" {
    try expectMacro("false", "hasExtension:Summarize", .{});
    try expectMacro("false", "hasExtension Summarize", .{});
    try expectMacro("yes", "if:on::yes::no", .{});
}

test "surrounding whitespace in the body does not hide the macro name" {
    try expectMacro("claude-4", "  model  ", .{ .model = "claude-4" });
}

test "resolve cleans up on every allocation failure" {
    const members = [_][]const u8{ "Rita", "Sam", "Vee" };
    const env = Env{
        .model = "claude-4",
        .group_members = &members,
        .max_context = 8192,
        .is_mobile = true,
    };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, e: Env) !void {
            const bodies = [_][]const u8{
                "model",
                "group",
                "maxContext",
                "isMobile",
                "banned::delve",
                "hasExtension::Summarize",
                "else",
                "if::isMobile::  # Head\n  Body\n::other",
                "if::::A" ++ ELSE_MARKER ++ "B",
            };
            for (bodies) |body| {
                const out = (try resolve(alloc, body, e)) orelse return error.MacroNotResolved;
                alloc.free(out);
            }
        }
    }.run, .{env});
}

test "resolve never panics or leaks on arbitrary bytes" {
    var prng = std.Random.DefaultPrng.init(0x3e5f1);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    for (0..5000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        if (try resolve(testing.allocator, buf[0..len], .{})) |out| testing.allocator.free(out);
    }
}
