//! Pure-Zig live-markdown highlighter for the inline message editor (`message_editor.zig`).
//!
//! It WRAPS markdown markers in styled `<span>`s without adding or dropping a single source
//! character: strip every tag from the output and HTML-unescape it and you get the input back byte
//! for byte. That invariant is the whole point, and it is asserted by test, because the editor's
//! save path reads the field's `textContent` back as the new message body: if the highlight ever
//! lost or invented a character, saving would silently corrupt the message.
//!
//! zx-free on purpose (ZX5): this is the pure logic half, unit-tested under `zig build test`. The
//! DOM half (contenteditable, caret, save) lives in `message_editor.zig` and is browser-verified.

const std = @import("std");

/// Wrap the raw markdown source in highlight spans. Line-structured: each line becomes one
/// `<span class="md-line …">` whose inline markers are wrapped in turn, and the lines are rejoined
/// with the literal `\n` they were split on, so the field's `textContent` reconstructs the source.
pub fn highlight(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var first = true;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        try out.appendSlice(alloc, "<span class=\"");
        try out.appendSlice(alloc, lineClass(line));
        try out.appendSlice(alloc, "\">");
        try inlineInto(alloc, &out, line);
        try out.appendSlice(alloc, "</span>");
    }
    return out.toOwnedSlice(alloc);
}

/// The block class for a line, from its leading markers. Static strings, so no allocation.
fn lineClass(line: []const u8) []const u8 {
    // ATX heading: 1-6 `#` then a space (or the whole line is just the hashes).
    var h: usize = 0;
    while (h < line.len and line[h] == '#') h += 1;
    if (h >= 1 and h <= 6 and (h == line.len or line[h] == ' ')) {
        return switch (h) {
            1 => "md-line md-h1",
            2 => "md-line md-h2",
            3 => "md-line md-h3",
            4 => "md-line md-h4",
            5 => "md-line md-h5",
            else => "md-line md-h6",
        };
    }

    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '>') return "md-line md-bq";
    if (std.mem.startsWith(u8, trimmed, "```")) return "md-line md-fence";
    if (isListMarker(trimmed)) return "md-line md-li";
    return "md-line";
}

/// `- ` / `* ` / `+ ` / `1. ` at the (already left-trimmed) start of a line.
fn isListMarker(t: []const u8) bool {
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') return true;
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    return i > 0 and i + 1 < t.len and t[i] == '.' and t[i + 1] == ' ';
}

fn emitEsc(alloc: std.mem.Allocator, out: *std.ArrayList(u8), ch: u8) !void {
    switch (ch) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        else => try out.append(alloc, ch),
    }
}

fn emitEscSlice(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| try emitEsc(alloc, out, ch);
}

/// A `<span class="md-mark">…</span>` around literal marker bytes (escaped), a `<span class="md-…">`
/// around the escaped content between them. Every byte of `open`, `body`, `close` is emitted, so the
/// wrapper never changes the underlying text.
fn wrap(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cls: []const u8, open: []const u8, body: []const u8, close: []const u8) !void {
    try out.appendSlice(alloc, "<span class=\"md-mark\">");
    try emitEscSlice(alloc, out, open);
    try out.appendSlice(alloc, "</span><span class=\"");
    try out.appendSlice(alloc, cls);
    try out.appendSlice(alloc, "\">");
    try emitEscSlice(alloc, out, body);
    try out.appendSlice(alloc, "</span><span class=\"md-mark\">");
    try emitEscSlice(alloc, out, close);
    try out.appendSlice(alloc, "</span>");
}

/// Inline scan of one line. Recognises `code`, `**bold**`/`__bold__`, `~~strike~~`, `*italic*`/
/// `_italic_`, and `[text](url)`. Anything that does not close is emitted as its own escaped bytes,
/// so an unterminated marker shows literally and still round-trips.
fn inlineInto(alloc: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];

        // `code` (or ``code with a backtick`` via a run): match an equal-length closing run.
        if (c == '`') {
            var n: usize = 0;
            while (i + n < line.len and line[i + n] == '`') n += 1;
            if (findRun(line, i + n, '`', n)) |close_at| {
                try wrap(alloc, out, "md-code", line[i .. i + n], line[i + n .. close_at], line[close_at .. close_at + n]);
                i = close_at + n;
                continue;
            }
            try emitRun(alloc, out, line, i, n);
            i += n;
            continue;
        }

        // **bold** / __bold__ / ~~strike~~ : two-char fence, matching two-char close.
        if ((c == '*' or c == '_' or c == '~') and i + 1 < line.len and line[i + 1] == c) {
            const cls: []const u8 = if (c == '~') "md-strike" else "md-bold";
            if (findClose2(line, i + 2, c)) |j| {
                try wrap(alloc, out, cls, line[i .. i + 2], line[i + 2 .. j], line[j .. j + 2]);
                i = j + 2;
                continue;
            }
        }

        // *italic* / _italic_ : single fence, content free of the fence char, non-empty, non-space edges.
        if (c == '*' or c == '_') {
            if (findCloseItalic(line, i + 1, c)) |j| {
                try wrap(alloc, out, "md-italic", line[i .. i + 1], line[i + 1 .. j], line[j .. j + 1]);
                i = j + 1;
                continue;
            }
        }

        // [text](url)
        if (c == '[') {
            if (parseLink(line, i)) |lk| {
                try out.appendSlice(alloc, "<span class=\"md-mark\">[</span><span class=\"md-link\">");
                try emitEscSlice(alloc, out, line[lk.text_start..lk.text_end]);
                try out.appendSlice(alloc, "</span><span class=\"md-mark\">](</span><span class=\"md-url\">");
                try emitEscSlice(alloc, out, line[lk.url_start..lk.url_end]);
                try out.appendSlice(alloc, "</span><span class=\"md-mark\">)</span>");
                i = lk.url_end + 1;
                continue;
            }
        }

        try emitEsc(alloc, out, c);
        i += 1;
    }
}

fn emitRun(alloc: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, start: usize, n: usize) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) try emitEsc(alloc, out, line[start + k]);
}

/// The index of a run of exactly `n` `ch` starting at or after `from` (and not longer than `n`).
fn findRun(line: []const u8, from: usize, ch: u8, n: usize) ?usize {
    var i = from;
    while (i < line.len) : (i += 1) {
        if (line[i] != ch) continue;
        var m: usize = 0;
        while (i + m < line.len and line[i + m] == ch) m += 1;
        if (m == n) return i;
        i += m - 1;
    }
    return null;
}

/// The index of the next `cc` pair (closing `**`/`__`/`~~`) at or after `from`, requiring at least
/// one byte of content between the fences (so `i > from`).
fn findClose2(line: []const u8, from: usize, c: u8) ?usize {
    var i = from;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == c and line[i + 1] == c and i > from) return i;
    }
    return null;
}

/// The index of the closing single fence for italic: the next bare `c` whose content is non-empty,
/// contains no `*`/`_`, and has non-space inner edges (so `a * b` is not italic).
fn findCloseItalic(line: []const u8, from: usize, c: u8) ?usize {
    if (from >= line.len) return null;
    if (line[from] == ' ' or line[from] == c) return null;
    var i = from;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '*' or ch == '_') {
            if (ch != c) return null; // a different emphasis char inside: bail, show literal
            if (i == from) return null;
            if (line[i - 1] == ' ') return null;
            return i;
        }
    }
    return null;
}

const Link = struct { text_start: usize, text_end: usize, url_start: usize, url_end: usize };

/// `[text](url)` starting at `open` (which is `[`). Returns the four content bounds, or null.
fn parseLink(line: []const u8, open: usize) ?Link {
    const text_start = open + 1;
    var i = text_start;
    while (i < line.len and line[i] != ']') i += 1;
    if (i >= line.len) return null; // no closing ]
    const text_end = i;
    if (i + 1 >= line.len or line[i + 1] != '(') return null;
    const url_start = i + 2;
    var j = url_start;
    while (j < line.len and line[j] != ')') j += 1;
    if (j >= line.len) return null; // no closing )
    return .{ .text_start = text_start, .text_end = text_end, .url_start = url_start, .url_end = j };
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// Strip every `<span …>`/`</span>` tag and HTML-unescape, i.e. reconstruct the field's textContent.
fn detag(alloc: std.mem.Allocator, htmls: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < htmls.len) {
        if (htmls[i] == '<') {
            while (i < htmls.len and htmls[i] != '>') i += 1;
            if (i < htmls.len) i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, htmls[i..], "&amp;")) {
            try out.append(alloc, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, htmls[i..], "&lt;")) {
            try out.append(alloc, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, htmls[i..], "&gt;")) {
            try out.append(alloc, '>');
            i += 4;
        } else {
            try out.append(alloc, htmls[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn expectRoundTrip(raw: []const u8) !void {
    const h = try highlight(testing.allocator, raw);
    defer testing.allocator.free(h);
    const back = try detag(testing.allocator, h);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(raw, back);
}

test "round trip is byte identical for a spread of markdown" {
    try expectRoundTrip("");
    try expectRoundTrip("plain text");
    try expectRoundTrip("**bold** and *italic* and ~~strike~~");
    try expectRoundTrip("a `code` span and ``a ` b`` too");
    try expectRoundTrip("# Heading one\n## Heading two\n> a quote\n- a list item");
    try expectRoundTrip("see [the docs](https://ziex.dev/reference) now");
    try expectRoundTrip("edge & < > chars stay intact");
    try expectRoundTrip("line one\n\nline three");
    try expectRoundTrip("unterminated **bold and *italic and `code");
    try expectRoundTrip("trailing newline\n");
    try expectRoundTrip("_under_ and __double__ mixed");
    try expectRoundTrip("a * b (not italic) and 1. numbered");
}

test "bold wraps the markers in md-mark and the content in md-bold" {
    const h = try highlight(testing.allocator, "**hi**");
    defer testing.allocator.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "<span class=\"md-mark\">**</span>") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<span class=\"md-bold\">hi</span>") != null);
}

test "a heading line carries its level class" {
    const h = try highlight(testing.allocator, "### three");
    defer testing.allocator.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "md-line md-h3") != null);
}

test "an html metacharacter in the body is escaped, not injected" {
    const h = try highlight(testing.allocator, "<script>");
    defer testing.allocator.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, h, "<script>") == null);
}

test "italic requires non-space edges so an asterisk in prose stays literal" {
    const h = try highlight(testing.allocator, "2 * 3 = 6");
    defer testing.allocator.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "md-italic") == null);
}

fn highlightAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const h = try highlight(a, raw);
    a.free(h);
}

test "highlight cleans up on every allocation failure" {
    const raw: []const u8 = "**bold** and _it_ and `c`\n# heading\n> quote\nsee [x](y) & <b>";
    try testing.checkAllAllocationFailures(testing.allocator, highlightAndFree, .{raw});
}

// The safety net for the save path: whatever bytes go in, the de-tagged output must come back out
// unchanged, or an edit could silently rewrite the message. Random input over the markdown alphabet,
// seeded and fixed for repro, doubles as the always-on fuzz fallback for this untrusted-input parser.
test "round trip holds over random markdown-ish input" {
    var prng = std.Random.DefaultPrng.init(0xB0BACAFE);
    const rand = prng.random();
    const alphabet = "ab  *_~`#>[]()\n-.1&<>";
    var buf: [80]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const len = rand.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        try expectRoundTrip(buf[0..len]);
    }
}
