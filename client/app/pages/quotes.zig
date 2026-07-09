//! Wraps quoted dialogue in <q> so it can be coloured, matching SillyTavern's regex at
//! public/script.js:1846. Runs before md4c: the emitted tags are inline HTML that md4c
//! passes through, and DOMPurify allows <q> by default.
//!
//! Alternation order is load-bearing. Code fences, inline code, <style> blocks and raw tags
//! are consumed first, so a quote character inside any of them is never wrapped.

const std = @import("std");

const Pair = struct { open: []const u8, close: []const u8 };

/// Straight, curly, guillemets, corner and fullwidth. The same six ST recognises.
const pairs = [_]Pair{
    .{ .open = "\"", .close = "\"" },
    .{ .open = "\u{201C}", .close = "\u{201D}" },
    .{ .open = "\u{00AB}", .close = "\u{00BB}" },
    .{ .open = "\u{300C}", .close = "\u{300D}" },
    .{ .open = "\u{300E}", .close = "\u{300F}" },
    .{ .open = "\u{FF02}", .close = "\u{FF02}" },
};

/// A quote never spans a newline, mirroring the non-dotall `.` in ST's regex.
fn closeBefore(src: []const u8, from: usize, close: []const u8) ?usize {
    const stop = std.mem.indexOfPos(u8, src, from, "\n") orelse src.len;
    const at = std.mem.indexOfPos(u8, src, from, close) orelse return null;
    return if (at < stop) at else null;
}

/// Caller owns the result. OOM propagates so `checkAllAllocationFailures` can prove every path.
pub fn wrap(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, src.len);

    var i: usize = 0;
    outer: while (i < src.len) {
        const rest = src[i..];

        if (std.mem.startsWith(u8, rest, "<style")) {
            const end = std.mem.indexOfPos(u8, src, i, "</style>") orelse src.len;
            const stop = @min(end + "</style>".len, src.len);
            try out.appendSlice(allocator, src[i..stop]);
            i = stop;
            continue;
        }

        for ([_][]const u8{ "```", "~~~" }) |fence| {
            if (std.mem.startsWith(u8, rest, fence)) {
                const end = std.mem.indexOfPos(u8, src, i + fence.len, fence) orelse src.len;
                const stop = @min(end + fence.len, src.len);
                try out.appendSlice(allocator, src[i..stop]);
                i = stop;
                continue :outer;
            }
        }

        if (rest[0] == '`') {
            const end = std.mem.indexOfPos(u8, src, i + 1, "`") orelse src.len;
            const stop = @min(end + 1, src.len);
            try out.appendSlice(allocator, src[i..stop]);
            i = stop;
            continue;
        }

        if (rest[0] == '<') {
            const end = std.mem.indexOfPos(u8, src, i, ">") orelse src.len;
            const stop = @min(end + 1, src.len);
            try out.appendSlice(allocator, src[i..stop]);
            i = stop;
            continue;
        }

        for (pairs) |p| {
            if (!std.mem.startsWith(u8, rest, p.open)) continue;
            const body_start = i + p.open.len;
            const close_at = closeBefore(src, body_start, p.close) orelse break;
            if (close_at == body_start) break;

            try out.appendSlice(allocator, "<q>");
            try out.appendSlice(allocator, src[i .. close_at + p.close.len]);
            try out.appendSlice(allocator, "</q>");
            i = close_at + p.close.len;
            continue :outer;
        }

        try out.append(allocator, rest[0]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn expectWrap(src: []const u8, want: []const u8) !void {
    const got = try wrap(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "wrap_recognises_all_six_quote_forms" {
    try expectWrap("\"a\"", "<q>\"a\"</q>");
    try expectWrap("\u{201C}a\u{201D}", "<q>\u{201C}a\u{201D}</q>");
    try expectWrap("\u{00AB}a\u{00BB}", "<q>\u{00AB}a\u{00BB}</q>");
    try expectWrap("\u{300C}a\u{300D}", "<q>\u{300C}a\u{300D}</q>");
    try expectWrap("\u{300E}a\u{300F}", "<q>\u{300E}a\u{300F}</q>");
    try expectWrap("\u{FF02}a\u{FF02}", "<q>\u{FF02}a\u{FF02}</q>");
}

test "wrap_skips_quotes_inside_inline_code" {
    try expectWrap("`\"hi\"`", "`\"hi\"`");
}

test "wrap_skips_quotes_inside_backtick_and_tilde_fences" {
    try expectWrap("```\n\"hi\"\n```", "```\n\"hi\"\n```");
    try expectWrap("~~~\n\"hi\"\n~~~", "~~~\n\"hi\"\n~~~");
}

test "wrap_skips_quotes_inside_tags_and_style_blocks" {
    try expectWrap("<img alt=\"x\">", "<img alt=\"x\">");
    try expectWrap("<style>a[b=\"c\"]{}</style>", "<style>a[b=\"c\"]{}</style>");
}

test "wrap_leaves_an_unpaired_quote_untouched" {
    try expectWrap("a \" b", "a \" b");
    try expectWrap("\"unterminated", "\"unterminated");
}

test "wrap_refuses_to_span_a_newline" {
    try expectWrap("\"a\nb\"", "\"a\nb\"");
}

test "wrap_ignores_an_empty_quote" {
    try expectWrap("\"\"", "\"\"");
}

test "wrap_marks_each_quote_on_a_shared_line" {
    try expectWrap("\"a\" and \"b\"", "<q>\"a\"</q> and <q>\"b\"</q>");
}

test "wrap_preserves_surrounding_prose" {
    try expectWrap("She said \"go\" firmly.", "She said <q>\"go\"</q> firmly.");
}

fn wrapAndDiscard(allocator: std.mem.Allocator, src: []const u8) !void {
    const out = try wrap(allocator, src);
    defer allocator.free(out);
    try testing.expect(out.len >= src.len);
}

test "wrap_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, wrapAndDiscard, .{"She said \"go\" and \u{201C}stop\u{201D} `\"x\"`"});
}

test "wrap_never_panics_on_random_bytes" {
    var prng = std.Random.DefaultPrng.init(0x5177_0715);
    const rand = prng.random();
    const alphabet = "\"`<>~ \n\u{201C}\u{201D}abc";

    var buf: [64]u8 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*ch| ch.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const out = try wrap(testing.allocator, buf[0..n]);
        defer testing.allocator.free(out);
        try testing.expect(out.len >= n);
    }
}
