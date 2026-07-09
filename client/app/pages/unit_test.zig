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
}

const sink_call = "html.sink(";

/// The raw-HTML attribute, split so the scan tolerates the whitespace the ziex parser ignores.
const raw_attr_tokens = [_][]const u8{ "@escaping", "=", "{", ".none", "}" };
const attr_head = raw_attr_tokens[0];

/// Proves the scan reached the real directory rather than an empty one; it reads whatever it finds.
const known_zx_count = 4;
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

fn loadZxSources(gpa: std.mem.Allocator, io: std.Io) ![]ZxSource {
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
        if (!std.mem.endsWith(u8, entry.name, ".zx")) continue;

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        errdefer gpa.free(text);
        try sources.append(gpa, .{ .name = name, .text = text });
    }
    return sources.toOwnedSlice(gpa);
}

/// `@escaping = { .none }` opens the same raw-HTML slot as `@escaping={.none}`, so an exact-string
/// match would wave a spaced attribute through. Returns the index just past the attribute.
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

fn loadAndFreeZxSources(gpa: std.mem.Allocator, io: std.Io) !void {
    const sources = try loadZxSources(gpa, io);
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
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src.text, at, attr_head)) |found| {
            at = found + attr_head.len;
            const attr_end = matchRawAttr(src.text, found) orelse continue;
            total += 1;
            at = attr_end;

            // The child expression follows the attribute on the same element, before the next tag.
            const rest = src.text[attr_end..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = rest[0..end];
            if (std.mem.indexOf(u8, line, sink_call) == null) {
                std.debug.print("\n{s}: raw HTML not fed by {s}:\n{s}\n", .{ src.name, sink_call, line });
                return error.UnsanitizedRawHtmlSink;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), total);
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
