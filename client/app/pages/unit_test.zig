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
    _ = @import("./chat/quotes.zig");
    _ = @import("libc_shim");
    _ = @import("./platform/markdown.zig");
    _ = @import("./platform/store.zig");
    _ = @import("./platform/utf8.zig");
    _ = @import("./platform/stream.zig");
    _ = @import("./platform/html.zig");
    // The inline message editor's pure highlighter (message_editor.zig is the zx-importing DOM half).
    _ = @import("./platform/md_highlight.zig");
    _ = @import("./setup/completion.zig");
    _ = @import("./nav/ui_state.zig");
    // The edge-tab reveal geometry; pointer_track.zig is the zx-importing DOM half.
    _ = @import("./nav/reveal_zone.zig");
    _ = @import("./cast/char_data.zig");
    _ = @import("./setup/generate.zig");
    _ = @import("./setup/tokenizer.zig");
    _ = @import("./platform/log_spec.zig");
    _ = @import("./nav/dropdown_nav.zig");
    // The command palette's catalogue + query filter; palette_state.zig is the zx-importing half.
    _ = @import("./nav/palette_targets.zig");
    _ = @import("./system/background_store.zig");
    // C4: the pure multipart/form-data assembler behind the Zig-owned uploads.
    _ = @import("./platform/multipart.zig");
    // w3-grp
    _ = @import("./cast/group_store.zig");
    _ = @import("./setup/textgen_types.zig");
    _ = @import("./platform/secret_mask.zig");
    // w3-grp
    _ = @import("./cast/group_rotation.zig");
    // character_view's tests never reached the runner: the module was absent here.
    _ = @import("./cast/tag_store.zig");
    _ = @import("./cast/character_view.zig");
    _ = @import("./cast/character_row.zig");
    _ = @import("./cast/card_form.zig");
    _ = @import("./platform/datetime.zig");
    // C-CFG
    _ = @import("./setup/macros.zig");
    _ = @import("./platform/rng.zig");
    _ = @import("./setup/templates.zig");
    _ = @import("./setup/samplers.zig");
    _ = @import("./setup/sampler_presets.zig");
    _ = @import("./setup/authors_note.zig");
    // C-PRE-TPL: the zx-free half of the preset pickers. template_presets.zig imports zx, so only
    // its rules can be proven here; its fetch and panel state are browser-verified.
    _ = @import("./setup/preset_lib.zig");
    // w3-chatmgr: the zx-free half of the chat manager (suffix rules + name minting).
    _ = @import("./chat/chat_names.zig");
    // w3-wi
    _ = @import("./setup/world_info.zig");
    // w3-wi-engine
    _ = @import("./setup/world_info_engine.zig");
    // P3-A: the zx-free server-event hub (transport; the router lands separately).
    _ = @import("./platform/server_events.zig");
    // P1-A: the zx-free half of the notifications (notifications.zig is the timer + region glue).
    _ = @import("./notify/notification_store.zig");
    // H1: the 64-bit crossing register + the door packing convention.
    _ = @import("./platform/boundary_marshal.zig");
    _ = @import("./platform/doorpack.zig");
}

const sink_call = "html.sink(";

/// The raw-HTML attribute, split so the scan tolerates the whitespace the ziex parser ignores.
const raw_attr_tokens = [_][]const u8{ "@escaping", "=", "{", ".none", "}" };
const attr_head = raw_attr_tokens[0];

/// The true count of `.zx` sources under app/pages across all 8 domain folders. The scan walks the
/// tree recursively, so a walk that silently missed a folder would read fewer files and pass as
/// clean; pinning the true total makes that a failure. Bump it the day a template lands.
const total_zx_sources = 38;
const zx_anchor = "chat/message.zx";

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

/// The true counts of `.zig` sources under app/pages across all 8 domain folders: every `.zig` for
/// the aggregator-import scan, and that minus the two witness-mint files for the forgery scan. A
/// recursive walk that missed a folder scans fewer and reads clean; pinning the totals fails it.
const total_zig_sources = 86;
const total_forgeable_zig = total_zig_sources - witness_mint_files.len;

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

    // Recursive: sources moved into per-domain subfolders a flat iterate would miss; basenames stay unique tree-wide, so name-keyed logic holds.
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, suffix)) continue;
        if (isExcluded(entry.basename, exclude)) continue;

        const name = try gpa.dupe(u8, entry.basename);
        errdefer gpa.free(name);
        const text = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20));
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
    try std.testing.expect(sources.len >= total_zx_sources);

    var total: usize = 0;
    for (sources) |src| {
        const scan = scanRawChildren(src.text);
        total += scan.count;
        if (scan.offender) |child| {
            std.debug.print("\n{s}: raw HTML child not fed by {s}:\n{s}\n", .{ src.name, sink_call, child });
            return error.UnsanitizedRawHtmlSink;
        }
    }
    // 2 = the message body + the reasoning block (w3-reason), both fed by renderMessage's
    // DOMPurify pass. Adding a raw element means reviewing it HERE, then bumping this pin.
    try std.testing.expectEqual(@as(usize, 2), total);
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

/// `libc_shim` is imported by module name rather than by path, so the aggregator's own line for it
/// carries no `.zig`. This file is the aggregator, so it is not asked to import itself.
const import_scan_exempt = [_][]const u8{ "libc_shim.zig", "unit_test.zig" };

// A module the runner never reaches reads as green while proving nothing: character_view.zig sat
// like that, nine tests that never ran and did not even compile once they did.
test "every_module_that_has_tests_is_imported_by_this_aggregator" {
    const gpa = std.testing.allocator;
    const sources = try loadSources(gpa, std.testing.io, ".zig", &[_][]const u8{});
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= total_zig_sources);

    // The aggregator reads its own source: the import list to check against is the text above.
    var self_text: ?[]const u8 = null;
    for (sources) |src| {
        if (std.mem.eql(u8, src.name, "unit_test.zig")) self_text = src.text;
    }
    const imports = self_text orelse return error.AggregatorSourceNotFound;

    var missing: usize = 0;
    for (sources) |src| {
        if (isExcluded(src.name, &import_scan_exempt)) continue;
        // A test declaration at column 0. `test "` inside a string or a comment is not one.
        if (std.mem.indexOf(u8, src.text, "\ntest \"") == null) continue;

        // Imports are subfolder-qualified (`@import("./chat/quotes.zig")`), so the basename is preceded by `/`; that leading slash also stops `store.zig` matching `background_store.zig`.
        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "/{s}\")", .{src.name});
        if (std.mem.indexOf(u8, imports, needle) == null) {
            std.debug.print("\n{s} has tests but unit_test.zig never imports it: they never run.\n", .{src.name});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "no_zx_source_unwraps_sanitized_html_outside_the_sink" {
    const gpa = std.testing.allocator;
    const sources = try loadZxSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= total_zx_sources);

    for (sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".unwrap()"));
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, ".bytes"));
    }
}

test "no_zx_source_forges_the_sanitized_witness" {
    const gpa = std.testing.allocator;
    const sources = try loadZxSources(gpa, std.testing.io);
    defer freeZxSources(gpa, sources);
    try std.testing.expect(sources.len >= total_zx_sources);

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
    try std.testing.expect(sources.len >= total_forgeable_zig);

    // html.zig admits `.witness_token = undefined` compiles with no field privacy, so any occurrence
    // of the field name in app-page Zig outside the mint is a forge reaching the raw-HTML sink.
    for (sources) |src| {
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(src.text, "witness_token"));
    }
}
