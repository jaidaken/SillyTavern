//! Wraps quoted dialogue in <q> so it can be coloured, matching SillyTavern's regex at
//! public/script.js:1846. Runs before md4c: the emitted tags are inline HTML that md4c
//! passes through, and DOMPurify allows <q> by default.
//!
//! A quote inside code is never wrapped. Every construct md4c renders as code is skipped whole:
//! indented code blocks, fenced code blocks, inline code spans, raw tags, and the bodies of
//! <script> <pre> <style> <textarea> <code>. Recognition mirrors CommonMark because md4c parses
//! this output. Where the two could disagree the module errs towards calling text code, which
//! costs a colour but can never leak a literal <q> into a code block.

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

/// Elements whose body renders as code or style, never as prose.
const RawElement = struct { name: []const u8, closer: []const u8, block: bool };

/// `block` marks CommonMark HTML block type 1, whose unclosed form runs to end of document.
const raw_elements = [_]RawElement{
    .{ .name = "script", .closer = "</script>", .block = true },
    .{ .name = "pre", .closer = "</pre>", .block = true },
    .{ .name = "style", .closer = "</style>", .block = true },
    .{ .name = "textarea", .closer = "</textarea>", .block = true },
    .{ .name = "code", .closer = "</code>", .block = false },
};

const Fence = struct { ch: u8, len: usize };

fn lineEndAt(src: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, src, from, '\n') orelse src.len;
}

fn isBlank(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return true;
}

/// A tab advances to the next four-column stop, per CommonMark tab expansion.
fn indentCols(line: []const u8) usize {
    var col: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            col += 1;
        } else if (ch == '\t') {
            col += 4 - (col % 4);
        } else break;
    }
    return col;
}

fn firstNonSpace(line: []const u8) usize {
    var k: usize = 0;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
    return k;
}

/// True when the line begins a paragraph, so a following indented line is a lazy continuation
/// rather than a code block. Any leading char that could open another block answers false, which
/// keeps the doubtful case on the treat-it-as-code side.
fn opensParagraph(line: []const u8) bool {
    const k = firstNonSpace(line);
    if (k >= line.len) return false;
    if (indentCols(line) >= 4) return false;
    const ch = line[k];
    if (std.ascii.isDigit(ch)) return false;
    return std.mem.indexOfScalar(u8, "#>-+*=<`~_|", ch) == null;
}

fn fenceOpen(line: []const u8) ?Fence {
    if (indentCols(line) >= 4) return null;
    const k = firstNonSpace(line);
    if (k >= line.len) return null;
    const ch = line[k];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (k + n < line.len and line[k + n] == ch) n += 1;
    if (n < 3) return null;
    // A backtick fence's info string may not contain a backtick.
    if (ch == '`' and std.mem.indexOfScalar(u8, line[k + n ..], '`') != null) return null;
    return .{ .ch = ch, .len = n };
}

fn fenceClose(line: []const u8, f: Fence) bool {
    if (indentCols(line) >= 4) return false;
    const k = firstNonSpace(line);
    var n: usize = 0;
    while (k + n < line.len and line[k + n] == f.ch) n += 1;
    if (n < f.len) return false;
    return isBlank(line[k + n ..]);
}

fn fencedBlockEnd(src: []const u8, from: usize, f: Fence) usize {
    var k = from;
    while (k < src.len) {
        const le = lineEndAt(src, k);
        if (fenceClose(src[k..le], f)) return @min(le + 1, src.len);
        if (le >= src.len) break;
        k = le + 1;
    }
    // An unclosed fence runs to the end of the document, so md4c reads the rest as code too.
    return src.len;
}

/// End of the paragraph containing `from`, bounding constructs that may not cross a blank line.
fn paragraphEnd(src: []const u8, from: usize) usize {
    var k = from;
    while (std.mem.indexOfScalarPos(u8, src, k, '\n')) |nl| {
        const next = lineEndAt(src, nl + 1);
        if (isBlank(src[nl + 1 .. next])) return nl;
        k = nl + 1;
    }
    return src.len;
}

/// Memoizes `paragraphEnd` within one `wrap`. That scan is O(paragraph length) and `wrapInline`
/// queries it once per raw tag and once per backtick run, so a paragraph dense in either would
/// rescan it each time, giving O(n^2) over the body. A query landing inside the cached span returns
/// the same boundary: a hit means no blank line lies between the two positions, so both resolve to
/// the same paragraph end.
const ParaCache = struct {
    from: usize = 0,
    end: usize = 0,
    primed: bool = false,

    fn endOf(self: *ParaCache, src: []const u8, from: usize) usize {
        if (self.primed and from >= self.from and from <= self.end) return self.end;
        const e = paragraphEnd(src, from);
        self.* = .{ .from = from, .end = e, .primed = true };
        return e;
    }
};

/// A run of N backticks closes on the next run of exactly N, per CommonMark. No such run means
/// the backticks are literal text, not a code span.
fn codeSpanEnd(src: []const u8, from: usize, n: usize, limit: usize) ?usize {
    var k = from;
    while (k < limit) {
        if (src[k] != '`') {
            k += 1;
            continue;
        }
        var r: usize = 0;
        while (k + r < limit and src[k + r] == '`') r += 1;
        if (r == n) return k + r;
        k += r;
    }
    return null;
}

/// True when `at` opens its line, indented under the four columns that would make it code.
fn startsBlock(src: []const u8, at: usize) bool {
    var ls = at;
    while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
    for (src[ls..at]) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return indentCols(src[ls..]) < 4;
}

fn rawElementEnd(src: []const u8, at: usize, pc: *ParaCache) ?usize {
    for (raw_elements) |el| {
        if (!std.ascii.startsWithIgnoreCase(src[at + 1 ..], el.name)) continue;
        const after = at + 1 + el.name.len;
        if (after < src.len) {
            // Guards against <styled> matching <style>.
            switch (src[after]) {
                '>', '/', ' ', '\t', '\n' => {},
                else => continue,
            }
        }
        const limit = if (el.block) src.len else pc.endOf(src, @min(after, src.len));
        if (after <= limit) {
            if (std.ascii.findIgnoreCasePos(src[0..limit], after, el.closer)) |e| return e + el.closer.len;
        }
        if (el.block and startsBlock(src, at)) return src.len;
        return null;
    }
    return null;
}

/// End of the raw tag opened at `at`, or null when the `<` opens no tag and is literal text.
fn rawTagEnd(src: []const u8, at: usize, pc: *ParaCache) ?usize {
    if (at + 1 >= src.len) return null;
    if (std.mem.startsWith(u8, src[at..], "<!--")) {
        const e = std.mem.indexOfPos(u8, src, at + 4, "-->") orelse return null;
        return e + 3;
    }
    if (std.mem.startsWith(u8, src[at..], "<![CDATA[")) {
        const e = std.mem.indexOfPos(u8, src, at + 9, "]]>") orelse return null;
        return e + 3;
    }
    if (std.mem.startsWith(u8, src[at..], "<?")) {
        const e = std.mem.indexOfPos(u8, src, at + 2, "?>") orelse return null;
        return e + 2;
    }

    const c = src[at + 1];
    if (c != '/' and c != '!' and !std.ascii.isAlphabetic(c)) return null;
    if (c == '/' and (at + 2 >= src.len or !std.ascii.isAlphabetic(src[at + 2]))) return null;

    // Raw HTML may not contain a blank line, which bounds an unterminated attribute value.
    const limit = pc.endOf(src, at);
    var k = at + 1;
    var quote: u8 = 0;
    while (k < limit) : (k += 1) {
        const ch = src[k];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '<' => return null,
            '>' => return k + 1,
            else => {},
        }
    }
    return null;
}

/// True when the quote at `at` opens a speech turn rather than a quoted word inside prose: it begins
/// its line, or the text before it on the line ends a sentence. The reading modes that put speech on
/// its own line break only turns, so a quoted word mid-narration stays inline.
fn opensTurn(src: []const u8, at: usize) bool {
    var ls = at;
    while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
    // Skip trailing whitespace and markdown emphasis markers, so an action beat wrapped in * or _
    // (the dominant roleplay form, `*she turns.*  "speech"`) still reads as a sentence end.
    var e = at;
    while (e > ls) : (e -= 1) {
        switch (src[e - 1]) {
            ' ', '\t', '*', '_' => {},
            else => break,
        }
    }
    if (e == ls) return true;
    const before = src[ls..e];
    switch (before[before.len - 1]) {
        '.', '!', '?', ':', ';' => return true,
        else => {},
    }
    return std.mem.endsWith(u8, before, "\u{2026}");
}

/// Scans one line, wrapping its quotes. Returns the next index, which passes `line_end` when a
/// code span or raw element carried the scan onto a later line.
fn wrapInline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    src: []const u8,
    start: usize,
    line_end: usize,
    pc: *ParaCache,
) std.mem.Allocator.Error!usize {
    var j = start;
    outer: while (j < line_end) {
        const ch = src[j];

        if (ch == '<') {
            const end = rawElementEnd(src, j, pc) orelse rawTagEnd(src, j, pc);
            if (end) |e| {
                try out.appendSlice(allocator, src[j..e]);
                if (e > line_end) return e;
                j = e;
                continue;
            }
            // A lone `<` opens no tag, so it is literal text and the scan carries on.
            try out.append(allocator, '<');
            j += 1;
            continue;
        }

        if (ch == '`') {
            var n: usize = 0;
            while (j + n < src.len and src[j + n] == '`') n += 1;
            if (codeSpanEnd(src, j + n, n, pc.endOf(src, j + n))) |e| {
                try out.appendSlice(allocator, src[j..e]);
                if (e > line_end) return e;
                j = e;
                continue;
            }
            try out.appendSlice(allocator, src[j .. j + n]);
            j += n;
            continue;
        }

        for (pairs) |p| {
            if (!std.mem.startsWith(u8, src[j..line_end], p.open)) continue;
            const body = j + p.open.len;
            // A quote never spans a newline, mirroring the non-dotall `.` in ST's regex.
            const close_at = std.mem.indexOfPos(u8, src[0..line_end], body, p.close) orelse break;
            if (close_at == body) break;

            const close_end = close_at + p.close.len;
            if (opensTurn(src, j)) {
                // A turn wraps its delimiters in <span class="qd"> so a reading mode can hide the
                // marks; the class-prefixing sanitiser renames these to custom-q-turn / custom-qd.
                try out.appendSlice(allocator, "<q class=\"q-turn\"><span class=\"qd\">");
                try out.appendSlice(allocator, src[j..body]);
                try out.appendSlice(allocator, "</span>");
                try out.appendSlice(allocator, src[body..close_at]);
                try out.appendSlice(allocator, "<span class=\"qd\">");
                try out.appendSlice(allocator, src[close_at..close_end]);
                try out.appendSlice(allocator, "</span></q>");
            } else {
                try out.appendSlice(allocator, "<q>");
                try out.appendSlice(allocator, src[j..close_end]);
                try out.appendSlice(allocator, "</q>");
            }
            j = close_end;
            continue :outer;
        }

        try out.append(allocator, ch);
        j += 1;
    }
    return j;
}

/// Caller owns the result. OOM propagates so `checkAllAllocationFailures` can prove every path.
pub fn wrap(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, src.len);

    var i: usize = 0;
    var in_indented_code = false;
    var paragraph_open = false;
    var pc: ParaCache = .{};

    while (i < src.len) {
        const le = lineEndAt(src, i);

        if (i == 0 or src[i - 1] == '\n') {
            const line = src[i..le];
            const next = @min(le + 1, src.len);

            if (in_indented_code) {
                if (isBlank(line) or indentCols(line) >= 4) {
                    try out.appendSlice(allocator, src[i..next]);
                    i = next;
                    continue;
                }
                in_indented_code = false;
            }

            // An indented code block cannot interrupt a paragraph.
            if (!paragraph_open and !isBlank(line) and indentCols(line) >= 4) {
                in_indented_code = true;
                try out.appendSlice(allocator, src[i..next]);
                i = next;
                continue;
            }

            if (fenceOpen(line)) |f| {
                const end = fencedBlockEnd(src, next, f);
                try out.appendSlice(allocator, src[i..end]);
                i = end;
                paragraph_open = false;
                continue;
            }

            paragraph_open = opensParagraph(line);
        }

        i = try wrapInline(allocator, &out, src, i, le, &pc);
        if (i == le and le < src.len) {
            try out.append(allocator, '\n');
            i = le + 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn expectWrap(src: []const u8, want: []const u8) !void {
    const got = try wrap(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// A single turn quote at line start, delimiters wrapped for the reading modes that hide them.
fn expectTurn(open: []const u8, body: []const u8, close: []const u8) !void {
    const src = try std.fmt.allocPrint(testing.allocator, "{s}{s}{s}", .{ open, body, close });
    defer testing.allocator.free(src);
    const want = try std.fmt.allocPrint(
        testing.allocator,
        "<q class=\"q-turn\"><span class=\"qd\">{s}</span>{s}<span class=\"qd\">{s}</span></q>",
        .{ open, body, close },
    );
    defer testing.allocator.free(want);
    const got = try wrap(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "wrap_recognises_all_six_quote_forms" {
    try expectTurn("\"", "a", "\"");
    try expectTurn("\u{201C}", "a", "\u{201D}");
    try expectTurn("\u{00AB}", "a", "\u{00BB}");
    try expectTurn("\u{300C}", "a", "\u{300D}");
    try expectTurn("\u{300E}", "a", "\u{300F}");
    try expectTurn("\u{FF02}", "a", "\u{FF02}");
}

test "wrap_classifies_a_line_leading_quote_as_a_turn" {
    try expectWrap(
        "\"Go home.\"",
        "<q class=\"q-turn\"><span class=\"qd\">\"</span>Go home.<span class=\"qd\">\"</span></q>",
    );
}

test "wrap_classifies_a_quote_after_sentence_punctuation_as_a_turn" {
    try expectWrap(
        "He stopped. \"Wait.\"",
        "He stopped. <q class=\"q-turn\"><span class=\"qd\">\"</span>Wait.<span class=\"qd\">\"</span></q>",
    );
}

test "wrap_leaves_a_mid_sentence_quoted_word_inline" {
    try expectWrap("the band is called \"Fucking Hate\" now", "the band is called <q>\"Fucking Hate\"</q> now");
    try expectWrap("She said \"go\" firmly.", "She said <q>\"go\"</q> firmly.");
}

test "wrap_treats_a_quote_after_an_ellipsis_as_a_turn" {
    try expectWrap(
        "well\u{2026} \"fine\"",
        "well\u{2026} <q class=\"q-turn\"><span class=\"qd\">\"</span>fine<span class=\"qd\">\"</span></q>",
    );
}

test "wrap_treats_a_quote_after_an_emphasised_action_beat_as_a_turn" {
    try expectWrap(
        "*she turns.* \"Leave.\"",
        "*she turns.* <q class=\"q-turn\"><span class=\"qd\">\"</span>Leave.<span class=\"qd\">\"</span></q>",
    );
    // A lone asterisk that is not closing a sentence must not manufacture a turn.
    try expectWrap("a * \"b\"", "a * <q>\"b\"</q>");
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
    try expectWrap(
        "\"a\" and \"b\"",
        "<q class=\"q-turn\"><span class=\"qd\">\"</span>a<span class=\"qd\">\"</span></q> and <q>\"b\"</q>",
    );
}

test "wrap_preserves_surrounding_prose" {
    try expectWrap("She said \"go\" firmly.", "She said <q>\"go\"</q> firmly.");
}

test "wrap_skips_quotes_inside_a_multi_backtick_code_span" {
    try expectWrap("``a \"b\" c``", "``a \"b\" c``");
    try expectWrap("`` ` \"b\" ``", "`` ` \"b\" ``");
    try expectWrap("``a \"b\"`` said \"hi\"", "``a \"b\"`` said <q>\"hi\"</q>");
}

test "wrap_skips_a_code_span_that_crosses_a_newline" {
    try expectWrap("`a \"b\"\nc` said \"hi\"", "`a \"b\"\nc` said <q>\"hi\"</q>");
}

test "wrap_skips_quotes_inside_an_indented_code_block" {
    try expectWrap("    print(\"hi\")", "    print(\"hi\")");
    try expectWrap("text\n\n\tprint(\"hi\")\n", "text\n\n\tprint(\"hi\")\n");
    try expectWrap("    a(\"x\")\n\n    b(\"y\")\nprose \"z\"", "    a(\"x\")\n\n    b(\"y\")\nprose <q>\"z\"</q>");
}

test "wrap_still_marks_an_indented_paragraph_continuation" {
    try expectWrap("She said \"go\"\n    still \"prose\"", "She said <q>\"go\"</q>\n    still <q>\"prose\"</q>");
}

test "wrap_resynchronises_after_a_stray_angle_bracket" {
    try expectWrap("5 < 6, she said \"hi\"", "5 < 6, she said <q>\"hi\"</q>");
    try expectWrap("a <3 b \"c\"", "a <3 b <q>\"c\"</q>");
}

test "wrap_resynchronises_after_an_unclosed_backtick" {
    try expectWrap("a ` b, she said \"hi\"", "a ` b, she said <q>\"hi\"</q>");
    try expectWrap("a ``` b, she said \"hi\"", "a ``` b, she said <q>\"hi\"</q>");
}

test "wrap_does_not_treat_a_mid_line_tilde_run_as_a_fence" {
    try expectWrap("a ~~~ b said \"hi\"", "a ~~~ b said <q>\"hi\"</q>");
}

test "wrap_treats_an_unclosed_fence_as_code_to_the_end" {
    try expectWrap("```\nsaid \"hi\"\n", "```\nsaid \"hi\"\n");
}

test "wrap_closes_a_fence_only_on_a_run_of_at_least_its_length" {
    try expectWrap(
        "````\n``\n\"a\"\n````\n\"b\"",
        "````\n``\n\"a\"\n````\n<q class=\"q-turn\"><span class=\"qd\">\"</span>b<span class=\"qd\">\"</span></q>",
    );
}

test "wrap_does_not_treat_a_styled_tag_as_a_style_block" {
    try expectWrap("<styled x=\"1\"> she said \"hi\"", "<styled x=\"1\"> she said <q>\"hi\"</q>");
}

test "wrap_skips_quotes_inside_pre_code_and_script_bodies" {
    try expectWrap("<pre>a \"b\"</pre>", "<pre>a \"b\"</pre>");
    try expectWrap("<code>\"x\"</code>", "<code>\"x\"</code>");
    try expectWrap("<script>var a = \"b\";</script>", "<script>var a = \"b\";</script>");
    try expectWrap("<textarea>\"x\"</textarea>", "<textarea>\"x\"</textarea>");
}

test "wrap_skips_quotes_after_an_unclosed_style_block" {
    try expectWrap("<style>\na[b=\"c\"]", "<style>\na[b=\"c\"]");
}

test "wrap_marks_quotes_after_a_closed_raw_element" {
    try expectWrap("<pre>\"a\"</pre> she said \"hi\"", "<pre>\"a\"</pre> she said <q>\"hi\"</q>");
}

test "wrap_keeps_a_quoted_attribute_containing_an_angle_bracket_intact" {
    try expectWrap("<img alt=\"a>b\"> \"hi\"", "<img alt=\"a>b\"> <q>\"hi\"</q>");
}

fn wrapAndDiscard(allocator: std.mem.Allocator, src: []const u8) !void {
    const out = try wrap(allocator, src);
    defer allocator.free(out);
    try testing.expect(out.len >= src.len);
}

test "wrap_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, wrapAndDiscard, .{"She said \"go\" and \u{201C}stop\u{201D} `\"x\"`"});
}

/// The alphabet holds no `q`, so every `<q>` in the output was inserted by `wrap`.
fn expectStripsBackToSource(out: []const u8, src: []const u8) !void {
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(testing.allocator);

    const inserted = [_][]const u8{ "<q class=\"q-turn\">", "<q>", "</q>", "<span class=\"qd\">", "</span>" };
    var k: usize = 0;
    outer: while (k < out.len) {
        for (inserted) |tag| {
            if (std.mem.startsWith(u8, out[k..], tag)) {
                k += tag.len;
                continue :outer;
            }
        }
        try stripped.append(testing.allocator, out[k]);
        k += 1;
    }
    try testing.expectEqualStrings(src, stripped.items);
}

test "wrap_only_ever_inserts_q_tags_into_random_bytes" {
    var prng = std.Random.DefaultPrng.init(0x5177_0715);
    const rand = prng.random();
    const alphabet = "\"`<>~ \n\t\u{201C}\u{201D}abc";

    var buf: [64]u8 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*ch| ch.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const out = try wrap(testing.allocator, buf[0..n]);
        defer testing.allocator.free(out);
        try testing.expect(out.len >= n);
        try expectStripsBackToSource(out, buf[0..n]);
    }
}

test "wrap_never_inserts_a_q_tag_inside_a_fenced_code_block" {
    var prng = std.Random.DefaultPrng.init(0xC0DE_B10C);
    const rand = prng.random();
    // No backtick, so a random payload can never close the fence early and leak a quote into prose.
    const alphabet = "\"<> \n\tabc\u{201C}\u{201D}\u{00AB}\u{00BB}";

    var buf: [96]u8 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*ch| ch.* = alphabet[rand.uintLessThan(usize, alphabet.len)];

        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "```\n");
        try src.appendSlice(testing.allocator, buf[0..n]);
        try src.appendSlice(testing.allocator, "\n```\n");

        const out = try wrap(testing.allocator, src.items);
        defer testing.allocator.free(out);
        // The whole body is one fenced block, so no quote inside it may be wrapped: the headline
        // invariant of the module is that a quote in code never becomes a <q>.
        try testing.expect(std.mem.indexOf(u8, out, "<q>") == null);
    }
}

test "wrap_marks_the_quote_in_a_paragraph_dense_with_tags_and_code_spans" {
    // Every tag and code span queries the paragraph-end memoizer, so one paragraph full of them
    // exercises the cache hit path; the trailing quote must still wrap and each construct pass through.
    try expectWrap(
        "<b>x</b> `a` <i>y</i> `b` <b>z</b> she said \"hi\"",
        "<b>x</b> `a` <i>y</i> `b` <b>z</b> she said <q>\"hi\"</q>",
    );
}
