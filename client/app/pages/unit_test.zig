//! Aggregator for `zig build test`. The runner only sees tests reachable from the compilation
//! root, so every test-bearing module is imported here.
//!
//! `sanitized.zig` and the `.zx` components depend on the ziex `zx` module and the `markdown`
//! module, so they are covered by `client/verify.sh` against a real browser instead. `store.zig`,
//! `utf8.zig`, `stream.zig` and `html.zig` are pure Zig precisely so they can be proven here.
//!
//! This file is never part of the app build, so it may read the `.zx` sources off disk. The
//! transpiler copies `app/pages/*.zig` into a cache directory where the `.zx` files do not exist,
//! which is why the source gate below cannot live in `html.zig`. The scan enumerates the directory
//! instead of naming its files, so a template added tomorrow is gated the day it lands.

const std = @import("std");

comptime {
    _ = @import("quotes.zig");
    _ = @import("libc_shim");
    _ = @import("markdown.zig");
    _ = @import("store.zig");
    _ = @import("utf8.zig");
    _ = @import("stream.zig");
    _ = @import("html.zig");
    _ = @import("completion.zig");
    _ = @import("ui_state.zig");
}

const sink_call = "html.sink(";

/// The raw-HTML attribute, split so the scan tolerates the whitespace the ziex parser ignores.
const raw_attr_tokens = [_][]const u8{ "@escaping", "=", "{", ".none", "}" };
const attr_head = raw_attr_tokens[0];

/// Proves the scan reached the real directory rather than an empty one; it reads whatever it finds.
const known_zx_count = 8;
const zx_anchor = "message.zx";

/// A test binary inherits the cwd `zig build` was invoked from, which is the client root on every
/// documented path. The other two candidates cost nothing and cover a repo-root invocation.
const zx_dir_candidates = [_][]const u8{ "app/pages", ".", "client/app/pages" };

const ZxSource = struct { name: []u8, text: []u8 };

fn openZxDir(io: std.Io) !std.Io.Dir {
    for (zx_dir_candidates) |candidate| {
        var dir = std.Io.Dir.cwd().openDir(io, candidate, .{ .iterate = true }) catch continue;
        if (dir.access(io, zx_anchor, .{})) |_| {
            return dir;
        } else |_| {
            dir.close(io);
        }
    }
    // A scan that finds no sources would satisfy every gate below, so a miss must fail loudly.
    return error.ZxSourceDirNotFound;
}

fn freeZxSources(gpa: std.mem.Allocator, sources: []ZxSource) void {
    for (sources) |src| {
        gpa.free(src.name);
        gpa.free(src.text);
    }
    gpa.free(sources);
}

/// html.zig is the one legitimate mint of a witness, and unit_test.zig carries `witness_token` in
/// its own scan strings, so the `.zig` forgery scan skips both.
const witness_mint_files = [_][]const u8{ "html.zig", "unit_test.zig" };

/// A floor proving the `.zig` scan reached the real page directory rather than an empty one.
const known_zig_min = 8;

fn isExcluded(name: []const u8, exclude: []const []const u8) bool {
    for (exclude) |ex| {
        if (std.mem.eql(u8, name, ex)) return true;
    }
    return false;
}

fn loadSources(gpa: std.mem.Allocator, io: std.Io, suffix: []const u8, exclude: []const []const u8) ![]ZxSource {
    var dir = try openZxDir(io);
    defer dir.close(io);

    var sources: std.ArrayList(ZxSource) = .empty;
    errdefer {
        for (sources.items) |src| {
            gpa.free(src.name);
            gpa.free(src.text);
        }
        sources.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        if (isExcluded(entry.name, exclude)) continue;

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        errdefer gpa.free(text);
        try sources.append(gpa, .{ .name = name, .text = text });
    }
    return sources.toOwnedSlice(gpa);
}

fn loadZxSources(gpa: std.mem.Allocator, io: std.Io) ![]ZxSource {
    return loadSources(gpa, io, ".zx", &[_][]const u8{});
}

/// Every `app/pages/*.zig` except the witness mint and this test file, for the forgery scan.
fn loadForgeableZigSources(gpa: std.mem.Allocator, io: std.Io) ![]ZxSource {
    return loadSources(gpa, io, ".zig", &witness_mint_files);
}

/// `@escaping = { .none }` opens the same raw-HTML slot as `@escaping={.none}`, so an exact-string
/// match would wave a spaced attribute through. Returns the index just past the attribute.
///
/// Only the literal `.none` is matched: were ziex to accept a non-literal `@escaping` value (a
/// comptime const), that element would go uncounted here and its children unscanned.
fn matchRawAttr(text: []const u8, at: usize) ?usize {
    var i = at;
    for (raw_attr_tokens) |token| {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (!std.mem.startsWith(u8, text[i..], token)) return null;
        i += token.len;
    }
    return i;
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

/// The result of auditing one `.zx` source: how many raw-HTML elements it opened, and the first
/// child of one that the sink does not wrap. ziex concatenates every text child of an element into
/// its innerHTML, so a raw element is only safe when EVERY child is individually sunk.
const RawScan = struct { count: usize = 0, offender: ?[]const u8 = null };

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn byteAt(text: []const u8, i: usize) u8 {
    return if (i < text.len) text[i] else 0;
}

/// Index just past the closing quote of the string opened at `at`.
fn skipString(text: []const u8, at: usize) usize {
    var i = at + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == text[at]) return i + 1;
    }
    return text.len;
}

/// Index just past the `}` matching the `{` at `at`.
fn braceEnd(text: []const u8, at: usize) ?usize {
    var depth: usize = 0;
    var i = at;
    while (i < text.len) {
        switch (text[i]) {
            '"', '\'' => {
                i = skipString(text, i);
                continue;
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// Index of the `>` closing the open tag, skipping the braces and quotes of later attributes so a
/// `>` inside an attribute value cannot end the tag early.
fn openTagEnd(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) {
        switch (text[i]) {
            '"', '\'' => {
                i = skipString(text, i);
                continue;
            },
            '{' => {
                i = braceEnd(text, i) orelse return null;
                continue;
            },
            '>' => return i,
            else => {},
        }
        i += 1;
    }
    return null;
}

/// The element name opening the tag that carries the attribute at `attr_at`.
fn tagNameBefore(text: []const u8, attr_at: usize) ?[]const u8 {
    const lt = std.mem.lastIndexOfScalar(u8, text[0..attr_at], '<') orelse return null;
    var end = lt + 1;
    while (end < text.len and isNameChar(text[end])) end += 1;
    if (end == lt + 1) return null;
    return text[lt + 1 .. end];
}

/// Index of the `</name>` closing the element whose children start at `from`.
fn childrenEnd(text: []const u8, from: usize, name: []const u8) ?usize {
    var depth: usize = 1;
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] != '<') continue;
        if (byteAt(text, i + 1) == '/') {
            if (!std.mem.startsWith(u8, text[i + 2 ..], name)) continue;
            if (isNameChar(byteAt(text, i + 2 + name.len))) continue;
            depth -= 1;
            if (depth == 0) return i;
        } else {
            if (!std.mem.startsWith(u8, text[i + 1 ..], name)) continue;
            if (isNameChar(byteAt(text, i + 1 + name.len))) continue;
            depth += 1;
        }
    }
    return null;
}

/// True when `expr` is one whole `html.sink(...)` call rather than a call with anything appended.
fn isSinkCall(expr: []const u8) bool {
    if (!std.mem.startsWith(u8, expr, sink_call)) return false;

    var depth: usize = 0;
    var i = sink_call.len - 1;
    while (i < expr.len) {
        switch (expr[i]) {
            '"', '\'' => {
                i = skipString(expr, i);
                continue;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i == expr.len - 1;
            },
            else => {},
        }
        i += 1;
    }
    return false;
}

/// Audits every `@escaping={.none}` element in `text`. A line-wide substring test would wave
/// through a second unsinked child, a sink hiding in an attribute, and a sink in a trailing
/// comment; each child expression is checked on its own instead.
fn scanRawChildren(text: []const u8) RawScan {
    var scan: RawScan = .{};
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, text, at, attr_head)) |found| {
        at = found + attr_head.len;
        const attr_end = matchRawAttr(text, found) orelse continue;
        scan.count += 1;
        at = attr_end;

        const name = tagNameBefore(text, found) orelse {
            scan.offender = text[found..attr_end];
            return scan;
        };
        const gt = openTagEnd(text, attr_end) orelse {
            scan.offender = text[found..attr_end];
            return scan;
        };
        // A self-closing raw element has no children to sink.
        if (text[gt - 1] == '/') continue;

        const kids_start = gt + 1;
        const kids_end = childrenEnd(text, kids_start, name) orelse {
            scan.offender = text[kids_start..];
            return scan;
        };

        var j = kids_start;
        while (j < kids_end) {
            if (std.ascii.isWhitespace(text[j])) {
                j += 1;
                continue;
            }
            // Literal text and nested tags reach innerHTML unsanitized, so only an expression fits.
            if (text[j] != '{') {
                scan.offender = std.mem.trim(u8, text[j..kids_end], &std.ascii.whitespace);
                return scan;
            }
            const expr_end = braceEnd(text, j) orelse {
                scan.offender = text[j..kids_end];
                return scan;
            };
            const expr = std.mem.trim(u8, text[j + 1 .. expr_end - 1], &std.ascii.whitespace);
            if (!isSinkCall(expr)) {
                scan.offender = expr;
                return scan;
            }
            j = expr_end;
        }
    }
    return scan;
}

fn loadAndFreeZxSources(gpa: std.mem.Allocator, io: std.Io) !void {
    const sources = try loadZxSources(gpa, io);
    freeZxSources(gpa, sources);
}

fn loadAndFreeZigSources(gpa: std.mem.Allocator, io: std.Io) !void {
    const sources = try loadForgeableZigSources(gpa, io);
    freeZxSources(gpa, sources);
}

test "match_raw_attr_accepts_a_spaced_attribute_and_rejects_other_escaping_modes" {
    try std.testing.expectEqual(@as(?usize, 17), matchRawAttr("@escaping={.none}", 0));
    try std.testing.expectEqual(@as(?usize, 21), matchRawAttr("@escaping = { .none }", 0));
    try std.testing.expectEqual(@as(?usize, 21), matchRawAttr("@escaping\t=\n{ .none\t}", 0));
    try std.testing.expectEqual(@as(?usize, null), matchRawAttr("@escaping={.html}", 0));
    try std.testing.expectEqual(@as(?usize, null), matchRawAttr("@escaping", 0));
    try std.testing.expectEqual(@as(?usize, null), matchRawAttr("@allocator={a}", 0));
}

test "loading_the_zx_sources_cleans_up_on_every_allocation_failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndFreeZxSources, .{std.testing.io});
}

test "every_raw_html_element_in_the_zx_sources_is_fed_by_the_sink" {
    const gpa = std.testing.allocator;
    const sources = try loadZxSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= known_zx_count);

    var total: usize = 0;
    for (sources) |src| {
        const scan = scanRawChildren(src.text);
        total += scan.count;
        if (scan.offender) |child| {
            std.debug.print("\n{s}: raw HTML child not fed by {s}:\n{s}\n", .{ src.name, sink_call, child });
            return error.UnsanitizedRawHtmlSink;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), total);
}

test "the_raw_child_scan_rejects_a_second_child_the_old_line_scan_waved_through" {
    // ziex concatenates both children into innerHTML, so `evil` renders unsanitized.
    const two_children = "<div @escaping={.none}>{html.sink(body)}{evil}</div>";
    // The retired per-line check passed this source: the substring is present on the line.
    try std.testing.expect(std.mem.indexOf(u8, two_children, sink_call) != null);

    const scan = scanRawChildren(two_children);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqualStrings("evil", scan.offender.?);
}

test "the_raw_child_scan_rejects_a_sink_that_only_decorates_an_attribute_or_a_comment" {
    const in_attribute = "<div @escaping={.none} title=\"html.sink(\">{evil}</div>";
    try std.testing.expect(std.mem.indexOf(u8, in_attribute, sink_call) != null);
    try std.testing.expectEqualStrings("evil", scanRawChildren(in_attribute).offender.?);

    const in_comment = "<div @escaping={.none}>{evil}</div> // html.sink(body)";
    try std.testing.expect(std.mem.indexOf(u8, in_comment, sink_call) != null);
    try std.testing.expectEqualStrings("evil", scanRawChildren(in_comment).offender.?);

    const literal_text = "<div @escaping={.none}>plain <b>text</b></div>";
    try std.testing.expectEqualStrings("plain <b>text</b>", scanRawChildren(literal_text).offender.?);
}

test "the_raw_child_scan_rejects_an_expression_that_only_starts_as_a_sink_call" {
    try std.testing.expectEqualStrings(
        "html.sink(body) ++ evil",
        scanRawChildren("<div @escaping={.none}>{html.sink(body) ++ evil}</div>").offender.?,
    );
    try std.testing.expectEqualStrings(
        "sink(body)",
        scanRawChildren("<div @escaping={.none}>{sink(body)}</div>").offender.?,
    );
    try std.testing.expectEqualStrings(
        "evil",
        scanRawChildren("<div @escaping={.none}>{evil}{html.sink(body)}</div>").offender.?,
    );
}

test "the_raw_child_scan_accepts_every_child_individually_sunk" {
    const spread_over_lines =
        \\<div class="mes_text" @escaping={.none}>
        \\    {html.sink(body)}
        \\</div>
    ;
    const scan = scanRawChildren(spread_over_lines);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqual(@as(?[]const u8, null), scan.offender);

    const nested_call = "<div @escaping={.none}>{html.sink(render(a, b))}{html.sink(tail)}</div>";
    try std.testing.expectEqual(@as(?[]const u8, null), scanRawChildren(nested_call).offender);

    const self_closing = "<img @escaping={.none} />";
    try std.testing.expectEqual(@as(usize, 1), scanRawChildren(self_closing).count);
    try std.testing.expectEqual(@as(?[]const u8, null), scanRawChildren(self_closing).offender);

    const escaped_element = "<div @escaping={.html}>{anything}</div>";
    try std.testing.expectEqual(@as(usize, 0), scanRawChildren(escaped_element).count);
    try std.testing.expectEqual(@as(?[]const u8, null), scanRawChildren(escaped_element).offender);
}

test "no_zx_source_unwraps_sanitized_html_outside_the_sink" {
    const gpa = std.testing.allocator;
    const sources = try loadZxSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= known_zx_count);

    for (sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".unwrap()"));
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".bytes"));
    }
}

test "no_zx_source_forges_the_sanitized_witness" {
    const gpa = std.testing.allocator;
    const sources = try loadZxSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= known_zx_count);

    for (sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, "witness_token"));
    }
}

test "loading_the_forgeable_zig_sources_cleans_up_on_every_allocation_failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndFreeZigSources, .{std.testing.io});
}

test "no_zig_source_outside_the_mint_forges_the_sanitized_witness" {
    const gpa = std.testing.allocator;
    const sources = try loadForgeableZigSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= known_zig_min);

    // html.zig admits `.witness_token = undefined` compiles with no field privacy, so any occurrence
    // of the field name in app-page Zig outside the mint is a forge reaching the raw-HTML sink.
    for (sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, "witness_token"));
    }
}
