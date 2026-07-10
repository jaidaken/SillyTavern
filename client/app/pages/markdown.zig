//! Markdown to HTML via md4c. Output is untrusted and MUST cross sanitized.sanitizeHtml before
//! it reaches @escaping={.none}: MD_FLAG_NOHTML is deliberately unset, so author HTML in a
//! message body passes through md4c untouched.
//!
//! Compiled for both targets. On wasm32-freestanding libc_shim supplies the nine libc symbols
//! md4c needs beyond compiler_rt's mem*; natively the exe links real libc.

const std = @import("std");

/// Referenced so its comptime @export block is analyzed; md4c links against those symbols.
const libc_shim = @import("libc_shim");
comptime {
    _ = libc_shim;
}

const c = @cImport({
    @cInclude("md4c-html.h");
});

/// GitHub dialect plus hard line breaks. A single newline becomes <br>, matching showdown's
/// simpleLineBreaks, which roleplay prose depends on.
const parser_flags: c_uint = c.MD_DIALECT_GITHUB | c.MD_FLAG_HARD_SOFT_BREAKS | c.MD_FLAG_LATEXMATHSPANS;

const Sink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    oom: bool = false,
};

fn collect(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(userdata orelse return));
    if (sink.oom) return;
    sink.buf.appendSlice(sink.allocator, text[0..size]) catch {
        sink.oom = true;
    };
}

pub const Error = std.mem.Allocator.Error;

/// Caller owns the result. A md4c parse failure yields a copy of `src` rather than nothing, so a
/// message can never vanish; allocation failure propagates so the alloc-failure oracle can see it.
pub fn toHtml(allocator: std.mem.Allocator, src: []const u8) Error![]const u8 {
    if (src.len == 0) return allocator.alloc(u8, 0);

    // No errdefer: each exit below deinits the sink itself; an errdefer would double-free on OOM.
    var sink = Sink{ .allocator = allocator };

    const rc = c.md_html(
        src.ptr,
        @intCast(src.len),
        collect,
        &sink,
        parser_flags,
        c.MD_HTML_FLAG_SKIP_UTF8_BOM,
    );

    if (sink.oom) {
        sink.buf.deinit(allocator);
        return error.OutOfMemory;
    }
    if (rc != 0) {
        sink.buf.deinit(allocator);
        return allocator.dupe(u8, src);
    }
    return sink.buf.toOwnedSlice(allocator) catch |err| {
        sink.buf.deinit(allocator);
        return err;
    };
}

const testing = std.testing;

fn expectContains(src: []const u8, needle: []const u8) !void {
    const html = try toHtml(testing.allocator, src);
    defer testing.allocator.free(html);
    if (std.mem.indexOf(u8, html, needle) == null) {
        std.debug.print("\nexpected \"{s}\" in:\n{s}\n", .{ needle, html });
        return error.NeedleNotFound;
    }
}

test "toHtml_renders_emphasis_bold_and_strikethrough" {
    try expectContains("*a*", "<em>a</em>");
    try expectContains("**a**", "<strong>a</strong>");
    try expectContains("~~a~~", "<del>a</del>");
}

test "toHtml_turns_a_single_newline_into_a_line_break" {
    try expectContains("a\nb", "<br");
}

test "toHtml_renders_github_tables_and_task_lists" {
    try expectContains("| a | b |\n| --- | --- |\n| 1 | 2 |\n", "<table>");
    try expectContains("- [x] done\n", "checkbox");
}

test "toHtml_tags_a_fenced_block_with_its_language" {
    try expectContains("```zig\nconst a = 1;\n```\n", "language-zig");
}

test "toHtml_passes_author_html_through_unescaped" {
    try expectContains("<span class=\"danger\">x</span>", "<span class=\"danger\">");
    try expectContains("<img src=x onerror=alert(1)>", "onerror");
}

test "toHtml_returns_empty_for_empty_input" {
    const html = try toHtml(testing.allocator, "");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("", html);
}

fn toHtmlAndDiscard(allocator: std.mem.Allocator, src: []const u8) !void {
    const html = try toHtml(allocator, src);
    defer allocator.free(html);
    try testing.expect(html.len > 0);
}

test "toHtml_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, toHtmlAndDiscard, .{"# h\n\n*a* **b**\n\n```zig\nx\n```\n"});
}

test "toHtml_never_panics_on_random_bytes" {
    var prng = std.Random.DefaultPrng.init(0x6d64_3463);
    const rand = prng.random();
    const alphabet = "*_`~#[]()<>|-\n! \\\"abc";

    var buf: [96]u8 = undefined;
    var round: usize = 0;
    while (round < 1500) : (round += 1) {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*ch| ch.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const html = try toHtml(testing.allocator, buf[0..n]);
        testing.allocator.free(html);
    }
}
