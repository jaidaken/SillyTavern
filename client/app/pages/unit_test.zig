//! Aggregator for `zig build test`. The runner only sees tests reachable from the compilation
//! root, so every test-bearing module is imported here.
//!
//! `sanitized.zig` and the `.zx` components depend on the ziex `zx` module and the `markdown`
//! module, so they are covered by `client/verify.sh` against a real browser instead. `store.zig`,
//! `utf8.zig`, `stream.zig` and `html.zig` are pure Zig precisely so they can be proven here.
//!
//! This file is never part of the app build, so it may `@embedFile` the `.zx` sources. The
//! transpiler copies `app/pages/*.zig` into a cache directory where the `.zx` files do not exist,
//! which is why the source gate below cannot live in `html.zig`.

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

const zx_sources = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "page.zx", .text = @embedFile("page.zx") },
    .{ .name = "layout.zx", .text = @embedFile("layout.zx") },
    .{ .name = "chat.zx", .text = @embedFile("chat.zx") },
    .{ .name = "message.zx", .text = @embedFile("message.zx") },
};

const raw_attr = "@escaping={.none}";
const sink_call = "html.sink(";

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| {
        n += 1;
        at = found + needle.len;
    }
    return n;
}

test "every_raw_html_element_in_the_zx_sources_is_fed_by_the_sink" {
    var total: usize = 0;
    for (zx_sources) |src| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src.text, at, raw_attr)) |found| {
            total += 1;
            at = found + raw_attr.len;

            // The child expression follows the attribute on the same element, before the next tag.
            const rest = src.text[at..];
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
    for (zx_sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".unwrap()"));
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".bytes"));
    }
}

test "no_zx_source_forges_the_sanitized_witness" {
    for (zx_sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, "witness_token"));
    }
}
